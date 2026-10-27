#!/usr/bin/env python3
"""Check the portable updater against a local watchdog without installing it."""

import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).parent
WATCHDOG = Path(os.environ.get("WATCHDOG_UNDER_TEST", Path.home() / ".local/bin/opendisplay-watchdog"))


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="opendisplay-update-")
        self.addCleanup(self.scratch.cleanup)
        self.target = Path(self.scratch.name) / "watchdog with spaces"
        self.updated = WATCHDOG.read_bytes()
        self.target.write_bytes(self.updated)
        self.target.chmod(0o700)
        for patch in ["physical-display-type.patch", "portable-displays.patch"]:
            result = subprocess.run(["/usr/bin/patch", "-R", "-f", "-F", "0", str(self.target),
                                     str(ROOT / patch)], capture_output=True)
            self.assertEqual(result.returncode, 0, "Tests require an already patched WATCHDOG_UNDER_TEST")
            if patch == "physical-display-type.patch": self.previous = self.target.read_bytes()
        self.original = self.target.read_bytes()

    def update(self, target=None):
        return subprocess.run(["/bin/bash", str(ROOT / "update-watchdog.sh"), str(target or self.target)],
                              text=True, capture_output=True)

    def test_update_backup_permissions_and_idempotence(self):
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.updated)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o700)
        backups = list(self.target.parent.glob(self.target.name + ".before-portable-displays-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), self.original)
        self.assertEqual(self.update().returncode, 0)
        self.assertEqual(len(list(self.target.parent.glob(self.target.name + ".before-portable-displays-*"))), 1)

    def test_changed_hunk_is_refused_without_modifying_original(self):
        content = self.original.replace(b'physical_connection_state() {', b'custom_connection_state() {')
        self.target.write_bytes(content)
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(self.target.read_bytes(), content)
        self.assertFalse(list(self.target.parent.glob(self.target.name + ".before-portable-displays-*")))

    def test_previous_portable_version_is_upgraded(self):
        self.target.write_bytes(self.previous)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.target.read_bytes(), self.updated)

    def test_invalid_shell_is_refused(self):
        content = self.original + b"\nif\n"
        self.target.write_bytes(content)
        self.assertNotEqual(self.update().returncode, 0)
        self.assertEqual(self.target.read_bytes(), content)

    def test_private_display_configuration_is_preserved(self):
        content = self.original.replace(b'DISPLAY_MODE="12"', b'DISPLAY_MODE="13"')
        content += b'\nPHYSICAL_DISPLAY_NAME="Another monitor"\nPHYSICAL_DISPLAY_MODE="54"\n'
        self.target.write_bytes(content)
        result = self.update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        updated = self.target.read_bytes()
        self.assertIn(b'DISPLAY_MODE="13"', updated)
        self.assertIn(b'PHYSICAL_DISPLAY_NAME="Another monitor"', updated)
        self.assertIn(b'PHYSICAL_DISPLAY_MODE="54"', updated)

    def test_symlink_is_refused(self):
        link = self.target.parent / "link"
        link.symlink_to(self.target)
        self.assertNotEqual(self.update(link).returncode, 0)
        self.assertEqual(self.target.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
