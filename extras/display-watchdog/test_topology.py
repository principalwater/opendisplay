#!/usr/bin/env python3
"""Exercise topology transitions without touching the desktop or power assertions."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WATCHDOG = Path(os.environ.get("WATCHDOG_UNDER_TEST", Path.home() / ".local/bin/opendisplay-watchdog"))
DEVICE = r'''
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ["DISPLAY_FIXTURE"])
s = json.loads(p.read_text())
args = sys.argv[1:]
devices = s["panels"] + [s["virtual"]]
def save(): p.write_text(json.dumps(s))
if Path(sys.argv[0]).name == "display-list":
    if args:
        target = args[1]
        for d in devices: d["main"] = d["id"] == target
        save()
    else:
        for d in devices:
            if d["on"] and not d.get("asleep"):
                print("\t".join([d["id"], "main" if d["main"] else "-", "1920x1080", "inactive" if d.get("asleep") else "active", d["name"]]))
        if s.get("session"):
            print("99\tmain\t1194x834\tactive\tOpenDisplay receiver")
    sys.exit(0)
s["calls"].append(args)
save()
selected = devices
for arg in args:
    if arg.startswith("-displayID="): selected = [d for d in selected if d["id"] == arg.split("=", 1)[1]]
    if arg.startswith("-UUID="): selected = [d for d in selected if d["uuid"] == arg.split("=", 1)[1]]
    if arg.startswith("-name="): selected = [d for d in selected if d["name"] == arg.split("=", 1)[1]]
    if arg.startswith("-deviceType="): selected = [d for d in selected if d["type"] == arg.split("=", 1)[1]]
if args[0] == "get" and "-identifiers" in args:
    records = [dict(UUID=d["uuid"], displayID=d["id"] if d["on"] else "0", name=d["name"], deviceType=d["type"], registryLocation="IOService:/Test" if d["type"] == "Display" else "", vendor="1", model="2", serial="3") for d in selected]
    # Observed BetterDisplay 5.1.1 response: a group is included unless type is explicit.
    if not any(a.startswith("-deviceType=") for a in args) and any(a.startswith(("-displayID=", "-UUID=")) for a in args):
        records.append(dict(deviceType="DisplayGroup", name="Default Group", tagID="-1001"))
    print(",".join(json.dumps(d) for d in records))
    sys.exit(0)
if len(selected) != 1: sys.exit(1)
d = selected[0]
if args[0] == "get" and "-connected" in args:
    if not d.get("queryManageable", d.get("manageable", True)): sys.exit(1)
    print("on" if d["on"] else "off")
elif args[0] == "set":
    for arg in args:
        if arg.startswith("-connected="):
            if not d.get("manageable", True) or (arg.endswith("=on") and d.get("restoreFails")) or (arg.endswith("=off") and d.get("disconnectFails")): sys.exit(1)
            d["on"] = arg.endswith("=on")
        elif arg.startswith("-displayModeNumber=") and d["type"] == "Display":
            sys.exit("physical modes must remain unchanged")
    save()
else:
    sys.exit(1)
'''.lstrip()


def panel(name="Thunderbolt Display", identifier="1", manageable=False):
    return dict(name=name, id=identifier, uuid=f"00000000-0000-0000-0000-{int(identifier):012d}",
                type="Display", on=True, main=True, manageable=manageable)


class TopologyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="opendisplay-topology-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.fixture = self.root / "devices.json"
        for name in ("betterdisplay", "display-list"):
            p = self.root / name
            p.write_text(DEVICE)
            p.chmod(0o755)
        self.awake = self.root / "awake"
        self.awake.write_text("1")
        self.state = dict(panels=[panel()], virtual=dict(name="Placeholder", id="10",
                          uuid="00000000-0000-0000-0000-000000000010", type="VirtualScreen",
                          on=False, main=False), session=False, attached=True, calls=[])

    def run_topology(self, previous="headless-session", fail_virtual=False):
        self.fixture.write_text(json.dumps(self.state))
        (self.root / "topology").write_text(previous)
        source = WATCHDOG.read_text()
        # Source the actual topology owner; replace only OS/process boundaries.
        source = source.rsplit('main "$@"', 1)[0]
        script = self.root / "run"
        script.write_text(source + r'''
LOG_DIR="$TEST_ROOT"
STATE="$TEST_ROOT/status"
TOPOLOGY_STATE="$TEST_ROOT/topology"
PHYSICAL_DISPLAY_STATE="$TEST_ROOT/physical-displays"
HEADLESS_KEEP_AWAKE_PID_STATE="$TEST_ROOT/keepawake.pid"
BETTERDISPLAY="$TEST_ROOT/betterdisplay"
DISPLAY_LIST="$TEST_ROOT/display-list"
DISPLAY_NAME=Placeholder
DISPLAY_UUID=00000000-0000-0000-0000-000000000010
DISPLAY_VENDOR=1 DISPLAY_MODEL=2 DISPLAY_SERIAL=3
sunshine_watchdog_loaded() { return 1; }
physical_hardware_connected() { [ "$ATTACHED" = 1 ]; }
opendisplay_session_settled() { [ "$SESSION" = 1 ]; }
session_layout() { printf remote; }
recover_stuck_topology() { return 1; }
process_count() { cat "$TEST_ROOT/awake"; }
ensure_single_headless_keepawake() { echo 1 > "$TEST_ROOT/awake"; }
terminate_matching_processes() { echo 0 > "$TEST_ROOT/awake"; }
display_is_active() { return 0; }
sleep() { :; }
if [ "$FAIL_VIRTUAL" = 1 ]; then disconnect_virtual() { return 1; }; fi
manage_topology
result=$?
printf '%s\n' "$topology_summary"
exit "$result"
''')
        env = dict(os.environ, TEST_ROOT=str(self.root), DISPLAY_FIXTURE=str(self.fixture),
                   ATTACHED=str(int(self.state["attached"])), SESSION=str(int(self.state["session"])),
                   FAIL_VIRTUAL=str(int(fail_virtual)))
        result = subprocess.run(["/bin/bash", str(script)], env=env, text=True, capture_output=True)
        self.state = json.loads(self.fixture.read_text())
        return result

    def test_new_monitor_releases_idle_assertion_without_mode_or_connection_control(self):
        result = self.run_topology()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.awake.read_text().strip(), "0")
        self.assertIn("topology=headed", result.stdout)
        self.assertFalse(any(c[0] == "set" for c in self.state["calls"]))
        calls = len(self.state["calls"])
        self.assertEqual(self.run_topology("headed").returncode, 0)
        self.assertFalse(any(c[0] == "set" for c in self.state["calls"][calls:]))

    def test_another_monitor_name_and_multiple_panels_preserve_primary(self):
        self.state["panels"] = [panel("Built-in Retina Display", "2"), panel("External USB-C", "3")]
        self.state["panels"][1]["main"] = False
        self.assertEqual(self.run_topology().returncode, 0)
        self.assertEqual(self.awake.read_text().strip(), "0")
        self.assertTrue(self.state["panels"][0]["main"])
        self.assertFalse(self.state["panels"][1]["main"])

    def test_sleeping_physical_monitor_is_not_woken_by_periodic_tick(self):
        self.state["panels"][0]["asleep"] = True
        self.awake.write_text("0")
        result = self.run_topology("headed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any(c[0] == "set" for c in self.state["calls"]))

    def test_idle_virtual_cleanup_failure_still_releases_display_assertion(self):
        result = self.run_topology(fail_virtual=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.awake.read_text().strip(), "0")

    def test_remote_session_hides_and_restores_exact_panels_before_dropping_placeholder(self):
        self.state["panels"] = [panel("External A", "2", True), panel("External B", "3", True)]
        self.state["panels"][1]["main"] = False
        self.state["session"] = True
        result = self.run_topology("headed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.state["virtual"]["on"])
        self.assertTrue(all(not d["on"] for d in self.state["panels"]))
        self.assertEqual(self.awake.read_text().strip(), "1")
        self.state["session"] = False
        result = self.run_topology("headed-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(all(d["on"] for d in self.state["panels"]))
        self.assertFalse(self.state["virtual"]["on"])
        self.assertEqual(self.awake.read_text().strip(), "0")
        self.assertTrue(self.state["panels"][0]["main"])
        self.assertFalse((self.root / "physical-displays").exists())
        calls = self.state["calls"]
        first_off = next(i for i, c in enumerate(calls) if "-connected=off" in c)
        self.assertTrue(any("-connected=on" in c and "-name=Placeholder" in c for c in calls[:first_off]))
        virtual_off = next(i for i, c in enumerate(calls) if "-connected=off" in c and "-name=Placeholder" in c)
        self.assertEqual(sum("-connected=on" in c and any(a.startswith("-UUID=") for a in c) for c in calls[:virtual_off]), 2)

    def test_failed_reconnect_retains_placeholder_assertion_and_recovery_record(self):
        self.state["panels"][0]["on"] = False
        self.state["panels"][0]["manageable"] = True
        self.state["panels"][0]["restoreFails"] = True
        self.state["virtual"]["on"] = True
        (self.root / "physical-displays").write_text(self.state["panels"][0]["uuid"] + "\n")
        result = self.run_topology("headed-session")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state["virtual"]["on"])
        self.assertEqual(self.awake.read_text().strip(), "1")
        self.assertTrue((self.root / "physical-displays").exists())

    def test_native_disconnect_does_not_depend_on_connected_query(self):
        self.state["panels"][0].update(manageable=True, queryManageable=False)
        self.state["session"] = True
        result = self.run_topology("headed")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.state["panels"][0]["on"])
        self.state["session"] = False
        self.assertEqual(self.run_topology("headed-session").returncode, 0)
        self.assertTrue(self.state["panels"][0]["on"])

    def test_partial_disconnect_can_recover_all_original_panels(self):
        self.state["panels"] = [panel("External A", "2", True), panel("External B", "3", True)]
        self.state["panels"][1].update(main=False, disconnectFails=True)
        self.state["session"] = True
        self.assertNotEqual(self.run_topology("headed").returncode, 0)
        self.assertFalse(self.state["panels"][0]["on"])
        self.assertTrue(self.state["panels"][1]["on"])
        self.state["session"] = False
        self.assertEqual(self.run_topology("headed").returncode, 0)
        self.assertTrue(all(d["on"] for d in self.state["panels"]))
        self.assertEqual(self.awake.read_text().strip(), "0")

    def test_corrupt_recovery_identity_refuses_mutation(self):
        (self.root / "physical-displays").write_text("not-a-display-uuid\n")
        self.assertNotEqual(self.run_topology().returncode, 0)
        self.assertFalse(any(c[0] == "set" for c in self.state["calls"]))

    def test_unreadable_recovery_record_refuses_physical_disconnect(self):
        record = self.root / "physical-displays"
        record.write_text("00000000-0000-0000-0000-000000000099\n")
        record.chmod(0)
        self.state["session"] = True
        self.state["panels"][0]["manageable"] = True
        result = self.run_topology("headed")
        record.chmod(0o600)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state["panels"][0]["on"])
        self.assertEqual(record.read_text(), "00000000-0000-0000-0000-000000000099\n")

    def test_unsupported_disconnect_leaves_physical_monitor_and_recovery_record(self):
        self.state["session"] = True
        result = self.run_topology("headed")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state["panels"][0]["on"])
        self.assertTrue(self.state["virtual"]["on"])
        self.assertEqual(self.awake.read_text().strip(), "1")

    def test_headless_idle_retains_keepawake(self):
        self.state["panels"] = []
        self.state["attached"] = False
        self.state["virtual"]["on"] = True
        result = self.run_topology("headless")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.awake.read_text().strip(), "1")


if __name__ == "__main__":
    unittest.main()
