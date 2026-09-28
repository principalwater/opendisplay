# OpenDisplay Alfheim fork

This branch contains the source used by a Mac sender and an iPad receiver in a
personal remote-desktop setup. It is based on upstream OpenDisplay v1.22.0 and
keeps the upstream GPL-3.0 license and attribution. Signed macOS packages are
published separately in GitHub Releases. Local machine names, network details,
and development logs are not included in this branch's history.

## Added behavior

- Hardware keyboard passthrough, key repeat, a selectable Command-key stand-in,
  pointer hover, secondary click, scrolling, and native touch gestures.
- A left Option/Command swap and a Control+backtick Escape binding are available
  in the Mac keyboard settings. Together they preserve Command+Option shortcuts
  and Command+backtick window switching when iPadOS delivers the key presses.
- System audio streaming with optional host-speaker silencing tied to the
  actual audio delivery gate.
- Remote, Extend, and Mirror layouts; 120 Hz default where the receiver and
  path support it; adaptive quality and congestion handling. Routed sessions
  start conservatively and probe upward when frames flow without congestion.
- Sender and receiver admission, reconnection, and cable/LAN deduplication.
  The receiver checks the chosen Mac before replacing a live session, and the
  sender waits for its admission before creating a virtual display. Its idle
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
