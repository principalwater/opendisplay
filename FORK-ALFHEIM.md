# OpenDisplay Alfheim fork

This branch contains the source used by a Mac sender and an iPad receiver in a
personal remote-desktop setup. It is based on upstream OpenDisplay v1.30.0,
less the upstream changes listed under the integration below, and keeps the
upstream GPL-3.0 license and attribution. Signed macOS packages are
published separately in GitHub Releases, but a release may lag this branch;
build the branch for the latest fixes. Host-specific configuration,
credentials, and development logs are not included in this branch.

## Added behavior

### Upstream v1.30.0 integration

Upstream `main` at v1.30.0 (`374cee0`) is merged; fork behavior wins where the
two overlap. Taken from upstream, ported onto the fork's pipeline:

- HEVC when both ends handle it in hardware (#325). The sender picks HEVC only
  if it keeps the frame rate H.264 would reach. Receivers from this branch offer
  HEVC at the panel's maximum rate (120 Hz on a ProMotion iPad), and the sender
  ignores the 60 fps H.264 limit that protocol 4 receivers advertise but never
  enforce. Bitrate, adaptive quality and the 120 Hz rate stay the fork's.
  `defaults write com.peetzweg.opensidecar.mac.alfheim videoCodec h264` keeps
  H.264 from the next session on; `hevc` drops the frame-rate condition; with
  the key unset the choice is automatic.
- The arrangement-restore window starts on its first tick (#392); a capture
  that delivers another display re-attaches (#393); a display-unit clash
  renumbers the session display in creation order (#399, Extend only).
- The sender can shut down a Mac receiver on a direct cable (#332); macOS may
  ask once to let the receiver control the login window. A Mac receiver whose
  direct cable is plugged in connects by itself (#338).
- Android over USB in accessory mode, without adb (#225, #404, #424). Plugging
  in connects only a device that streamed over the cable before.

Left out: the sleep and lock recovery rewrite (#320), receiver-driven desktop
sizing from `hello.panel` (#345) with #323, #346, #347 and #352 that build on
it, the asynchronous resize and window reporting (#357), the Retry-only session
button (#335), and the iOS idle screen, rating prompt and About links (#350).
The fork's own sleep handling, native desktop sizing, resize and rotation path,
Reconnect button and Connect UI remain. The sender ignores the new `hello`
fields it does not use. `PROTOCOL.md` keeps upstream's 6.6 (power) and 6.7
(panel); the fork's "Choosing a sender" is now 6.8.

A 1.23.0 receiver offers only H.264 and still works with this sender; a
receiver from this branch also works with a 1.23.0 sender.

### Extend and Mirror display fixes

Extend records the main display before it creates the session display and
makes it main again after creation and through the arrangement-restore window,
so the iPad display never becomes main. The session display goes on its
remembered side, or to the right of the main display when no valid placement
is remembered. A placement at or over the main display's origin is never
restored or saved. Remote still pins its display as main; Mirror keeps its
arrangement. Mirror sessions now create an input injector for the captured
display, so touches and keys reach it.

### Sender 1.23.0: native display ownership

Remote desktop sessions now disconnect physical monitors through macOS itself,
without BetterDisplay, an external CLI, Bash polling or a `caffeinate` process.
The sender prepares recovery before creating its session display and requests
disconnection only after capture starts. Extend and Mirror keep physical panels.
Monitor discovery uses the system's physical/virtual metadata and UUIDs, with no
monitor names, fixed display IDs or resolution changes for physical panels.

An embedded, signed Swift agent holds a recovery desktop until physical panels
have returned. It restores their modes and arrangement when the session ends or
the sender dies. A pipe is the sender's lifetime lease; a private boot-scoped
journal is written before disconnection. The sender also recovers the journal
if the agent crashes. Failed or unavailable system operations leave local
displays usable and report the failure in the control panel. Brightness and
gamma are never used to imitate disconnection.

The same agent supplies a small native desktop when the Mac has no physical
panel. IOPM assertions keep streaming and headless desktops awake and are released on
a local idle desktop, allowing the configured macOS display-sleep timeout.
Display changes and session transitions drive the work; there is no recurring
display-management polling timer. Existing receiver discovery and dialers handle
reconnection. The legacy `exitAfterReceiverLoss` preference is retired.

Enable **Launch at login** in the app to use macOS ServiceManagement. When
upgrading a Mac that has the old external watchdog, stop and disable that job
before using native display ownership; the old `extras/display-watchdog` updater
is only for older senders. Preserve its configuration and backup for rollback.
An existing launchd supervisor may launch the native app directly and restart
it after a crash; it no longer needs a script, timer, or log watcher.

This uses private macOS display APIs, as virtual-display creation already does.
Symbols are resolved at runtime; unrecognized displays are left alone. Hardware
behavior varies, so an untested Mac must verify both disconnect and recovery.
The [hardware check](extras/native-display-tests/README.md) is explicit opt-in.
The iPad protocol, release bundle identity and privacy grants are unchanged.

Apple Thunderbolt Display brightness works natively with **Control + Brightness
Up/Down** ([Apple keyboard shortcuts](https://support.apple.com/en-ie/102650)).
No brightness keyboard interception is included.

Capture rebuilds retain physical ownership for a bounded five-second gap; an
explicit end, shutdown or pipe EOF restores immediately. Normal teardown waits
for a bounded restoration acknowledgement before releasing the capture display.
Window gathering remembers display UUIDs and relative positions, so restoring
the physical arrangement does not invalidate the saved window coordinates.
Unavailable panels remain in the recovery journal; a usable physical desktop
does not retain an invisible fallback screen for a disconnected second panel.

If the sender hangs, its lifetime lease remains active. Quit and reopen the Mac
app to request recovery. If both the sender and agent have been forcibly killed,
relaunch the app to recover its journal, or reboot the Mac. An existing launchd
supervisor can relaunch it after a crash. Recovery requires a logged-in desktop;
lock screen, logout and sleep/wake have not been validated on every Mac.

### Receiver 1.23.0: manual connection by default

The iPad receiver waits for **Connect** beside the host picker on a cold launch.
Choose the host without a deadline, then tap Connect. Settings can enable
automatic connection with the existing immediate or 1–5 second delay. Changing
hosts before the first connection does not start streaming. Reconnection after
an established session retains the existing automatic behavior.

A fresh Bonjour appearance immediately wakes a waiting dial. A newly discovered
service gets one quick fresh-resolution retry, then returns to the normal
five-second attempt deadline and one-second retry pause. Direct host endpoints
keep their existing deadlines; there is no added permanent fast network poll.

### External watchdog update (2026-10-26)

The optional [portable display patch](extras/display-watchdog/README.md) updates
an already installed external watchdog. It removes physical monitor-name and mode
hardcoding, releases stale idle display-sleep assertions on a local desktop, and
records actual display UUIDs for remote-session restoration. The guarded updater
preserves each Mac's private configuration and makes a rollback copy. This is a
separate deployment update; replacing the app bundle alone does not apply it.

### Sender 1.22.4

A nonmodifier key-up ignores UIKit's fallback modifier snapshot, which can
retain a chord's original Option or Command after that modifier was released.
Tracked held modifiers and the on-screen sidebar still apply to key-up; key-down
keeps the fallback for modifiers pressed before the video view had focus.
This prevents the stale key-up from reasserting a released swapped modifier.

Injected arrow keys keep the native macOS NumericPad and Fn key-class flags
on both press and release. This preserves the native navigation event shape
for remapped Command+Shift+arrow shortcuts even when UIKit reports only the
physical modifiers. Letters and modifier transitions are unaffected. The wire
protocol and signed 1.22.0 receiver remain compatible.

### Sender 1.22.3

The encoder permits two in-flight frames and uses normal real-time rate
control by default. The previous single-frame gate skipped every other 120 Hz
capture when encoding took more than 8.3 ms. A native NV12 benchmark measured
about 60 outputs/s with that gate and about 112 outputs/s with the new settings;
live receiver delivery and presentation still require validation. The existing
`lowlatency` override remains available for hardware comparisons.

VideoToolbox completions enter the serial sender queue before touching framing
or the network queue. Retired capture, encoder and connection completions are
excluded, and reconnects no longer reset the count of still-running encodes.
Display restoration and external watchdog timing are unchanged.

A hardware key press reconciles a supplied modifier snapshot before injection,
so a lost modifier release does not keep Command latched on later keystrokes.
Deliberately held modifiers remain held; legacy events without a snapshot keep
the previous behavior. The wire protocol and 1.22.0 receiver are unchanged.

### Sender 1.22.2

Reconnects identify the live connection by an object reference, so a reused
allocation address cannot inherit the previous peer's framing or admission.
Video and adaptation wait for the new greeting and admission; retired write
callbacks cannot change the replacement connection's send queue. Repeated
ready notifications keep one control receive loop.

Adaptive quality no longer treats frame arrival gaps as network drops: idle
capture and encoder pacing create those gaps too. Sender backlog and measured
delivery delay remain congestion signals. A congested point at the bitrate
floor is not saved as stable. Remembered low LAN points probe upward with fresh
clean receiver reports; without a report, increases remain 10% every 15 seconds.
The wire protocol and existing 1.22.0 iPad receiver remain compatible. Display
watchdogs, restoration timing, bundle identity and signing identity are unchanged.

- Hardware keyboard passthrough, key repeat, a selectable Command-key stand-in,
  pointer hover, secondary click, scrolling, and native touch gestures.
- A left Option/Command swap and a Control+backtick Escape binding are available
  in the Mac keyboard settings. Together they preserve Command+Option shortcuts
  and Command+backtick window switching when iPadOS delivers the key presses.
- System audio streaming with optional host-speaker silencing tied to the
  actual audio delivery gate.
- Remote, Extend, and Mirror layouts; 120 Hz default where the receiver and
  path support it; adaptive quality and congestion handling. Recognized
  tailnet sessions start conservatively and probe upward when frames flow
  without congestion; an RTT reading alone does not cap local Wi-Fi.
- Sender and receiver admission, reconnection, and cable/LAN deduplication.
  The receiver checks the chosen Mac before replacing a live session, and the
  sender waits for its admission before creating a virtual display. Repeated
  refusals are summarized in the receiver log while retrying. Its idle
  screen offers the Mac picker and a manual Connect button by default;
  iPad settings can enable an optional automatic startup delay.
- Tests for the input, audio, display, transport, and protocol paths.

The fork gives the Mac sender and iOS receiver distinct bundle identifiers:
`com.peetzweg.opensidecar.mac.alfheim` and
`com.peetzweg.opensidecar.ios.alfheim`. Keep these identifiers stable once
macOS privacy grants and the receiver installation are in use. Automatic
Sparkle updates are disabled for the forked Mac sender.

## Build

Use Xcode and `xcodegen`, which `generate.sh` invokes.
Create a local, ignored `.env` containing `DEVELOPMENT_TEAM=YOUR_TEAM_ID`,
then run `./generate.sh`. Build the Mac sender with the `OpenSidecarMac`
scheme and the iOS receiver with `OpenSidecariOS`. Sign the receiver with
your own Apple development team and install it on your device. The upstream
[README](README.md) describes the general build and permission flow.

Both endpoints should run compatible builds from this branch. The Mac dials
the receiver's TCP port 9000; the optional cursor and stats lane uses UDP
9001, with a TCP fallback for cursor updates. Bonjour discovery only works on
the local network. A routed or tailnet deployment needs an explicit reachable
receiver endpoint and should be validated end to end before unattended use.

The complete external display watchdog and host-specific network configuration
remain private deployment concerns. The optional portable patch above contains
only the shared physical-display repair; it does not distribute host settings or
install a new watchdog.

## Upstream contribution context

This fork draws on work proposed to upstream by other contributors: input and
click handling in [#216](https://github.com/peetzweg/opendisplay/pull/216) and
keyboard passthrough in [#247](https://github.com/peetzweg/opendisplay/pull/247)
by kdbhalala, touch positioning in
[#218](https://github.com/peetzweg/opendisplay/pull/218) by BLACKIELF, audio in
[#274](https://github.com/peetzweg/opendisplay/pull/274) by M4st3rZeus, and
frame-rate controls in [#276](https://github.com/peetzweg/opendisplay/pull/276)
by KareemmSayed. These upstream proposals were still open on 2026-09-28.
Future PRs from this fork should preserve their credit and isolate additional
changes rather than submit the entire fork as one patch.
