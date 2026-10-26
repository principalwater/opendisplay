# Portable physical displays for the external watchdog

This fixes a deployment script, not the OpenDisplay app. Updating only the app
bundle will not replace a separately installed `opendisplay-watchdog`.

The old watchdog addressed a specific monitor name and BetterDisplay mode number.
After replacing that monitor, headed recovery failed before stopping its long-lived
`caffeinate -d -i -u` child. That prevented idle display sleep even though the macOS
display timeout was still enabled. Some monitors also do not support BetterDisplay's
`connected` feature; they must be recognized through the actual macOS display list.

## Update another Mac

Use the local desktop, end the remote session first, and leave a physical display
connected. The Mac must already have the external watchdog and its display helpers.
This patch preserves its existing receiver, virtual-display and network settings.
It does not install a new watchdog or configure BetterDisplay.

From a reviewed checkout of the `alfheim` branch:

```sh
bash extras/display-watchdog/update-watchdog.sh
```

An optional argument selects another installed watchdog path. The updater requires
the current user to own the regular file, checks every patch hunk without fuzz,
validates Bash syntax, makes a timestamped backup and replaces the file atomically.
Legacy physical-name/mode variables may remain in private configuration; the
patched functions no longer read them.
Running it twice is harmless. A different/custom watchdog is refused without
changing it; review and port the patch rather than forcing it.

After the next scheduled tick, inspect `pmset -g assertions` and the watchdog's
state/log files. With a local physical desktop and no remote session, its display
sleep assertion should be gone. The existing macOS idle timeout still applies.
The updater does not alter global power settings, app binaries, signatures or TCC.

To roll back, end any remote session, copy the printed backup to a temporary file
beside the installed watchdog and rename that file over the watchdog. A rollback
restores the old behavior, including its monitor-specific limitation.

## Behavior and limits

- Physical display names, resolutions, refresh rates and BetterDisplay mode
  numbers are not hardcoded. An idle physical desktop keeps its existing settings,
  including its primary display; a sleeping panel is not woken by watchdog ticks.
- Remote sessions retain the placeholder-before-disconnect order and keep-awake.
  The watchdog records the actual panels' UUIDs before hiding any of them, restores
  those panels and the original physical primary, then drops the placeholder.
  Partial failures keep the recovery record and a usable display path.
- BetterDisplay connection management still requires supported hardware and its
  applicable license. Unsupported physical disconnection is reported as a topology
  failure with the panel left available; this patch does not bypass that limitation.
- Display classification retains the existing exclusions for the configured
  placeholder, OpenDisplay displays and AirPlay placeholders. Other third-party
  virtual-display products are outside the validated scope.

## Verification

The tests mock the desktop/device and process boundaries, leaving the production
topology functions in control. Python 3 and macOS's Bash/plutil are needed:

```sh
WATCHDOG_UNDER_TEST="$HOME/.local/bin/opendisplay-watchdog" \
  python3 -m unittest discover -s extras/display-watchdog -p 'test_*.py'
```

Coverage includes unsupported connection queries, replacement/multiple monitors,
sleeping panels, headless keep-awake, exact remote restoration and primary selection,
partial disconnect, reconnect failure, invalid recovery identities and failed virtual
cleanup. Updater tests also exercise backups, file modes, repeat application, paths
with spaces, and refusal of conflicting edits, syntax errors and symlinks.
Per-Mac placeholder modes and legacy settings are preserved during application.
Hardware acceptance on each other Mac remains necessary for remote connect,
disconnect, cable changes and the actual idle timeout.
