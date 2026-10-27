# Native display control hardware checks

The normal Xcode test suite covers bounded commands, recovery-file validation,
exclusive ownership, restart persistence and boot-scoped opaque display IDs.
It never changes actual displays.

The separate hardware check deliberately disconnects physical panels, reconnects
them and SIGKILLs an actual virtual-display owner. Run it only in a local GUI
session with a working physical display and another way to reach the Mac. Stop
any older external display watchdog before testing. BetterDisplay is unnecessary.

From the repository root, after building the Release sender:

```sh
xcrun swiftc -parse-as-library -O -target arm64-apple-macos14.0 \
  -import-objc-header Mac/CGVirtualDisplayPrivate.h \
  DisplayControl/*.swift extras/native-display-tests/Integration.swift \
  -o /tmp/opendisplay-native-integration
/tmp/opendisplay-native-integration --exercise-hardware \
  "$PWD/build/Build/Products/Release/OpenDisplay Alfheim.app/Contents/MacOS/OpenDisplayDisplayAgent"
```

Use `x86_64-apple-macos14.0` when compiling on an Intel host. The command prints
the retained evidence directory. Recovery files precede every disconnect;
normal EOF and real parent SIGKILL must restore the original physical mode and
arrangement and clear journal ownership. These tests use disposable state,
not the installed app's recovery files.

The fixture pins the capture at the main origin using a session-scoped layout,
as the real sender does. It re-enables the owned physical panel from a separate
process during a remote session and expects the agent to disconnect it again.
Snapshots and pin transactions use fresh processes: CoreGraphics caches in a
long-lived test client can otherwise make a failed check appear successful.

The private enabled-state API does **not** reliably roll back on process death,
even for an app-scoped transaction. The independent native recovery process,
pipe EOF and write-before-off journal are required. A real sender session and
an agent crash should also be checked after a signed installation.

The agent runs a native `NSApplication` event loop without activation. A bare
`RunLoop` did not keep display state fresh after another process changed it on
the tested system. Restoration uses a session-scoped layout transaction to undo
the sender's capture-origin pin; physical enabled-state changes stay app-scoped.

## Validation recorded on 2026-10-27

On Apple Silicon, macOS27.0.1 and an Apple Thunderbolt Display, the hardware
fixture passed physical disconnect, external reactivation, capture replacement
without panel wake, repeated sessions, held-capture restoration acknowledgement,
normal end, lease EOF and an actual capture-owner SIGKILL, restoring physical
mode and arrangement. BetterDisplay was closed. The normal suite passed844
XCTest cases (one existing optional skip) and four Swift Testing cases; the
legacy topology/updater suite passed18 cases. Signed Release builds succeeded
for a universal macOS14+ sender/helper and the iOS16.4+ receiver. Existing
unrelated compiler warnings remain.

The manual Connect UI was checked in iPad portrait/landscape and a narrow phone
simulator. It remained unarmed beyond80seconds, with no TCP listener; choosing
Any Mac did not start admission. The automatic option defaulted to off.
The operator accepted signed1.23.0(13) on a real iPad: saved-host/manual Connect,
faster connection, streaming, repeated rotation without panel wake, and correct
panel/window return. Killing the signed agent during a real session also
restored physical ownership while the session continued. A pending-panel fixture
kept the journal, avoided an invisible fallback on a headed desktop and used
less than1.5seconds of child CPU while waiting through bounded EOF recovery.

Physical cable hotplug and sleep/wake still require device acceptance. Intel runtime
and other monitor hardware have not been exercised. These observations do not
establish sustained streaming or energy performance.
