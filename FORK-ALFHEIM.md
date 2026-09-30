# OpenDisplay Alfheim fork

This branch contains the source used by a Mac sender and an iPad receiver in a
personal remote-desktop setup. It is based on upstream OpenDisplay v1.22.0 and
keeps the upstream GPL-3.0 license and attribution. Signed macOS packages are
published separately in GitHub Releases, but a release may lag this branch;
build the branch for the latest fixes. Host-specific configuration,
credentials, and development logs are not included in this branch.

## Added behavior

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
  screen offers the Mac picker, with a 3-second startup delay by default;
  iPad settings can change the delay to immediate or 1–5 seconds.
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

The external display watchdog and host-specific network configuration are
deployment concerns and are deliberately not included in this public source
branch. They depend on each Mac's displays, BetterDisplay identifiers, power
policy, and network topology.

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
