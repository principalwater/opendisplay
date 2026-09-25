// MacSender — captures a display, H.264-encodes it, streams it to the phone.
//
// Milestone 1 (mirror):  capture the main display.
// Milestone 2 (extend):  create a CGVirtualDisplay sized to the phone panel
//                        (announced by the phone in a "hello" message) and
//                        capture that — macOS gains a true second monitor.
//
// Pipeline:  ScreenCaptureKit -> VideoToolbox (H.264) -> framed TCP
// Roles: the PHONE listens, the MAC connects (required for usbmux/USB).
//
// Wire protocol, Mac -> phone:   [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, NALUs delimited by 00 00 00 01)
// Wire protocol, phone -> Mac:   [4-byte big-endian length][JSON message]
//   e.g. {"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}

import ScreenCaptureKit
import VideoToolbox
import Network
import CoreMedia
import AVFoundation
import AppKit

/// The last `stats` report from the receiver, whichever channel carried it.
struct ReceiverReport: Equatable {
    var stalls = 0
    var e2eP50 = 0.0
    var e2eP95 = 0.0
    var rtt = 0.0
    var mbps = 0.0
    var fps = 0
}

/// Thrown by `start()` when the controller refuses a session at its first
/// `hello`: another session already serves the same receiver over a better
/// transport. Deliberately **not** a failure — nothing was built, so the row
/// must vanish rather than sit on a red "Failed:" the user has to dismiss.
struct SessionSuperseded: Error {}

struct PhoneInfo: Decodable {
    let pixelsWide: Int   // landscape-oriented (long edge)
    let pixelsHigh: Int
    let scale: Double
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // lets the controller match the same physical device
                          // across USB and WiFi
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1
    let cursorPort: Int?  // UDP port for the cursor side channel (PROTOCOL.md
                          // 6.3); absent = cursor stays on TCP
    let addrs: [String]?  // every address the receiver is reachable on
                          // (PROTOCOL.md 6.4); probed for a cable upgrade
    let maxEncodeWide: Int?  // receiver's decode ceiling in pixels (PROTOCOL.md
    let maxEncodeHigh: Int?  //  6.5): cap the stream, keep the desktop size
    let audioSeq: Bool?   // receiver understands AudioPacket's optional
                          // sequence number (PROTOCOL.md 6.7). Absent on every
                          // receiver that predates it → do not stamp, and the
                          // bytes on the wire stay exactly what they were.

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
    var wantsAudioSequence: Bool { audioSeq ?? false }
}

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
enum SenderTransport {
    case tcp(NWEndpoint)                   // WiFi (Bonjour) or -host/-port override
    case usb(udid: String?, port: UInt16)  // native usbmuxd dial; nil = first device
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status surfaced to the UI (updated on main thread).
    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Int, Double) -> Void)?   // framesSent, mbps
    // Fired whenever adaptive quality steps the stream down or back up, so the
    // panel can say what the link is actually getting.
    @MainActor var onQualityLevel: ((QualityLevel) -> Void)?
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    @MainActor var onDisconnected: (() -> Void)?
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    @MainActor var onPeerSleeping: (() -> Void)?
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    @MainActor var onPeerClosed: (() -> Void)?
    // Fired when the receiver refuses this sender because the user picked a
    // different Mac (PROTOCOL.md 6.6). Carries the backoff the receiver asked
    // for. The controller ends the session — so no display, no encoder and no
    // audio pipeline exist for the duration — and suppresses the dial until it
    // expires.
    @MainActor var onRejectedByReceiver: ((_ retryAfterMs: Int, _ reason: String) -> Void)?
    // Fired once a TCP connection is live, with whether it runs over a
    // wired path (Thunderbolt Bridge / Ethernet) rather than WiFi — the UI
    // labels the row so the user can see the cable is actually in use.
    @MainActor var onTransportPath: ((_ wired: Bool) -> Void)?
    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?
    // Asked ONCE, on the session's first `hello`, and answered before this
    // sender has created a CGVirtualDisplay, an encoder or an audio encoder.
    // `false` means another session already serves this receiver over a better
    // transport, and this one must disappear without ever having been visible.
    //
    // The ordering is the whole point. The controller's post-hoc dedupe can
    // only compare two identities once both have been learned, i.e. once both
    // sessions have built their display — which is what produced two displays
    // 340 ms apart and two audio streams into one iPad (the echo). Absent
    // (nil), the session proceeds, so nothing changes for a sender built
    // without a controller.
    @MainActor var admitSession: ((PhoneInfo) -> Bool)?
    // Fired when the user stopped the capture from the system UI (menu-bar
    // recording indicator / "Stop Extending"). The controller disconnects
    // the session — teardown plus auto-connect opt-out — so the app honors
    // the stop instead of fighting it.
    @MainActor var onCaptureStoppedByUser: (() -> Void)?
    // Fired when the device's display identity had to be abandoned (macOS
    // saved hostile state for it — see setupExtend) and a bumped identity
    // came online instead: carries the validated TOTAL offset from the
    // device's base identity, for the controller to store as-is. Absolute,
    // not a delta — repeated bumps in one session must not accumulate into
    // an offset nothing ever validated.
    @MainActor var onDisplayIdentityBumped: ((UInt32) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var connection: NWConnection?
    private var virtualDisplay: VirtualDisplay?

    /// **The only way this sender lets go of a display.**
    ///
    /// Round 9 ended with two orphaned `CGVirtualDisplay`s registered with
    /// WindowServer — CoreGraphics reporting displays with empty localized
    /// names while the real monitor had dropped out of
    /// `CGGetOnlineDisplayList` — because "release the display" was `= nil` in
    /// one place and nothing at all in several others. Every path that stops
    /// using a display calls this, and `VirtualDisplay.release()` is idempotent
    /// so calling it twice is free. `VirtualDisplayRegistry` covers the paths
    /// where no Swift of ours runs at all (a signal, `exit`, an uncaught
    /// exception).
    private func releaseVirtualDisplay(_ reason: String) {
        guard let vd = virtualDisplay else { return }
        virtualDisplay = nil
        vd.onLost = nil
        Log.info("releasing virtual display \(vd.displayID): \(reason)")
        vd.release()
    }

    private let queue = DispatchQueue(label: "sender.video")
    /// Audio runs on its own queue: sharing the video queue would let an
    /// encode hiccup on either stream stall the other, and video is the one
    /// with a frame deadline.
    private let audioQueue = DispatchQueue(label: "sender.audio")
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    /// What this session does to the desktop: `remote`, `extend` or `mirror`.
    /// Resolved once at session start (like `quality` and `frameRate`), so a
    /// change in the panel applies to the next session.
    let layout: SessionLayout
    /// Which defaults key the layout came from, for the capture-start line.
    /// Purely diagnostic — nothing branches on it.
    private let layoutSource: SessionLayout.Source
    /// Which display the pipeline captures. Derived, never stored separately:
    /// `remote` and `extend` are both extend captures and differ only in what
    /// the sender does with the display's origin.
    private var mode: CaptureMode { layout.captureMode }
    private let quality: StreamQuality
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple OpenDisplay monitors apart and persist their arrangement.
    private let displaySerial: UInt32
    // How far this device's identity has already moved off its base serial
    // and productID (identities macOS saved hostile state for are abandoned
    // permanently — see setupExtend). Advanced in-session when a fallback
    // identity is validated, so a rotation rebuild doesn't re-probe the
    // poisoned one.
    private var baseIdentityOffset: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 1) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously. If ScreenCaptureKit delivers the next frame
    // before the previous encode callback fires, VideoToolbox will run multiple
    // encodes in parallel inside the same session.
    //
    // Capping pendingEncodes at 1 enforces “latest frame wins” on the encoder:
    // skip captures while an encode is in flight (enc drops), then feed the next
    // fresh buffer when the callback clears the slot. The H.264 reference chain
    // stays valid (pre-encode skip → normal P-frame n→n+2); we do NOT force
    // keyframes on enc drops.
    private var pendingEncodes = 0
    private let maxPendingEncodes = 1

    // ── Latency-first send queue (see Mac/VideoSendQueue.swift) ─────────────
    //
    // Round 8 counted outstanding sends and, at a cap of 3, threw away the next
    // *capture*. That keeps the three oldest frames and discards everything
    // newer, which on a stalled relay means the receiver eventually decodes a
    // picture from seconds ago — the operator's `fps 1` against `capFps 28`.
    //
    // The queue keeps at most one write in flight and two frames waiting, and a
    // third arrival evicts the **oldest**. Latency is bounded by construction,
    // the newest picture always wins, and an eviction asks for an IDR (throttled
    // to one a second) because dropping an encoded frame breaks the reference
    // chain.
    //
    // `net↓` keeps its meaning — "the link could not take this frame" — it is
    // just counted at the queue now instead of at the capture callback.
    private var sendQueue = VideoSendQueue<Data>()
    private var keyframeAfterDrop = KeyframeAfterDropPolicy()
    /// When the write currently in flight started, for the sender-local
    /// "the socket is not taking bytes" signal. Zero when nothing is in flight.
    private var writeStartedAt: CFTimeInterval = 0
    /// Completion latencies over the current adaptive tick, ms.
    private var writeCompletionsThisTick: [Double] = []
    /// Bytes whose send completion fired since the last adaptive tick.
    private var bytesDeliveredTotal = 0
    private let maxSendQueueDepth = SendQueuePolicy.capacity
    private let pipelineLock = NSLock()
    /// `sendQueue.depth`, republished from `queue` under `pipelineLock` for the
    /// audio path and the ping line, which run elsewhere.
    private var sendQueueDepthPublished = 0
    private var dropsEncThisWindow = 0
    private var dropsNetThisWindow = 0
    private var dropsEncTotal = 0
    private var dropsNetTotal = 0
    private var needsKeyframe = true
    private var connectionReady = false {
        didSet {
            refreshAudioGate()
            guard connectionReady != oldValue else { return }
            let up = connectionReady
            Task { @MainActor in self.onConnectedChange?(up) }
        }
    }

    /// Whether this sender's socket is actually up, published to the
    /// controller. Round 6's Bonjour bug turned on the difference between "a
    /// session exists" and "a session is connected": a `-host`/`-port` sender
    /// spent an evening logging `Connection refused — will retry` while
    /// suppressing the LAN dial of the same iPad. `SessionDedupe` now asks, so
    /// somebody has to answer.
    @MainActor var onConnectedChange: ((Bool) -> Void)?
    /// Fired when this sender can actually put audio frames on the wire.
    ///
    /// This deliberately differs from `onConnectedChange`: a persistent
    /// dialer may have no connection, and a socket may be up before the peer's
    /// hello proves it supports tagged audio frames. The controller uses this
    /// signal to silence whichever output device is currently selected.
    @MainActor var onAudioDeliveryChange: ((Bool) -> Void)?
    /// System-audio capture and encode. Nil until a session enables audio.
    /// Touched only on `audioQueue`.
    private var audioEncoder: AudioEncoder?
    /// Whether the user wants audio streamed.
    ///
    /// Read-only here, and read fresh at capture setup rather than cached:
    /// SenderController owns the setting and restarts capture when it changes,
    /// so this always sees the current value and there is only ever one writer.
    private var audioEnabled: Bool { AudioPolicy.streamAudioEnabled }
    /// `loggedAudioUnsupportedPeer` is audio-queue-only; `becomeReady` clears
    /// it through `audioQueue.async` rather than writing it directly.
    private var loggedAudioUnsupportedPeer = false
    /// The connection `becomeReady` last ran its per-connection resets for.
    /// `queue` only.
    private var readyConnection: ObjectIdentifier?

    // MARK: - Audio/video queue boundary
    //
    // Audio capture runs on `audioQueue` and everything it needs to know about
    // the connection is decided on `queue`. Exactly two values cross, both
    // behind `audioLock`: the gate (may audio go out at all) and the packet
    // counters the stats line reports. Nothing else is shared — the send
    // itself hops back to `queue`, which is the only executor that may touch
    // `connection`.
    private let audioLock = NSLock()
    /// `connectionReady && peerSpeaksTaggedFrames`, republished from `queue`
    /// whenever either changes. The audio path reads only this.
    /// Keep a dial that cannot reach its receiver from owning the log. One per
    /// failure mode: a timeout and a refusal are different news, and they
    /// arrive at very different rates.
    private var dialTimeoutLog = RedialLogThrottle()
    private var dialWaitingLog = RedialLogThrottle()
    private var audioGateOpen = false
    /// Why, in words — published with the gate so the audio queue can say
    /// something true without reaching across the boundary for the two fields.
    private var audioGateReason = "no connection"
    /// The last state this was logged in, so transitions are logged once.
    /// `queue` only.
    private var loggedAudioGate: Bool?
    private var audioPacketsSent = 0
    private var audioDropsThisWindow = 0
    /// `audioLock`-guarded mirror of `peerWantsAudioSequence`, read by the
    /// encoder on `audioQueue` when it stamps a packet.
    private var peerWantsAudioSequenceForEncoder = false
    /// The next sequence number to hand out. `audioQueue` only — it is
    /// incremented exactly where the packet is built, so no two packets can
    /// ever carry the same number, which is the whole property the receiver
    /// relies on.
    private var nextAudioSequence: UInt32 = 0

    /// Whether this connection's receiver asked for sequence-stamped audio
    /// packets. `queue` only; mirrored across the lock for the encoder.
    private var peerWantsAudioSequence = false

    /// Whether this connection's receiver speaks tagged framing (protocol 4+).
    ///
    /// Per-connection, and false until the receiver's `hello` proves otherwise:
    /// the handshake itself cannot be tagged, because at the moment we send it
    /// we do not yet know what the peer understands. Reset on every new
    /// connection — a reconnect may reach a different device, and a stale true
    /// here would tag frames at a receiver that cannot read them.
    private var peerSpeaksTaggedFrames = false { didSet { refreshAudioGate() } }

    /// Republish the audio gate. Cheap enough to run from a `didSet`: both
    /// inputs change on connection transitions, never per frame.
    private func currentAudioGateState() -> Bool {
        audioLock.lock()
        defer { audioLock.unlock() }
        return audioGateOpen
    }

    private func refreshAudioGate() {
        let open = AudioDeliveryPolicy.isActive(connectionReady: connectionReady,
                                                peerSpeaksTaggedFrames: peerSpeaksTaggedFrames)
        audioLock.lock()
        let changed = audioGateOpen != open
        audioGateOpen = open
        audioGateReason = Self.audioGateReason(connectionReady: connectionReady,
                                               peerSpeaksTaggedFrames: peerSpeaksTaggedFrames)
        let reason = audioGateReason
        audioLock.unlock()
        if changed {
            // Read the current gate again on delivery. Two rapid transitions
            // can enqueue two unstructured MainActor tasks, whose execution
            // order is not a contract; reading the lock-protected current
            // value prevents an old `true` callback from re-muting the host
            // after a newer disconnect.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onAudioDeliveryChange?(self.currentAudioGateState())
            }
        }
        // **Logged on every transition, on both sides.** Round 5's Mac log
        // repeated `audio: receiver not ready for audio frames — audio not
        // sent` every eight seconds for three minutes and never once said what
        // "not ready" meant. It had two possible causes with completely
        // different fixes — a receiver too old to read tagged frames, and a
        // connection whose receiver has not said `hello` at all — and the line
        // could not tell them apart. (It was the second: the iPad app had been
        // backgrounded and iOS was accepting the Mac's TCP connections without
        // the suspended app ever adopting one.)
        guard loggedAudioGate != open else { return }
        loggedAudioGate = open
        Log.info("audio gate: \(open ? "OPEN" : "closed") — \(reason)")
    }

    /// Why the gate is where it is, in words, computed from the two inputs.
    static func audioGateReason(connectionReady: Bool, peerSpeaksTaggedFrames: Bool) -> String {
        switch (connectionReady, peerSpeaksTaggedFrames) {
        case (false, _):
            return "no connection"
        case (true, false):
            return "the connection is up but the receiver has not said hello yet "
                 + "(audio frames only exist in tagged framing, pv \(WireProtocol.taggedFrameVersion)+)"
        case (true, true):
            return "connection ready and the receiver speaks tagged framing "
                 + "(pv \(WireProtocol.taggedFrameVersion)+)"
        }
    }
    private var stopped = false
    // The liveness monitors are self-rescheduling chains guarded only by
    // `stopped`; arm them at most once per instance so a double start() can't
    // stack parallel loops (the failure mode behind #75). Mirrors the
    // `monitorsStarted` guard the iOS PhoneReceiver already uses.
    private var monitorsStarted = false

    // Disconnect detection: before the first connection we dial patiently
    // (the user may start the Mac side first); once connected, a device that
    // stays gone past the grace ends the session via onDisconnected.
    private var everConnected = false
    private var disconnectedSince: Date?
    private let disconnectGraceSeconds: TimeInterval = 10

    private var lastHello: PhoneInfo?
    private var helloContinuation: CheckedContinuation<PhoneInfo, Error>?
    // The injector is created by the capture setup task, used from the
    // connection's receive queue, and reset from the main actor — three
    // executors, so the *reference* needs its own guard even though the
    // injector serializes its own state (review #4). Replacing it always
    // resets the outgoing one first: a rebuilt display must not leave the old
    // injector's buttons, modifiers or auto-repeat held forever.
    private let injectorLock = NSLock()
    private var _inputInjector: InputInjector?
    private var inputInjector: InputInjector? {
        injectorLock.lock()
        defer { injectorLock.unlock() }
        return _inputInjector
    }

    private func replaceInputInjector(_ new: InputInjector?) {
        injectorLock.lock()
        let old = _inputInjector
        _inputInjector = new
        let size = encodedSize
        injectorLock.unlock()
        old?.reset()
        // Scroll deltas arrive in encoded-video pixels, so a fresh injector
        // needs the size the receiver is measuring against — the capture may
        // have been configured before this injector existed (the rotation
        // path rebuilds capture first).
        if size.wide > 0 { new?.setEncodedSize(pixelsWide: size.wide, pixelsHigh: size.high) }
    }

    /// Dimensions of the stream currently being encoded, i.e. the "video
    /// pixels" the protocol's coordinate section is written in. Guarded by
    /// `injectorLock` because capture setup and the control queue both touch it.
    private var encodedSize: (wide: Int, high: Int) = (0, 0)

    private func noteEncodedSize(pixelsWide: Int, pixelsHigh: Int) {
        injectorLock.lock()
        encodedSize = (pixelsWide, pixelsHigh)
        let injector = _inputInjector
        injectorLock.unlock()
        injector?.setEncodedSize(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }

    /// Ends the input epoch: everything the receiver was holding is released
    /// now, not when a replacement session finally reaches `becomeReady()` or
    /// the disconnect grace expires. Ordinary connection loss used to leave
    /// buttons, modifiers, Pencil proximity and — worst — auto-repeat live for
    /// up to the full grace period, typing into the Mac's only display while
    /// the iPad was already gone (review #3).
    private func endInputEpoch(_ reason: String) {
        guard let injector = inputInjector else { return }
        Log.info("releasing held input: \(reason)")
        injector.reset()
    }

    // Liveness: both sides ping every 2s; if nothing arrives for 5s the link
    // is half-open (e.g. usbmuxd accepted but the device is gone) — reconnect.
    private var lastReceived = Date()

    // Session created after the receiver went to sleep: it refuses
    // connections until its screen is back, so dial failures mean "asleep",
    // not "app closed" — surface that instead of the usual hints. Cleared by
    // the first successful connection.
    private var awaitingWake: Bool

    // A capture that keeps dying is not coming back on its own (capture
    // authorization revoked, or saved display state blocks the identity) —
    // retrying forever spams WindowServer with create/destroy cycles and,
    // after a user-initiated stop, amounts to defying the user. Counted per
    // failed recovery round, reset by a capture that comes back up. On
    // `queue`.
    private var captureRecoveryFailures = 0
    private let maxCaptureRecoveryFailures = 5

    // Consecutive actively-refused dials on a previously connected session.
    // Refusal is unambiguous: the device is reachable but nothing listens,
    // so the app was quit (a suspended app's kernel still accepts, and a
    // network blip times out instead of refusing). Three in a row (~3s)
    // ends the session early; the full 10s grace stays reserved for the
    // ambiguous failure kinds.
    private var consecutiveRefusals = 0
    private let refusalsBeforeGivingUp = 3
    private var dropsTotal: Int { dropsEncTotal + dropsNetTotal }

    // Local cursor echo: a cursor baked into the video carries the full
    // capture→encode→stream→display latency (~30ms perceived). Instead we
    // hide it from capture and stream its position on the control channel —
    // the phone draws it locally on the ~2ms path the touches use.
    // Escape hatch: `defaults write com.peetzweg.opensidecar.mac localCursor -bool false`.
    private let localCursor = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    // Cable upgrade (PROTOCOL.md 6.4): while a WiFi session runs, probe the
    // receiver's advertised addresses over non-WiFi paths and migrate the
    // session the moment one answers — the Mac-to-Mac analogue of the
    // iPhone's WiFi→USB transport switch. All confined to `queue`.
    private var upgradeTimer: DispatchSourceTimer?
    private var upgradeProbes: [NWConnection] = []
    private var probeRoundGeneration = 0
    private var lastLoggedCandidates: [String] = []
    private var peerAddrs: [String] = []
    // The Mac-to-Mac USB link takes ~25-30s to negotiate, and either side
    // can finish last. Peer-side lateness arrives as a re-hello; this
    // monitor catches OUR side coming up, so a probe fires the moment the
    // local interface is routable instead of up to 10s later.
    private var wiredPathMonitor: NWPathMonitor?
    // Probing is gated on this, not on wired-ness: the upgrade exists to get
    // OFF WiFi, and any non-WiFi path (bridge, USB-C link, even loopback)
    // is already as good as a probe could find — re-probing there would
    // migrate in a circle.
    private var currentPathUsesWiFi = false
    // Set while the live session rides the direct cable link (USB-C /
    // Thunderbolt host-to-host to a Mac receiver, link-local addressed).
    // Losing that link is treated as intent — see linkDied(). A merely-
    // wired path (a docked Mac on Ethernet streaming to a phone on WiFi)
    // must NOT count: silence there is a backgrounded receiver or the
    // phone's radio, and undocking should fall back to WiFi like it always
    // has. Computed by refreshDirectLinkClassification, cleared the moment
    // the session decides to redial (scheduleReconnect/switchTransport):
    // dial-phase failures take the grace/refusal rules, never this exit.
    private var currentPathDirectLink = false
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    // Cursor side channel (UDP, WiFi only): positions queue behind video
    // frames on the shared TCP socket and stutter under head-of-line
    // blocking. Opened when hello advertises cursorPort; while ready,
    // pollCursorPosition sends there instead. Sprites stay on TCP (up to
    // 24 KB, must arrive intact). All state lives on `queue`.
    private var cursorConnection: NWConnection?
    private var cursorChannelPort: NWEndpoint.Port?
    // True once the receiver acked a datagram (cursorAck). Until then every
    // position also rides TCP: UDP .ready proves only a local route, and a
    // silently firewalled port must not eat the cursor. Duplicates are
    // harmless — both paths carry the same sequence and the receiver drops
    // whatever is not newer.
    private var cursorChannelConfirmed = false
    private var cursorConnectionReady = false
    private var cursorSeq: UInt64 = 0
    private var captureDisplayID: CGDirectDisplayID = 0
    // ScreenCaptureKit and VideoToolbox finish work asynchronously. During a
    // rotation, an old capture callback or a late encoder completion must not
    // put a frame from the retired display onto this device's new socket.
    // Bumped on `queue` but read from the SCK sample queue and the VideoToolbox
    // callback queue, so it lives under `pipelineLock` like the other counters
    // those callbacks touch — read it via `captureGenerationNow`.
    private var captureGeneration: UInt64 = 0
    private var captureGenerationNow: UInt64 {
        pipelineLock.lock()
        defer { pipelineLock.unlock() }
        return captureGeneration
    }

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // These policies bound noisy paths while retaining an explicit record when
    // details were suppressed. Unknown types and unparseable messages live on
    // `queue` with the rest of the control-connection state; encoder failures
    // are guarded by `pipelineLock` with the other pipeline counters.
    private var unknownTypeLogPolicy = UnknownControlTypeLogPolicy()
    // Encode failures repeat every frame once the session goes bad; throttle
    // the log to one line a second and carry the count.
    private var encodeFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // Same for the encoder output callback rejecting a frame; separate policy
    // so "submit failed" and "output rejected" stay distinguishable.
    private var encodeOutputFailureLogPolicy = ThrottledLogPolicy<OSStatus>()
    // A framing desync feeds this garbage at the peer's message rate until the
    // watchdog redials, so it needs the same treatment. Detail is the byte
    // count of the last message that would not parse.
    private var unparseableControlLogPolicy = ThrottledLogPolicy<Int>()
    // Capture cadence: SCK only emits on content change, so the phone can't
    // tell "Mac rendered 45fps" from "frames got lost" — count deliveries here.
    private var capFrames = 0
    private var capWindowStart = Date()

    // ── Adaptive quality (see Mac/AdaptiveQuality.swift) ────────────────────
    //
    // All of this lives on `queue`, with the encoder and the send queue it
    // reads. The controller itself is pure; what is here is the sampling, the
    // three effects (a live VideoToolbox bitrate write, a capture-rate change
    // and a capture-scale change) and the two log lines.
    private let adaptiveEnabled = AdaptiveQualityController.isEnabled
    private let adaptiveFloorKbps = AdaptiveQualityController.floorKbps
    /// How deep the ladder may go (`adaptiveMaxLever`, default `frameRate`).
    /// Read once per sender so a `defaults write` mid-session cannot change the
    /// ladder under a live plan.
    private let adaptiveMaxLever = AdaptiveQualityController.maxLever
    /// Nil until the first capture has sized the plan — the ladder's rungs are
    /// fractions of the encoded size, which is not known until then.
    private var adaptive: AdaptiveQualityController?
    /// Cumulative counters as of the previous tick, so a tick can be a delta.
    private var lastAdaptiveCounters = (enc: 0, frames: 0, bytes: 0)
    private var lastAdaptiveTickAt: CFTimeInterval = 0
    /// Frames submitted to the encoder, ever.
    private var framesEncodedTotal = 0
    /// The most recent receiver `stats` report and when it landed. Consumed
    /// once — reports arrive every 5 s at best, and counting one of them on
    /// every 0.5 s tick in between would read one bad window as ten.
    private var receiverReport: ReceiverReport?
    private var receiverReportAt: Date?
    /// Which copy of each report won the race, TCP or the UDP cursor flow.
    private var statsDedupe = StatsDedupe()
    private var loggedStatsPath = false
    /// What the settings asked for, before any adaptation. Captured when the
    /// encoder is built so the ceiling is always the configured value rather
    /// than the last thing we wrote.
    private var configuredBitrate = 0
    /// Frames per second to hand the encoder, when adaptation has capped it.
    /// Nil is "whatever capture delivers", which is the configured rate.
    private var deliveredFrameCap: Int?
    private var lastDeliveredFrameAt: CFTimeInterval = 0
    private var adaptiveMonitorStarted = false
    /// When the panel line was last printed.
    private var lastAdaptivePanelAt: CFTimeInterval = 0
    /// The capture scale in force right now. Starts at the configured
    /// `quality` and is the one thing adaptation may move: the **virtual
    /// display keeps its mode**, so the desktop does not reflow.
    private var activeScale: StreamQuality
    /// Set while a capture reconfiguration is in flight so two cannot race.
    private var captureReconfiguring = false
    /// Bumped per reconfiguration so a late completion cannot clear a newer
    /// one's gate, and so the timeout below can tell whose gate it is holding.
    private var captureReconfigureGeneration: UInt64 = 0
    /// How long `SCStream.updateConfiguration` gets to answer before the gate
    /// is released anyway. Generous: this is a deadlock breaker, not a policy.
    private let captureReconfigureTimeout: TimeInterval = 10
    /// The size the live compression session was built for. A capture whose
    /// size does not match rebuilds it before the frame is handed over, which
    /// is what makes the scale change safe in either order.
    private var encoderSize: (wide: Int, high: Int) = (0, 0)
    /// True once the path class has been settled from a measured RTT.
    private var pathClassSettled = false
    /// When the operating point was last written to defaults, so a stable
    /// session does not write once a second.
    private var lastOperatingPointWriteAt: CFTimeInterval = 0
    /// The frame rate the live `SCStreamConfiguration` was last set to, so a
    /// reconfiguration that would change nothing is not sent.
    private var lastConfiguredCaptureFps = 0

    private var framesSent = 0
    private var bytesSent = 0
    private var statsWindowStart = Date()

    // ScreenCaptureKit emits frames only when content changes. After a
    // reconnect on a static screen there is nothing to hang the forced
    // keyframe on — so keep the last frame around and re-encode it.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    /// Debounced replay after encoder/send backpressure drops a frame.
    /// At most one timer is active; each new drop resets the 30ms deadline.
    private var dropReplayTimer: DispatchSourceTimer?

    let frameRate: FrameRate

    init(transport: SenderTransport, name: String, layout: SessionLayout,
         layoutSource: SessionLayout.Source = .forkDefault,
         quality: StreamQuality = .best, frameRate: FrameRate = .forkDefault,
         displaySerial: UInt32 = 0x0001,
         identityOffset: UInt32 = 0, awaitingWake: Bool = false) {
        self.transport = transport
        self.endpointName = name
        self.layout = layout
        self.layoutSource = layoutSource
        self.quality = quality
        self.activeScale = quality
        self.frameRate = frameRate
        self.displaySerial = displaySerial
        self.baseIdentityOffset = identityOffset
        self.awaitingWake = awaitingWake
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        stopped = false
        queue.async { self.connect() }   // dial state lives on `queue`
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
            scheduleAdaptiveTick()
        }

        // Screen Recording permission: poll until granted. No auto-prompt at
        // launch — the permission panel's Grant button triggers the system
        // dialog, so the request always has visible context.
        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording permission needed — see Permissions below")
            Log.info("Screen Recording permission missing — waiting for grant via the permission panel")
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(2))
                if stopped { return }
            }
            Log.info("Screen Recording permission granted")
        }

        switch mode {
        case .mirror:
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "MacSender", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no displays found"])
            }
            // SCDisplay.width/height are POINTS. Capturing at points on a
            // Retina panel discards half the raster before the encoder ever
            // sees it, and no quality setting can bring it back — read the
            // true pixel size from the active display mode.
            let displayMode = CGDisplayCopyDisplayMode(display.displayID)
            let pixelsW = displayMode?.pixelWidth ?? display.width
            let pixelsH = displayMode?.pixelHeight ?? display.height
            let captureW = (Int(Double(pixelsW) * activeScale.scale)) & ~1
            let captureH = (Int(Double(pixelsH) * activeScale.scale)) & ~1
            try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        case .extend:
            // awaitingWake is queue-confined — read it there before surfacing.
            queue.async { [weak self] in
                guard let self else { return }
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for the device to connect…"
                Task { await self.status(text) }
            }
            let info = try await waitForHello()
            // Before the display, before the encoders, before a single audio
            // packet: may this session exist at all? See `admitSession`.
            let admitted = await MainActor.run { self.admitSession?(info) ?? true }
            guard admitted else {
                Log.info("standing down before building anything: "
                    + "another session already serves receiver \(info.id ?? "(unidentified)")")
                throw SessionSuperseded()
            }
            try await setupExtend(info)

            // Touch back-channel (Milestone 3). Needs Accessibility trust;
            // streaming works without it, so don't interrupt with a prompt —
            // the permission panel's Grant button asks when the user is ready.
            if !AXIsProcessTrusted() {
                await status("Extending — grant Accessibility for touch input")
                // Event posting is trust-checked per-post, so it starts working
                // the moment the user grants — poll just to log/report it.
                while !AXIsProcessTrusted() {
                    try await Task.sleep(for: .seconds(2))
                    if stopped { return }
                }
                Log.info("Accessibility permission granted — touch input live")
            }
        }
    }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupExtend(_ info: PhoneInfo) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        // Phone panel is @3x; the virtual display runs @2x HiDPI, so points
        // = native pixels / 2 (rounded down to even for the encoder).
        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        // Rough physical size so macOS picks a sane default UI scale.
        let mm = info.pixelsWide >= info.pixelsHigh
            ? CGSize(width: 147, height: 68)
            : CGSize(width: 68, height: 147)

        // USB sessions can start before lockdown resolves the device name —
        // fall back to the kind from the hello rather than the generic label.
        let displayName = endpointName.hasPrefix("iPhone / iPad")
            ? "OpenDisplay — \(info.kind)"
            : "OpenDisplay — \(endpointName)"
        // Keep one stable identity across rotations. Reconfiguration below
        // applies a new mode to the existing virtual monitor, so macOS keeps
        // its windows and arrangement attached to this physical device.
        let serial = displaySerial
        // Arrangement memory (#116): keyed on the device's install id so the
        // display returns to its spot across transports and orientations —
        // the serial-keyed memory macOS keeps starts from scratch whenever
        // the serial changes. Old receivers without an id fall back to the
        // session serial, which is at least orientation-stable.
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let sizeInPoints = CGSize(width: pointsWide, height: pointsHigh)
        // Creating a display whose serial is still registered fails — e.g. a
        // just-quit instance's display lingers in WindowServer for a moment
        // after the process dies. Retry through that window instead of
        // parking the session on "Failed" until a manual reconnect.
        //
        // macOS also keys SAVED display state on this identity, and that
        // state can be hostile: the system UI's "Stop Extending" records a
        // config under which the identity never comes online again —
        // creation "succeeds" but the display joins neither the active
        // display list nor shareable content (#206, #221). Unlike the saved
        // mirror-set (#100) and 1x-mode variants, no post-creation
        // enforcement can undo that, so an identity that never surfaces is
        // abandoned for a fresh serial. The controller persists the working
        // offset, so the device skips its poisoned identities from then on.
        var vd: VirtualDisplay?
        var display: SCDisplay?
        var identityError = NSError(domain: "MacSender", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        // Only a created-but-never-surfaced display proves the identity is
        // poisoned. Creation refusing outright usually means a twin still
        // holds the serial (just-quit instance, parallel debug build) —
        // moving to a fallback identity is fine for THIS session, but the
        // move must not be persisted over a merely-transient condition.
        var sawPoisonedIdentity = false
        identities: for probe in 0..<UInt32(3) {
            let totalOffset = baseIdentityOffset &+ probe
            // A lingering serial belongs to a just-quit twin of the CURRENT
            // identity; fresh fallback identities get a shorter window.
            var created: VirtualDisplay?
            for attempt in 0..<(probe == 0 ? 8 : 3) {
                if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
                // A Disconnect during the retry window tore the session down. Bail
                // before creating/assigning the display: the serial the old display
                // held is likely free now, so a late attempt would *succeed* and
                // resurrect the very zombie this retry exists to avoid. (Mirrors the
                // `if stopped` checks in the permission-poll loops above.)
                if stopped { return }
                created = await MainActor.run {
                    // `remote` keeps no arrangement memory at all: it neither
                    // reads a saved origin nor writes one. That is not tidiness
                    // — the saved restore is what moved the display off (0,0)
                    // two seconds after it was put there, session after
                    // session.
                    let policy: VirtualDisplay.OriginPolicy = self.layout.remembersArrangement
                        ? .remembered(restore: DisplayArrangement.origin(for: sizeInPoints,
                                                                         device: arrangementKey),
                                      onChange: { origin, currentSize in
                                          DisplayArrangement.save(origin: origin, size: currentSize,
                                                                  device: arrangementKey)
                                      })
                        : .pinnedToMain
                    // The productID moves with the serial: field data in #206
                    // suggests some macOS versions key the hostile state on
                    // the product, not the serial — bumping both escapes
                    // either keying.
                    return VirtualDisplay(name: displayName,
                                          pointsWide: pointsWide, pointsHigh: pointsHigh,
                                          sizeInMillimeters: mm,
                                          targetFPS: Double(self.frameRate.rawValue),
                                          serialNum: serial &+ totalOffset,
                                          productID: 0x4F53 &+ totalOffset,
                                          originPolicy: policy)
                }
                if created != nil { break }
                Log.info("virtual display creation failed (identity +\(totalOffset), attempt \(attempt + 1)) — retrying")
                await status("Preparing virtual display…")
            }
            guard let candidate = created else { continue }
            // A Disconnect can land while the creation above is awaiting the
            // main actor. Adopting the candidate then would resurrect a display
            // for a session `stop()` has already torn down, and nothing would
            // ever release it.
            guard !stopped else {
                candidate.release()
                return
            }
            // A previous probe's display, if any, goes back before this one is
            // adopted — two live CGVirtualDisplays for one session is exactly
            // the state round 9 left the machine in.
            releaseVirtualDisplay("replaced by a fresh identity (+\(totalOffset))")
            virtualDisplay = candidate
            // The display is *coming up*: for the next five seconds it is
            // legitimately not queryable, and its own enforcement tick must not
            // read that as "the @2x mode vanished" and start re-publishing
            // settings underneath the poll. That fight is what ended round 9 —
            // see `VirtualDisplay.beginReconfiguration`.
            await MainActor.run { candidate.beginReconfiguration() }
            do {
                display = try await findSCDisplay(id: candidate.displayID)
                await MainActor.run { candidate.endReconfiguration() }
                vd = candidate
                if probe > 0, sawPoisonedIdentity {
                    Log.info("display identity +\(totalOffset) came online — the previous one is "
                        + "poisoned by saved system state; persisting the offset")
                    baseIdentityOffset = totalOffset   // rebuilds skip the dead probe
                    Task { @MainActor in self.onDisplayIdentityBumped?(totalOffset) }
                }
                break identities
            } catch {
                await MainActor.run { candidate.endReconfiguration() }
                releaseVirtualDisplay("identity +\(totalOffset) never came online")
                // No shareable displays at all is a permission-side failure —
                // a different identity cannot help there.
                if (error as NSError).domain == "MacSender", (error as NSError).code == 4 { throw error }
                identityError = error as NSError
                sawPoisonedIdentity = true
                if stopped { return }
                Log.info("virtual display (identity +\(totalOffset)) never came online — trying a fresh identity")
                await status("Display blocked by saved macOS state — trying a fresh identity…")
            }
        }
        guard let vd, let display else {
            if sawPoisonedIdentity {
                throw NSError(domain: "MacSender", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "saved display state in macOS is blocking "
                        + "OpenDisplay's displays — log out and back in (or restart the Mac), then reconnect"])
            }
            throw identityError
        }
        replaceInputInjector(InputInjector(displayID: vd.displayID))
        // Enforcement gives up rather than spinning (round 9's thirty
        // `applySettings:` in seven seconds). When it does, this is where the
        // session hears about it, and the answer is a rebuild around a fresh
        // display — not another enforcement loop.
        await MainActor.run { [weak self] in
            // `[weak self]` on the *inner* closure as well: the display holds
            // this handler, and a strong sender inside it would be a cycle
            // (display → handler → sender → display) that keeps a
            // CGVirtualDisplay alive after the session is gone — the exact
            // failure this round is about.
            vd.onLost = { [weak self] reason in
                guard let self else { return }
                self.queue.async { self.handleDisplayLost(reason) }
            }
        }
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        var captureW = (Int(Double(pointsWide * 2) * activeScale.scale)) & ~1
        var captureH = (Int(Double(pointsHigh * 2) * activeScale.scale)) & ~1
        // hello.maxEncodeWide/High (PROTOCOL.md 6.5): a big panel does not
        // imply a big decoder. Cap the stream at the receiver's advertised
        // decode ceiling — SCK scales the capture — while the desktop keeps
        // its announced size.
        if let maxW = info.maxEncodeWide, let maxH = info.maxEncodeHigh,
           maxW > 0, maxH > 0, captureW > maxW || captureH > maxH {
            let s = min(Double(maxW) / Double(captureW), Double(maxH) / Double(captureH))
            captureW = (Int(Double(captureW) * s)) & ~1
            captureH = (Int(Double(captureH) * s)) & ~1
            Log.info("stream capped at \(captureW)x\(captureH) by the receiver's decode ceiling \(maxW)x\(maxH)")
        }
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        // Debug aid (`defaults write com.peetzweg.opensidecar.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }

        gatherWindowsOncePinned(displayID: vd.displayID)
    }

    // MARK: - Gathering the desktop onto the session display

    private let windowGatherer = WindowGatherer()
    /// One gather per session. A rotation rebuilds the display but not the
    /// desktop, and re-running the walk would only move windows the user had
    /// since arranged.
    private var windowsGathered = false

    /// Bring the open windows onto the session display, once the display has
    /// actually become the main one.
    ///
    /// **After the pin, never before.** `OriginPin` moves this display to
    /// `(0,0)` and lays the others out to its right; a gather that ran first
    /// would compute every destination against the arrangement the pin is about
    /// to replace, and would put the windows exactly where they already were.
    /// The pin runs synchronously at display creation (§36), so in practice
    /// this waits one poll — but "in practice" is what round 5 believed about
    /// the pin itself, so it is checked rather than assumed, with a ceiling.
    private func gatherWindowsOncePinned(displayID: CGDirectDisplayID) {
        guard layout == .remote, WindowGatherPolicy.enabled(), !windowsGathered else { return }
        windowsGathered = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            var waited = 0
            while waited < 20 {
                if self.stopped { return }
                if CGDisplayBounds(displayID).origin == .zero,
                   CGMainDisplayID() == displayID { break }
                try? await Task.sleep(for: .milliseconds(250))
                waited += 1
            }
            if self.stopped { return }
            guard CGMainDisplayID() == displayID else {
                Log.info("gather windows: display \(displayID) is not the main display after "
                         + "5s — not moving anything (see the `remote layout:` lines above)")
                return
            }
            self.windowGatherer.gather(onto: displayID)
        }
    }

    /// Tear down and rebuild when the phone announces new dimensions. Loops
    /// until the built display matches the latest hello, so rotations that
    /// arrive mid-rebuild aren't lost (and rapid flip-flops settle once).
    private var reconfiguring = false
    private func reconfigure(_ info: PhoneInfo) async {
        guard !reconfiguring, !stopped else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        var target = info
        // Round 9's `reconfigure failed: … virtual display never appeared in
        // SCShareableContent` returned here, and what it left behind was a
        // session with no stream, no encoder and a **live CGVirtualDisplay** —
        // one of the two orphans the operator then had to kill BetterDisplay to
        // get rid of. A failure now means: give the display back, build a new
        // one from nothing, and only if *that* fails is the session over.
        var rebuildFromScratch = false
        while !stopped {
            Log.info("reconfiguring for \(target.pixelsWide)x\(target.pixelsHigh)"
                     + (rebuildFromScratch ? " — from scratch, the in-place path failed" : ""))
            // A cached frame is valid for a network reconnect to the same
            // display, but never for a rotation: it belongs to the retired
            // desktop and can otherwise be replayed onto the new one.
            invalidateCapturePipeline(discardingLastFrame: true)
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            needsKeyframe = true
            do {
                if !rebuildFromScratch, try await resizeExistingDisplay(for: target) {
                    // The display identity survived, so WindowServer has no
                    // reason to migrate this device's windows to a sibling.
                } else {
                    // Safety fallback for a system that refuses an in-place
                    // mode switch. This keeps the old recovery behaviour.
                    releaseVirtualDisplay("rebuilding the pipeline from scratch")
                    try await setupExtend(target)
                }
            } catch {
                Log.info("reconfigure failed: \(error)")
                // Whatever went wrong, the display does not survive it. This is
                // the line round 9 did not have.
                releaseVirtualDisplay("reconfigure failed: \(error.localizedDescription)")
                guard !rebuildFromScratch, !stopped else {
                    await status("Display could not be rebuilt: \(error.localizedDescription)")
                    queue.async { [weak self] in
                        self?.reportGone("reconfigure failed twice (\(error.localizedDescription)) "
                                         + "— display released, ending session")
                    }
                    return
                }
                rebuildFromScratch = true
                await status("Rebuilding the display…")
                continue
            }
            if let latest = lastHello,
               latest.pixelsWide != target.pixelsWide || latest.pixelsHigh != target.pixelsHigh {
                target = latest   // rotated again while we were rebuilding
                continue
            }
            return
        }
    }

    /// `VirtualDisplay` enforcement gave up on this display. On `queue`.
    ///
    /// The wrapper deliberately does not heal itself — trying forever is the
    /// defect this round exists to remove — so the session answers instead, and
    /// the answer is a rebuild from nothing. Bounded by the same counter the
    /// capture-recovery loop uses, so a display that cannot be built stops the
    /// session rather than cycling WindowServer.
    private func handleDisplayLost(_ reason: String) {
        guard !stopped, mode == .extend, let hello = lastHello else { return }
        guard !displayLossHandled else { return }
        displayLossHandled = true
        Log.info("display lost (\(reason)) — releasing it and rebuilding the session")
        releaseVirtualDisplay("enforcement reported it lost: \(reason)")
        Task {
            await self.reconfigure(hello)
            self.queue.async { self.recoveryRoundEnded() }
        }
    }
    /// One rebuild per lost display; cleared when a capture comes back up.
    private var displayLossHandled = false

    /// Apply the rotated mode to the existing virtual monitor and restart
    /// only the capture/encoder pieces that depend on pixel dimensions.
    /// Returns false when there is no reusable display or macOS rejected the
    /// mode switch, letting the caller use the legacy rebuild fallback.
    private func resizeExistingDisplay(for info: PhoneInfo) async throws -> Bool {
        guard let vd = virtualDisplay else { return false }

        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let size = CGSize(width: pointsWide, height: pointsHigh)
        let didResize = await MainActor.run {
            // Same rule as creation: in `remote` the display goes back to the
            // origin, not to a remembered spot. `VirtualDisplay.resize`
            // enforces that itself (the policy is fixed at construction), so
            // nil here is the honest input rather than a second opinion.
            let origin = self.layout.remembersArrangement
                ? DisplayArrangement.origin(for: size, device: arrangementKey)
                : nil
            return vd.resize(pointsWide: pointsWide, pointsHigh: pointsHigh, movingTo: origin)
        }
        guard didResize else { return false }

        // **The five seconds that ended round 9.** `resize()` republishes the
        // mode list, and until WindowServer has finished bringing the display
        // back up `CGDisplayCopyAllDisplayModes` answers with nothing. The
        // enforcement tick read that as "the @2x mode vanished" and re-applied
        // the settings — restarting the very bring-up this poll is waiting to
        // see, five times a second, for as long as the poll ran. The poll could
        // not win, `findSCDisplay` threw, the log filled with thirty identical
        // lines, and WindowServer (which serialises display reconfiguration
        // process-wide) stopped serving loginwindow and the real monitor.
        //
        // Declaring the reconfiguration makes the tick stand down for exactly
        // as long as it lasts. It is `defer`red so the throw from
        // `findSCDisplay` cannot leave the display suspended forever.
        await MainActor.run { vd.beginReconfiguration() }
        let display: SCDisplay
        do {
            display = try await findSCDisplay(id: vd.displayID, expectedSize: size)
        } catch {
            await MainActor.run { vd.endReconfiguration() }
            throw error
        }
        await MainActor.run { vd.endReconfiguration() }
        let captureW = (Int(Double(pointsWide * 2) * activeScale.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * activeScale.scale)) & ~1
        // The injector is rebuilt BEFORE capture starts, as it is in
        // `setupExtend`. The display identity survives a resize so the id is
        // the same either way, but the capture-start line asserts that the
        // injector's target equals the captured display, and an assertion that
        // reads the *previous* injector is not one.
        replaceInputInjector(InputInjector(displayID: vd.displayID))
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
        return true
    }

    /// The virtual display takes a moment to show up in shareable content.
    private func findSCDisplay(id: CGDirectDisplayID, expectedSize: CGSize? = nil) async throws -> SCDisplay {
        var lastDisplayCount = 0
        for _ in 0..<20 {
            let content = try await SCShareableContent.current
            lastDisplayCount = content.displays.count
            if let display = content.displays.first(where: {
                $0.displayID == id
                    && (expectedSize == nil
                        || ($0.width == Int(expectedSize!.width)
                            && $0.height == Int(expectedSize!.height)))
            }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        // An empty display list is a different disease from "ours is
        // missing": capture authorization is broken app-wide, and callers
        // must not burn fallback identities on it.
        if lastDisplayCount == 0 {
            throw NSError(domain: "MacSender", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "macOS returned no capturable displays — "
                              + "the screen may be locked; if this persists unlocked, re-grant "
                              + "Screen Recording in System Settings and relaunch"])
        }
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent"])
    }

    /// Everything about an `SCStreamConfiguration` that depends on the size and
    /// the rate, in one place — so `startCapture` and the live reconfiguration
    /// adaptation asks for cannot drift apart.
    private func makeStreamConfiguration(pixelsWide: Int, pixelsHigh: Int,
                                         fps: Int, wantsAudio: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for double the target frame rate so SCK's rate limiter does not
        // skip frames that arrive a hair early (beat frequency) — measured
        // ~51fps instead of 60 when requested at 1/60.
        config.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(StreamTiming.captureIntervalTimescale(fps: fps)))
        // 420v matches the encoder's native input — skips a BGRA→YUV conversion
        // inside VideoToolbox. (`-pixfmt bgra` reverts for A/B testing.)
        config.pixelFormat = UserDefaults.standard.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor
        // System audio on the SAME stream as video, so both arrive stamped by
        // one capture clock and stay in sync without a second mechanism.
        // Excluding our own process keeps a Mac receiver's playback from being
        // captured and sent back to itself.
        config.capturesAudio = wantsAudio
        config.excludesCurrentProcessAudio = true
        return config
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        noteEncodedSize(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)

        // Clamp to what High@L5.2 permits for this encoded size before asking
        // ScreenCaptureKit for anything: delivering frames the encoder is about
        // to refuse would be work spent on a drop.
        let targetFPS = H264Level.effectiveFrameRate(requested: frameRate.rawValue,
                                                     width: pixelsWide, height: pixelsHigh)
        if targetFPS < frameRate.rawValue {
            Log.info("frame rate: \(frameRate.rawValue) requested, "
                     + "\(targetFPS) is the H.264 level 5.2 ceiling at \(pixelsWide)x\(pixelsHigh) — using \(targetFPS)")
        }
        let wantsAudio = audioEnabled
        let config = makeStreamConfiguration(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                             fps: deliveredFrameCap ?? targetFPS,
                                             wantsAudio: wantsAudio)

        invalidateCapturePipeline(discardingLastFrame: true)
        let generation = captureGenerationNow
        try setupEncoder(width: pixelsWide, height: pixelsHigh)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsAudio {
            // A failure here must not cost the user their display: log it and
            // stream video alone.
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
                // `async`, not `sync`: this runs before `startCapture()`, so on
                // a serial queue the encoder is in place before the first
                // sample can arrive, and nothing here ever waits on a queue
                // that is itself about to touch the pipeline lock.
                audioQueue.async { [weak self] in self?.audioEncoder = AudioEncoder() }
            } catch {
                Log.info("audio: stream output unavailable (\(error)) — video only")
            }
        } else {
            audioQueue.async { [weak self] in self?.audioEncoder = nil }
        }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if self.stream === stream { self.stream = nil }
            throw error
        }
        captureDisplayID = display.displayID
        lastConfiguredCaptureFps = deliveredFrameCap ?? targetFPS
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        // A capture that came back through any path (recovery, rotation,
        // identity fallback) earns the full recovery budget again — without
        // this, a pending recovery timer that finds the stream alive exits
        // without ever resetting the counter, and the next unrelated death
        // starts with as little as one round left.
        queue.async {
            self.captureRecoveryFailures = 0
            // A capture that is running again means the display underneath it
            // is healthy, so the next enforcement give-up is a new one.
            self.displayLossHandled = false
            self.rebuildAdaptivePlan(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
        }
        // `layout` is on this line for an external watchdog to read: it is the
        // one place the resolved value (defaults key, legacy `mode`, or the
        // fork default) is visible from outside the process — and `layoutFrom`
        // says WHICH of the three answered, which is the fact round 4's log
        // was missing when a stale `mode extend` quietly demoted the session.
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) "
            + "generation \(generation) mode \(mode.rawValue) layout \(layout.rawValue) "
            + "layoutFrom \(layoutSource.rawValue) (\(layoutSource.explanation)) "
            + "localCursor=\(localCursor)")
        // The geometry every injected touch is normalized against, printed
        // once per capture so an offset can be diagnosed from the log rather
        // than guessed at. `injectorDisplay` MUST equal `display` — the
        // injector is rebuilt with the new id on every path that changes it
        // (`setupExtend`, `resizeExistingDisplay`), and the cursor channel
        // normalizes against `captureDisplayID`, i.e. the same display.
        let injectorID = inputInjector?.targetDisplayID ?? 0
        let bounds = CGDisplayBounds(display.displayID)
        Log.info("input target: injector display \(injectorID) "
            + "(capture display \(display.displayID)), bounds "
            + "(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))), "
            + "main display \(CGMainDisplayID())"
            + (injectorID == display.displayID ? "" : " — MISMATCH, touches will be offset"))
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    func stop() {
        stopped = true
        // Before the display goes: put the gathered windows back where they
        // were. Best effort, on its own queue, and nothing here waits for it —
        // a window that will not move must not delay tearing a session down.
        if windowsGathered { windowGatherer.restore() }
        inputInjector?.reset()
        invalidateCapturePipeline(discardingLastFrame: true)
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorImageTimer?.cancel()
        cursorImageTimer = nil
        stream?.stopCapture { _ in }
        stream = nil
        connection?.cancel()
        connection = nil
        // The stream is gone, so no further audio callbacks; drop the encoder
        // with it rather than leaving an AVAudioConverter alive for a session
        // that has ended.
        audioQueue.async { [weak self] in self?.audioEncoder = nil }
        // Cursor-channel state is confined to `queue` (the 120Hz poll and the
        // UDP callbacks run there); tearing it down from the main actor races
        // them.
        queue.async { [weak self] in
            self?.closeCursorChannel()
            self?.stopUpgradeProbing()
        }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        releaseVirtualDisplay("session stopped")
        cancelDropReplayTimer()
        queue.async { [weak self] in
            // Unblock a start() that is still waiting for the hello.
            self?.helloContinuation?.resume(throwing: CancellationError())
            self?.helloContinuation = nil
        }
    }

    /// Migrate the live session to another transport: swap the socket under
    /// the pipeline — virtual display, capture and encoder stay up (no
    /// display destroy/create, so no screen flash and no window reshuffle)
    /// while the connection redials over the new transport. The receiver
    /// treats it like any reconnect: the fresh connection replaces the old
    /// one and the video resyncs with a keyframe. Which transport to be on
    /// is the controller's call (cable-in upgrade, unplug failover).
    func switchTransport(to newTransport: SenderTransport) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let label = if case .usb = newTransport { "USB" } else { "WiFi" }
            Log.info("switching \(self.endpointName) to \(label)")
            self.transport = newTransport
            // Fresh grace window: if the new link can't come up either, the
            // session ends like any other disconnect instead of dialing
            // a dead transport forever.
            self.disconnectedSince = Date()
            self.connectionReady = false
            self.currentPathDirectLink = false   // the new transport re-classifies
            self.dialGeneration += 1   // a dial still in flight must not adopt
            self.connection?.cancel()
            self.connection = nil
            self.closeCursorChannel()
            self.stopUpgradeProbing()
            self.resetSendQueue()
            self.pipelineLock.lock()
            self.pendingEncodes = 0
            self.pipelineLock.unlock()
            self.connect()
        }
    }

    // The controller's end() is idempotent, but several detectors (grace,
    // refusals, service withdrawal) can conclude "gone" repeatedly while the
    // stop is in flight — report once so the log tells the story once.
    private var goneReported = false

    /// Declare the device gone and end the session (must be called on `queue`).
    private func reportGone(_ reason: String) {
        guard !goneReported, !stopped else { return }
        goneReported = true
        inputInjector?.reset()
        Log.info(reason)
        Task { @MainActor in self.onDisconnected?() }
    }

    /// A live connection just died (must be called on `queue`). On the
    /// direct cable link the death is almost always someone pulling the
    /// plug, and unplugging is how people intentionally end a session —
    /// falling back to WiFi would resurrect what they just killed. Every
    /// other path (WiFi, routed Ethernet, the dev loopback) keeps the
    /// redial loop: a drop there is never intent.
    private func linkDied(_ detail: String) {
        endInputEpoch("link died (\(detail))")
        if currentPathDirectLink, case .tcp = transport {
            reportGone("cable link lost (\(detail)) — unplugging means disconnect, ending session")
        } else {
            scheduleReconnect()
        }
    }

    /// (Re)decide whether the live session rides the direct host-to-host
    /// cable (must be called on `queue`). Address shape alone is not
    /// enough: on a bridged LAN a phone's Bonjour record can resolve to
    /// its fe80, and a DHCP-less switch hands out 169.254 to everyone —
    /// so the peer must also be a Mac receiver, the only receiver a TCP
    /// cable session can exist with (phones ride usbmuxd). Runs again when
    /// hello arrives: a fresh dial reaches ready before the first hello
    /// names the device.
    private func refreshDirectLinkClassification(for conn: NWConnection) {
        guard connection === conn, case .tcp = transport,
              lastHello?.device == "Mac",
              let path = conn.currentPath else {
            currentPathDirectLink = false
            return
        }
        let wired = !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.loopback)
            && !path.usesInterfaceType(.cellular)
        currentPathDirectLink = wired
            && Self.endpointIsLinkLocal(path.remoteEndpoint ?? conn.endpoint)
    }

    /// True when the far end of a connection is a link-local address
    /// (fe80::/10 or 169.254/16). The USB-C/Thunderbolt host-to-host link
    /// hands out nothing else — necessary for "riding the direct cable",
    /// but not sufficient: see refreshDirectLinkClassification.
    private static func endpointIsLinkLocal(_ endpoint: NWEndpoint?) -> Bool {
        guard case .hostPort(let host, _)? = endpoint else { return false }
        switch host {
        case .ipv4(let addr): return addr.isLinkLocal
        case .ipv6(let addr): return addr.isLinkLocal
        case .name(let name, _):
            // Literal probe targets dial as names ("fe80::1%en5").
            let bare = name.lowercased()
            return bare.hasPrefix("169.254.") || bare.hasPrefix("fe80:")
        @unknown default: return false
        }
    }

    /// A dial was actively refused (must be called on `queue`). On a session
    /// that has streamed before, enough refusals in a row prove the receiver
    /// app is gone — end now instead of waiting out the grace.
    private func dialRefused() {
        guard everConnected, !stopped else { return }
        consecutiveRefusals += 1
        if consecutiveRefusals >= refusalsBeforeGivingUp {
            reportGone("dial refused \(consecutiveRefusals)x — receiver app is gone, ending session")
        }
    }

    /// The receiver's Bonjour advertisement disappeared (the system
    /// deregisters a dead app's service within ~1s, while a suspended app
    /// keeps it). Only meaningful once the connection is already down —
    /// a live connection outranks a flapping mDNS cache. Together they
    /// prove a WiFi receiver quit, where dials just stall instead of
    /// being refused.
    func peerServiceWithdrawn() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.everConnected,
                  !self.connectionReady else { return }
            self.reportGone("service withdrawn and connection down — receiver app is gone, ending session")
        }
    }

    /// Drop the current connection and dial again — fresh TCP through the
    /// tunnel, fresh accept on the phone. Bound to the UI Reconnect button.
    func forceReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Log.info("manual reconnect requested")
            self.disconnectedSince = Date()   // fresh grace window
            self.scheduleReconnect()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // A retired stream commonly reports its stop after the replacement is
        // already live. It must not tear down that replacement (#203).
        guard stream === self.stream else { return }
        Log.info("stream stopped with error: \(error)")
        // The user stopped this capture from the system UI (the menu bar's
        // recording indicator / "Stop Extending"). That is a disconnect, not
        // a fault: restarting capture would defy the user — and macOS
        // answers such defiance by saving display state that keeps this
        // identity from ever coming online again (#206). Hand it to the
        // controller to honor exactly like the in-app Disconnect.
        if let scError = error as? SCStreamError, scError.code == .userStopped,
           consoleIsInteractive {
            Task { @MainActor in self.onCaptureStoppedByUser?() }
            return
        }
        Task { await status("Capture stopped: \(error.localizedDescription)") }
        // E.g. display sleep can tear the virtual display down underneath the
        // stream — rebuild instead of sitting dead until an app restart.
        guard !stopped, mode == .extend else { return }
        invalidateCapturePipeline()
        self.stream = nil
        scheduleCaptureRecovery()
    }

    /// Retry until capture is back. Per issue #29 fix-plan point 1: a dead
    /// stream does NOT mean the display is gone. If our own virtual display
    /// still exists, just re-attach the capture to it — rebuilding the display
    /// (destroy+create) is what killed the NEIGHBOR's stream and ping-ponged
    /// the infinite rebuild loop. Only do a full `reconfigure` when the display
    /// is actually gone (e.g. display sleep tore it down).
    private func scheduleCaptureRecovery() {
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.stopped, self.stream == nil,
                  let hello = self.lastHello else { return }
            // Does our virtual display still exist? CGDisplayBounds returns a
            // zero rect for an unknown id, so a non-empty bounds means it's live.
            // Test isEmpty, not isNull: isNull is only true for the special
            // CGRect.null, so it reads as "live" for a dead display too and the
            // rebuild fallback below would become unreachable.
            if let vd = self.virtualDisplay,
               !CGDisplayBounds(vd.displayID).isEmpty {
                Log.info("capture died — display still present, re-attaching capture only (#29)")
                Task {
                    // Same rule as every other poll: while `findSCDisplay` is
                    // waiting for the display to answer, the enforcement tick
                    // must not be re-publishing settings underneath it.
                    await MainActor.run { vd.beginReconfiguration() }
                    var found: SCDisplay?
                    var failure: Error?
                    do { found = try await self.findSCDisplay(id: vd.displayID) }
                    catch { failure = error }
                    await MainActor.run { vd.endReconfiguration() }
                    do {
                        guard let display = found else { throw failure! }
                        // Capture at the display's pixel resolution (points ×2 @2x),
                        // not SCDisplay.width (logical points) — matches setupExtend.
                        let captureW = (Int(Double(vd.pointsWide * 2) * self.activeScale.scale)) & ~1
                        let captureH = (Int(Double(vd.pointsHigh * 2) * self.activeScale.scale)) & ~1
                        try await self.startCapture(display: display,
                                                    pixelsWide: captureW, pixelsHigh: captureH)
                        self.needsKeyframe = true
                    } catch {
                        Log.info("re-attach failed (\(error)) — falling back to full rebuild")
                        await self.reconfigure(hello)
                    }
                    self.queue.async { self.recoveryRoundEnded() }
                }
                return
            }
            // Display genuinely gone — full rebuild (preserves old behavior).
            Log.info("capture died — rebuilding pipeline")
            Task {
                await self.reconfigure(hello)
                self.queue.async { self.recoveryRoundEnded() }
            }
        }
    }

    /// SCK can report `.userStopped` for stops the user did not initiate
    /// when the console goes non-interactive (screen lock, fast user
    /// switch). Only a stop from an interactive console can be a deliberate
    /// menu-bar "stop sharing"; everything else stays on the recovery path,
    /// which was already how those transitions healed before this check
    /// existed.
    private var consoleIsInteractive: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool ?? true
        let locked = info["CGSSessionScreenIsLocked"] as? Bool ?? false
        return onConsole && !locked
    }

    /// On `queue`: after a recovery round, re-arm the loop while capture is
    /// still down — up to the cap, then declare the session gone. A capture
    /// dead this many rounds is not coming back by itself, and ending the
    /// session (display torn down, reconnect is the user's call) beats
    /// hammering WindowServer with create/destroy cycles forever.
    private func recoveryRoundEnded() {
        guard stream == nil else {
            captureRecoveryFailures = 0
            return
        }
        captureRecoveryFailures += 1
        guard captureRecoveryFailures < maxCaptureRecoveryFailures else {
            Task { await status("Capture could not be restarted") }
            reportGone("capture recovery failed \(captureRecoveryFailures)x — ending session")
            return
        }
        scheduleCaptureRecovery()
    }

    // MARK: - Connection (with retry)

    // Guards against a stale async USB dial adopting after a newer one (or a
    // manual reconnect) superseded it. Only touched on `queue`.
    private var dialGeneration = 0

    private func connect() {
        guard !stopped else { return }
        switch transport {
        case .tcp(let endpoint): connectTCP(endpoint)
        case .usb(let udid, let port): connectUSB(udid: udid, port: port)
        }
    }

    /// Bookkeeping shared by both transports once a connection is live.
    private func becomeReady(_ conn: NWConnection) {
        inputInjector?.reset()
        // The next failure to reach this receiver is news again.
        dialTimeoutLog.reset()
        dialWaitingLog.reset()
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        cursorSeq = 0   // per-session; the receiver rewound its floor with the connection
        // The stats sequence restarts with the connection too (PROTOCOL.md
        // 6.3), so the tracker that deduplicates the TCP and UDP copies has to
        // rewind with it — otherwise the whole of the next session's telemetry
        // reads as duplicate and the controller goes blind.
        statsDedupe.reset()
        loggedStatsPath = false
        receiverReport = nil
        receiverReportAt = nil
        resetSendQueue()
        // Back to legacy framing until this connection's receiver identifies
        // itself: a reconnect can land on a different device than the last one.
        //
        // **Only for a connection we have not already greeted.** `NWConnection`
        // may report `.ready` more than once for the same object — after a
        // `.waiting`, after a path migration — and clearing this on the second
        // one closed the audio gate for the rest of a live session, because a
        // receiver sends `hello` on adoption and had no reason to send another.
        // The receiver's own re-hello triggers (`Shared/StreamReceiver`: panel
        // change, cursor port, address change, unmute) reopen it; nothing
        // should be able to need them.
        let isNewConnection = readyConnection != ObjectIdentifier(conn)
        readyConnection = ObjectIdentifier(conn)
        if isNewConnection {
            peerSpeaksTaggedFrames = false
            // Same reasoning, and the same scope: a different receiver may not
            // understand the stamp. It is re-asserted by the next `hello`,
            // which every receiver sends on adoption.
            peerWantsAudioSequence = false
            audioLock.lock()
            peerWantsAudioSequenceForEncoder = false
            audioLock.unlock()
        } else {
            Log.info("connection re-reported ready — keeping the handshake "
                     + "(receiver \(peerSpeaksTaggedFrames ? "speaks" : "has not claimed") tagged framing)")
        }
        // A new receiver has no codec config, so the next packet must carry it.
        // The "peer is too old for audio" log-once flag lives on the audio
        // queue with everything else the audio path owns, so it is cleared
        // there rather than written across the boundary.
        audioQueue.async { [weak self] in
            self?.audioEncoder?.reset()
            self?.loggedAudioUnsupportedPeer = false
        }
        everConnected = true
        awaitingWake = false
        consecutiveRefusals = 0
        disconnectedSince = nil
        needsKeyframe = true   // new peer needs SPS/PPS + IDR
        // Keep cached pixels: ScreenCaptureKit stays quiet on a static
        // display, and the watchdog needs them to force the reconnect IDR.
        cancelDropReplayTimer()
        // A reconnect can recreate the phone's video view with no cursor
        // sprite; the sprite is otherwise only sent on shape change, so the
        // cursor would stay invisible until the user hovers something that
        // changes it. Reset the dedup state to re-send sprite + position to
        // the fresh peer — the cursor analogue of forcing a keyframe.
        lastCursorPNGHash = 0
        lastCursorSent = (-1, -1, false)
        lastReceived = Date()  // fresh grace period for the watchdog
        // An established connection whose interface vanishes does NOT get a
        // .failed/.waiting state update — NW keeps it and flags it non-viable
        // (field-tested: pulling the USB-C cable left the state handler
        // silent and only the 5s watchdog noticed). Viability is the prompt
        // unplug signal. Only the direct cable link acts on it: WiFi blips
        // go non-viable routinely and NW rides them out on its own, and a
        // docked Mac losing its Ethernet (undock) should fall back to WiFi,
        // not end the session.
        conn.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.connection === conn, !viable,
                  self.currentPathDirectLink else { return }
            self.linkDied("path no longer viable")
        }
        receiveControl(on: conn)
        refreshDirectLinkClassification(for: conn)
        if let path = conn.currentPath {
            let wired = !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.loopback)
                && !path.usesInterfaceType(.cellular)
            currentPathUsesWiFi = path.usesInterfaceType(.wifi)
            let names = path.availableInterfaces.map(\.name).joined(separator: ",")
            Log.info("connection path to \(endpointName): \(names) wired=\(wired) direct=\(currentPathDirectLink)")
            Task { @MainActor in self.onTransportPath?(wired) }
        }
        // -forceUpgradeProbe YES: dev knob — loopback runs never look like
        // WiFi, so this is the only way to exercise probe+migrate on one Mac.
        if currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe") {
            startUpgradeProbing()
        } else {
            stopUpgradeProbing()   // already off WiFi — nothing better to find
        }
        Task { await self.status("Connected to \(self.endpointName)") }
    }

    // MARK: - Cable upgrade (PROTOCOL.md 6.4)

    /// Arm the periodic probe. Cheap when there is nothing to find: with no
    /// advertised addresses, or on the USB transport, it never fires a dial.
    private func startUpgradeProbing() {
        lastLoggedCandidates = []
        upgradeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 10.0)
        timer.setEventHandler { [weak self] in self?.probeForCablePath() }
        timer.resume()
        upgradeTimer = timer
        wiredPathMonitor?.cancel()
        let monitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        // The handler also fires once at start with the current state; only
        // a transition to satisfied means a cable was just plugged.
        var wasSatisfied: Bool? = nil
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            defer { wasSatisfied = satisfied }
            guard let self, satisfied, wasSatisfied == false else { return }
            Log.info("local wired path appeared — probing cable paths now")
            self.probeForCablePath(force: true)
        }
        monitor.start(queue: queue)
        wiredPathMonitor = monitor
    }

    private func stopUpgradeProbing() {
        upgradeTimer?.cancel()
        upgradeTimer = nil
        wiredPathMonitor?.cancel()
        wiredPathMonitor = nil
        probeRoundGeneration += 1   // orphan any pending sweep
        upgradeProbes.forEach { $0.cancel() }
        upgradeProbes.removeAll()
    }

    /// One probe round: dial every candidate (receiver address × local
    /// interface for link-local IPv6) with WiFi forbidden. mDNS resolution
    /// stalls under interface restrictions; literal addresses do not.
    private func probeForCablePath(force: Bool = false) {
        guard !stopped, connectionReady,
              currentPathUsesWiFi || UserDefaults.standard.bool(forKey: "forceUpgradeProbe"),
              case .tcp = transport, !peerAddrs.isEmpty else { return }
        if force {
            // Something changed (peer re-hello, local interface up): a round
            // of stale candidates still in flight must not swallow this one.
            upgradeProbes.forEach { $0.cancel() }
            upgradeProbes.removeAll()
        } else {
            guard upgradeProbes.isEmpty else { return }   // a round is still in flight
        }

        // Directly-dialable addresses first (IPv4, routable IPv6): they are
        // one candidate each and usually enough. Link-local IPv6 needs a
        // local zone and fans out across interfaces, so it goes last and
        // only across interfaces that hold a link-local themselves — a cap
        // eaten by dead scopes would starve the real candidates.
        var candidates: [NWEndpoint.Host] = []
        var linkLocal: [NWEndpoint.Host] = []
        let scopes = Self.candidateInterfaceNames()
        for addr in peerAddrs {
            if addr.lowercased().hasPrefix("fe80:") {
                for iface in scopes {
                    linkLocal.append(NWEndpoint.Host("\(addr)%\(iface)"))
                }
            } else {
                candidates.append(NWEndpoint.Host(addr))
            }
        }
        candidates.append(contentsOf: linkLocal)
        guard !candidates.isEmpty else { return }
        // Log a round only when its candidate set differs from the last
        // logged one: the first round of a session and every cable-plug
        // transition show up, an unchanged set repeating every 10s does not.
        let candidateNames = candidates.prefix(16).map { "\($0)" }
        if candidateNames != lastLoggedCandidates {
            lastLoggedCandidates = candidateNames
            Log.info("probing \(candidateNames.count) candidate cable paths"
                     + " (direct \(candidates.count - linkLocal.count),"
                     + " fe80 scopes \(scopes.joined(separator: ","))) — repeats every 10s")
        }
        probeRoundGeneration += 1
        let round = probeRoundGeneration

        for host in candidates.prefix(16) {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            params.prohibitedInterfaceTypes = [.wifi, .cellular]
            let probe = NWConnection(host: host, port: 9000, using: params)
            upgradeProbes.append(probe)
            probe.stateUpdateHandler = { [weak self] state in
                guard let self, self.upgradeProbes.contains(where: { $0 === probe }) else { return }
                switch state {
                case .ready:
                    if let path = probe.currentPath, !path.usesInterfaceType(.wifi) {
                        self.migrate(to: probe)
                    } else {
                        self.upgradeProbes.removeAll { $0 === probe }
                        probe.cancel()
                    }
                case .failed, .waiting:
                    self.upgradeProbes.removeAll { $0 === probe }
                    probe.cancel()
                default: break
                }
            }
            probe.start(queue: queue)
        }
        // Sweep stragglers so the next round starts clean. Generation-gated:
        // a forced round may have replaced this one, and the old sweep must
        // not cancel the new round's probes mid-dial.
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.probeRoundGeneration == round else { return }
            self.upgradeProbes.forEach { $0.cancel() }
            self.upgradeProbes.removeAll()
        }
    }

    /// Swap the live session onto the probed connection. Same shape as a
    /// reconnect: the receiver parks the newcomer, adopts it on our first
    /// bytes, and the abandoned WiFi socket's EOF is ignored as stale.
    private func migrate(to conn: NWConnection) {
        let names = conn.currentPath?.availableInterfaces.map(\.name)
            .joined(separator: ",") ?? "?"
        Log.info("cable path answered (\(names)) — migrating the session off WiFi")
        upgradeProbes.removeAll { $0 === conn }
        stopUpgradeProbing()
        dialGeneration += 1   // a redial in flight must not clobber this
        closeCursorChannel()  // rebuilt from the next hello on the new path
        // Detach the old connection's handler BEFORE cancelling: its
        // .cancelled callback arrives after becomeReady below and would
        // reset connectionReady, silently blackholing every send on the
        // migrated connection.
        connection?.stateUpdateHandler = nil
        connection?.viabilityUpdateHandler = nil
        connection?.cancel()
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.connection === conn else { return }
            switch state {
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                self.linkDied("failed: \(error)")
            case .waiting(let error):
                Log.info("connection waiting: \(error) — will retry")
                self.connectionReady = false
                self.linkDied("waiting: \(error)")
            case .cancelled:
                self.connectionReady = false
            default: break
            }
        }
        becomeReady(conn)
    }

    /// Local zones a link-local probe could ride: interfaces that are up,
    /// not loopback, and hold a link-local IPv6 address of their own (a
    /// scope with no fe80 of its own answers every dial with "network is
    /// down"). Names only — the probe carries the actual restriction via
    /// prohibitedInterfaceTypes.
    private static func candidateInterfaceNames() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: ifa.ifa_name)
            // anpi* completes TCP handshakes but cannot carry the stream —
            // see the matching exclusion in StreamReceiver.
            if name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("utun")
                || name.hasPrefix("gif") || name.hasPrefix("stf")
                || name.hasPrefix("anpi") { continue }
            let isLinkLocal = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var a = $0.pointee.sin6_addr
                return withUnsafeBytes(of: &a) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
            }
            guard isLinkLocal else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    private func connectTCP(_ endpoint: NWEndpoint) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        // No interface steering: macOS already ranks a Thunderbolt Bridge or
        // Ethernet link above WiFi, so a plain dial lands on the cable when
        // there is one (field-tested: en10 chosen over en0). A WiFi-prohibited
        // pre-dial was tried and only ever hung until its timeout, adding 2s
        // to every connect. becomeReady reports which path won.
        let params = NWParameters(tls: nil, tcp: options)
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        // A dial to a withdrawn Bonjour service (receiver asleep or app
        // closed) sits in .preparing forever — it neither fails nor resolves
        // when the service later returns, observed on macOS 26. Give every
        // dial a deadline and redial fresh: a new NWConnection re-runs
        // Bonjour resolution, so the retry loop reaches the receiver the
        // moment it advertises again.
        let generation = dialGeneration
        queue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self, generation == self.dialGeneration, !self.stopped,
                  self.connection === conn, conn.state != .ready else { return }
            switch self.dialTimeoutLog.note("\(conn.state)",
                                            now: Date().timeIntervalSince1970) {
            case .speak:
                Log.info("dial timed out in \(conn.state) — redialing")
            case .summarise(let quiet):
                Log.info("dial still timing out in \(conn.state) — redialing "
                         + "(\(quiet) more since the last line)")
            case .quiet:
                break
            }
            self.scheduleReconnect()
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becomeReady(conn)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.dialRefused()
                }
                // Dial-phase state: this connection never carried the
                // session, so its failure says nothing about a cable —
                // plain reconnect, under the grace/refusal rules.
                self.scheduleReconnect()
            case .waiting(let error):
                // On loopback there is no "path change" to wake us up again
                // (e.g. a manual -host tunnel not started yet) — treat
                // waiting as failure and poll by reconnecting.
                //
                // A refused dial comes back about once a second, so this is
                // the chatty one. (The other `connection waiting` site is a
                // connection that already carried the session; a drop there is
                // news every time.)
                switch self.dialWaitingLog.note("\(error)",
                                                now: Date().timeIntervalSince1970) {
                case .speak:
                    Log.info("connection waiting: \(error) — will retry")
                case .summarise(let quiet):
                    Log.info("connection still waiting: \(error) — will retry "
                             + "(\(quiet) more since the last line)")
                case .quiet:
                    break
                }
                self.connectionReady = false
                // Read the queue-confined flag here (handler runs on queue),
                // not inside the detached status Task.
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for receiver at \(self.endpointName)…"
                Task { await self.status(text) }
                self.scheduleReconnect()
            case .cancelled:
                self.connectionReady = false
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Dial through macOS's built-in usbmuxd — no external tunnel needed.
    /// The handshake is async, so adoption is gated on `dialGeneration`.
    private func connectUSB(udid: String?, port: UInt16) {
        dialGeneration += 1
        let generation = dialGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await Usbmux.dial(udid: udid, port: port, queue: queue)
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else {
                        conn.cancel()
                        return
                    }
                    self.connection = conn
                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .failed(let error):
                            Log.info("usb connection failed: \(error)")
                            self.connectionReady = false
                            self.scheduleReconnect()
                        case .cancelled:
                            self.connectionReady = false
                        default:
                            break
                        }
                    }
                    self.becomeReady(conn)
                }
            } catch {
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else { return }
                    // Distinct guidance per failure: cable missing vs app
                    // closed. Composed on `queue`: awaitingWake lives there.
                    let hint: String
                    switch error as? Usbmux.Failure {
                    case .noDevice:
                        hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                    case .refused:
                        self.dialRefused()
                        hint = self.awaitingWake
                            ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                            : "Device found — open the OpenDisplay app on it…"
                    default:
                        Log.info("usb dial failed: \(error)")
                        hint = "USB connection failed: \(error.localizedDescription)"
                    }
                    Task { await self.status(hint) }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        // Before anything else, and before the grace timer gets a vote: the
        // link that was carrying input is gone, so nothing may still be held
        // on its behalf.
        endInputEpoch("connection lost, redialing")
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > disconnectGraceSeconds {
                    reportGone("device gone for >\(Int(disconnectGraceSeconds))s — ending session")
                    return
                }
            } else {
                disconnectedSince = Date()
                Task { await status("Connection lost — retrying for \(Int(disconnectGraceSeconds))s…") }
            }
        }
        connectionReady = false
        // Whatever this session rode is gone; deciding to redial means it is
        // an ordinary reconnecting session now. A stale direct-link flag here
        // would let the first dial hiccup end the session via linkDied.
        currentPathDirectLink = false
        dialGeneration += 1   // a USB dial still in flight must not adopt
        let generation = dialGeneration
        connection?.cancel()
        connection = nil
        closeCursorChannel()   // rebuilt from the next hello
        resetSendQueue()
        pipelineLock.lock()
        pendingEncodes = 0
        pipelineLock.unlock()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            // Generation-guarded so a switchTransport (or another reconnect)
            // that landed in this 1s window supersedes this dial instead of
            // racing it — otherwise the queued connect() re-dials the new
            // transport, briefly running two live connections. (No bare
            // self-rescheduling asyncAfter — the pattern banned in #76.)
            guard let self, generation == self.dialGeneration, !self.stopped else { return }
            self.connect()
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady {
                // Liveness + send-side health for the phone's overlay.
                let elapsed = Date().timeIntervalSince(self.capWindowStart)
                let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
                self.capFrames = 0
                self.capWindowStart = Date()
                let sorted = self.inputLatencies.sorted()
                let inp50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2].rounded()
                let inp95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))].rounded()
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(self.dropsEncTotal),\"netDrops\":\(self.dropsNetTotal),\"pending\":\(self.sendQueue.depth),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 5 {
                // A suspended receiver app (user switched apps) goes silent
                // like this while its kernel still accepts redials — the
                // session and display are kept on purpose so the user's
                // window arrangement survives until they come back. Genuine
                // network loss fails the redials and ends via the grace.
                if self.currentPathDirectLink, case .tcp = self.transport {
                    // Backstop for the viability handler: silence on the
                    // direct cable is an unplug (or a dead peer) — never
                    // redial onto WiFi.
                    self.linkDied("silent for >5s")
                } else {
                    Log.info("watchdog: nothing from the phone for >5s — reconnecting")
                    // Can't tell a backgrounded receiver from a brief stall here
                    // (both go silent while redials still succeed) — hedge.
                    Task { await self.status("\(self.endpointName) is silent — keeping the display (app in background or brief stall)") }
                    self.scheduleReconnect()
                }
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.connectionReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                self.reportGone("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
                let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen after reconnect to \(self.endpointName) — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
                            generation: self.captureGenerationNow)
            }
            self.scheduleWatchdog()
        }
    }

    // MARK: - Adaptive quality

    /// Build the controller for a capture of this size.
    ///
    /// Called from `startCapture`, on `queue`, and **only** from there: the
    /// changes adaptation makes to a live session go through
    /// `SCStream.updateConfiguration`, which does not restart the capture. So
    /// reaching here always means a genuinely new pipeline — a rotation, a
    /// transport migration, a recovery — and a new pipeline is judged on its
    /// own evidence, starting from whatever this path class was last seen to
    /// sustain.
    private func rebuildAdaptivePlan(pixelsWide: Int, pixelsHigh: Int) {
        guard adaptiveEnabled else { return }
        // The plan's rungs are fractions of the size at scale 1.0, not of
        // whatever scale is in force — otherwise a session that restarted while
        // degraded would build its ladder on top of an already-reduced base.
        // Rounded, not truncated: the captured size was itself rounded down to
        // even, so `1790 / 0.75` has to come back as 2388 and not 2386 — or a
        // session configured at Balanced would reconfigure its own capture by
        // two pixels the moment the plan was built.
        let base = activeScale.scale > 0
            ? (wide: Int((Double(pixelsWide) / activeScale.scale).rounded()),
               high: Int((Double(pixelsHigh) / activeScale.scale).rounded()))
            : (wide: pixelsWide, high: pixelsHigh)
        let plan = AdaptivePlan(configuredBitrateBps: configuredBitrate,
                                configuredFps: frameRate.rawValue,
                                configuredScale: quality,
                                baseWide: base.wide, baseHigh: base.high,
                                floorBps: adaptiveFloorKbps * 1000,
                                maxLever: adaptiveMaxLever)
        let pathClass = provisionalPathClass()
        let remembered = OperatingPointStore.decode(
            UserDefaults.standard.object(forKey: OperatingPointStore.defaultsKey),
            for: pathClass)
        let now = ProcessInfo.processInfo.systemUptime
        var controller = AdaptiveQualityController(plan: plan, pathClass: pathClass,
                                                   start: remembered, now: now)
        controller.noteApplied(at: now)
        adaptive = controller
        pathClassSettled = false
        if activeScale != quality {
            // A previous session's scale must not survive into a fresh plan.
            activeScale = quality
        }
        let ladder = plan.levels.map { level -> String in
            let size = plan.encodedSize(level)
            return "\(plan.frameRate(level))fps \(size.wide)x\(size.high)"
        }.joined(separator: " → ")
        Log.info("adaptive: path \(pathClass.label)"
                 + (remembered == nil
                    ? " (nothing remembered — starting at the configured "
                      + "\(AdaptiveQualityController.mbps(plan.configuredBitrateBps)) Mbps)"
                    : " — resuming the remembered operating point")
                 + ", start \(controller.startDescription), "
                 + "floor \(adaptiveFloorKbps)kbps, ceiling "
                 + "\(AdaptiveQualityController.mbps(plan.configuredBitrateBps)) Mbps; levers \(ladder)"
                 + "; lever cap \(adaptiveMaxLever.rawValue) — \(adaptiveMaxLever.explanation)")
        applyAdaptiveState(controller, force: true)
    }

    /// Everything `PathClass.classify` needs that is not the round trip, read
    /// off the live connection. On `queue`, where `connection` lives.
    private func pathSignals() -> (usb: Bool, directLink: Bool, wired: Bool, tailnet: Bool) {
        if case .usb = transport { return (true, true, true, false) }
        var wired = false
        var host = ""
        if let path = connection?.currentPath {
            // `.wiredEthernet` specifically, and NOT the "not WiFi, not
            // loopback, not cellular" test the `connection path to …` line
            // uses: Tailscale's `utun4` passes that one, and a session over a
            // DERP relay would be classified as a local cable.
            wired = path.usesInterfaceType(.wiredEthernet)
            if case .hostPort(let endpointHost, _)? = path.remoteEndpoint {
                host = "\(endpointHost)"
            }
        }
        // `remoteEndpoint` is the RESOLVED address — the operator dials
        // a MagicDNS hostname, which says nothing, and `currentPath`
        // answers a 100.64.0.0/10 address, which identifies the tailnet path.
        // `endpointName` is the fallback for a path that has not resolved yet,
        // and is where a MagicDNS `….ts.net` name would show up.
        if host.isEmpty { host = endpointName }
        return (false, currentPathDirectLink, wired, TailnetAddress.isTailnet(host))
    }

    /// The class this session is on before any RTT has been measured: enough to
    /// pick a remembered operating point in the first second, which is the
    /// second that matters on LTE.
    private func provisionalPathClass() -> PathClass {
        let signals = pathSignals()
        if signals.usb { return .lan }
        return PathClass.classify(directLink: signals.directLink, wired: signals.wired,
                                  tailnet: signals.tailnet, rttMs: nil)
    }

    /// Settle the class once the receiver has measured a round trip. One
    /// correction per session: after the controller has acted on evidence, a
    /// remembered number from another class is worse information than what it
    /// already has.
    private func settlePathClass(rttMs: Double) {
        guard adaptiveEnabled, !pathClassSettled, var controller = adaptive, rttMs > 0 else { return }
        let signals = pathSignals()
        guard !signals.usb else { return }
        pathClassSettled = true
        let settled = PathClass.classify(directLink: signals.directLink, wired: signals.wired,
                                         tailnet: signals.tailnet, rttMs: rttMs)
        guard settled != controller.pathClass else { return }
        let was = controller.pathClass
        let remembered = OperatingPointStore.decode(
            UserDefaults.standard.object(forKey: OperatingPointStore.defaultsKey),
            for: settled)
        let moved = controller.reclassify(as: settled, remembered: remembered)
        adaptive = controller
        Log.info(String(format: "adaptive: path settles as %@ (was %@, rtt %.0fms)",
                        settled.label, was.label, rttMs)
                 + (moved ? " — adopting its remembered \(controller.startDescription)"
                          : " — keeping the current operating point"))
        if moved { applyAdaptiveState(controller, force: true) }
    }

    /// Sample the link twice a second and let `AdaptiveQualityController`
    /// decide. Twice a second rather than on the ping (every 2 s) because the
    /// congestion hold is one second and a 2 s sampler cannot see a second.
    private func scheduleAdaptiveTick() {
        guard adaptiveEnabled else {
            Log.info("adaptive quality: off (adaptiveQuality = false)")
            return
        }
        if !adaptiveMonitorStarted {
            adaptiveMonitorStarted = true
            Log.info("adaptive: on — continuous rate control, floor \(adaptiveFloorKbps)kbps "
                     + "(adaptiveFloorKbps), AIMD "
                     + "×\(AdaptiveQualityController.decreaseFactor)/"
                     + "+\(Int((AdaptiveQualityController.increaseFactor - 1) * 100))%, "
                     + "cooldown \(AdaptiveQualityController.cooldownSeconds)s, "
                     + "increase after \(Int(AdaptiveQualityController.increaseAfterCleanSeconds))s clean, "
                     + "penalty \(Int(AdaptiveQualityController.penaltySeconds))s, "
                     + "lever cap \(adaptiveMaxLever.rawValue) (adaptiveMaxLever) — "
                     + adaptiveMaxLever.explanation)
        }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped else { return }
            self.adaptiveTick()
            self.scheduleAdaptiveTick()
        }
    }

    private func adaptiveTick() {
        guard connectionReady, encoder != nil, var controller = adaptive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let tickSeconds = lastAdaptiveTickAt > 0 ? max(now - lastAdaptiveTickAt, 0.05) : 0.5
        lastAdaptiveTickAt = now

        pipelineLock.lock()
        let enc = dropsEncTotal
        let frames = framesEncodedTotal
        pipelineLock.unlock()

        let bytes = bytesDeliveredTotal
        let evicted = sendQueue.drainEvictions()
        let completions = writeCompletionsThisTick.sorted()
        writeCompletionsThisTick.removeAll(keepingCapacity: true)
        let writeP95 = completions.isEmpty
            ? 0
            : completions[min(completions.count - 1, Int(Double(completions.count) * 0.95))]
        let oldestWriteMs = writeStartedAt > 0 ? (CACurrentMediaTime() - writeStartedAt) * 1000 : 0

        // The receiver's half, consumed exactly once. `receiverIsFresh` is the
        // flag round 8 did not have: it took step-downs with `e2e95=0ms
        // rtt=0ms` in the line because a missing report and a zero-latency
        // report were the same value.
        let report = receiverReport
        receiverReport = nil
        let reportAge = receiverReportAt.map { Date().timeIntervalSince($0) } ?? 0

        let sample = LinkSample(
            sendQueueDepth: sendQueue.depth,
            maxSendQueueDepth: maxSendQueueDepth,
            oldestWriteAgeMs: oldestWriteMs,
            writeCompletionP95Ms: writeP95,
            evictedFrames: evicted,
            senderEncDrops: max(0, enc - lastAdaptiveCounters.enc),
            framesEncoded: max(0, frames - lastAdaptiveCounters.frames),
            bytesDelivered: max(0, bytes - lastAdaptiveCounters.bytes),
            tickSeconds: tickSeconds,
            receiverIsFresh: report != nil,
            receiverAgeSeconds: reportAge,
            receiverGoodputMbps: report?.mbps ?? 0,
            receiverE2eP50Ms: report?.e2eP50 ?? 0,
            receiverE2eP95Ms: report?.e2eP95 ?? 0,
            receiverStalls: report?.stalls ?? 0,
            receiverRttMs: report?.rtt ?? 0)
        lastAdaptiveCounters = (enc, frames, bytes)

        let change = controller.ingest(sample, at: now)
        if let change {
            Log.info(controller.decisionLine(change, sample: sample, at: now))
            controller.noteApplied(at: now)
            adaptive = controller
            applyAdaptiveState(controller, force: false)
        } else {
            adaptive = controller
        }

        // The panel line, every five seconds: where the controller stands even
        // when it decided nothing, which is most ticks and is the state the
        // next round will want to read.
        if now - lastAdaptivePanelAt >= 5 {
            lastAdaptivePanelAt = now
            Log.info(controller.panelLine(sample: sample, at: now))
            sendQueue.resetPeak()
        }
        persistOperatingPointIfStable(controller, at: now)
    }

    /// Remember where this path class settled, so the next session over it does
    /// not start by asking for 28.8 Mbps on a link that carries one.
    private func persistOperatingPointIfStable(_ controller: AdaptiveQualityController,
                                               at now: CFTimeInterval) {
        guard let point = controller.stableOperatingPoint(at: now),
              now - lastOperatingPointWriteAt >= OperatingPointStore.stableAfterSeconds
        else { return }
        lastOperatingPointWriteAt = now
        let defaults = UserDefaults.standard
        let existing = OperatingPointStore.decode(
            defaults.object(forKey: OperatingPointStore.defaultsKey),
            for: controller.pathClass)
        guard existing != point else { return }
        let merged = OperatingPointStore.encode(
            defaults.object(forKey: OperatingPointStore.defaultsKey),
            point: point, for: controller.pathClass)
        defaults.set(merged, forKey: OperatingPointStore.defaultsKey)
        Log.info("adaptive: remembering \(point.targetKbps)kbps / level \(point.levelIndex) "
                 + "for \(controller.pathClass.label)")
    }

    /// Put the controller's state into effect. Three levers, in order of cost:
    ///
    /// * **bitrate** — `kVTCompressionPropertyKey_AverageBitRate` is settable
    ///   on a live compression session; VideoToolbox applies it from the next
    ///   frame, with no restart, no keyframe and no black flash. Every tick
    ///   that changes only the rate costs exactly this property write;
    /// * **frame rate** — both the delivery gate *and* `SCStreamConfiguration.`
    ///   `minimumFrameInterval`, so a capped session stops paying for captures
    ///   it is going to throw away. Round 8 capped only delivery, which saved
    ///   bandwidth and nothing else;
    /// * **capture scale** — `SCStream.updateConfiguration` changes the
    ///   captured size on the **live** stream, so the SCStream, the filter and
    ///   above all the `CGVirtualDisplay` are untouched: the desktop keeps its
    ///   mode, its origin and its window layout, and only the encoded size
    ///   moves. The compression session does have to be rebuilt (a
    ///   `VTCompressionSession`'s dimensions are fixed at creation) and the
    ///   receiver rebuilds its decoder off the new SPS, which PROTOCOL.md 5.2
    ///   has always required. That is one keyframe, once, and it is logged.
    private func applyAdaptiveState(_ controller: AdaptiveQualityController, force: Bool) {
        let level = controller.level
        if let encoder, configuredBitrate > 0 {
            let status = VTSessionSetProperty(encoder,
                                              key: kVTCompressionPropertyKey_AverageBitRate,
                                              value: controller.targetBps as CFNumber)
            if status != noErr {
                Log.info("adaptive: the encoder refused a live bitrate change "
                         + "(status \(status)) — staying at \(configuredBitrate / 1_000_000)Mbps")
            }
        }
        let cappedRate = controller.plan.frameRate(level)
        let newCap = cappedRate < frameRate.rawValue ? cappedRate : nil
        let rateChanged = newCap != deliveredFrameCap
        deliveredFrameCap = newCap
        if rateChanged { lastDeliveredFrameAt = 0 }

        let scaleChanged = level.scale != activeScale
        guard force || rateChanged || scaleChanged else { return }
        if scaleChanged {
            Log.info("adaptive: capture scale \(activeScale.rawValue) → \(level.scale.rawValue)"
                     + " — the virtual display keeps its mode, only the encoded size moves")
        }
        // **`activeScale` is not moved here.** It is what every rebuild path
        // multiplies by (`setupExtend`, `resizeExistingDisplay`, the capture
        // re-attach), so committing it before ScreenCaptureKit has accepted the
        // new size means a *refused* reconfiguration still permanently resizes
        // every future rebuild of this session. It is committed in the
        // completion handler, on success only.
        reconfigureCapture(level: level, controller: controller, wantedScale: level.scale)
        Task { @MainActor in self.onQualityLevel?(level) }
    }

    /// Ask ScreenCaptureKit for a new size and/or rate on the live stream.
    ///
    /// `updateConfiguration` is the seam that makes this seamless: it is the
    /// documented way to change a running capture, it does not touch the
    /// `SCContentFilter` (so the display being captured is the same object),
    /// and it therefore cannot move the virtual display. A failure falls back
    /// to nothing at all rather than to a rebuild — a session that keeps its
    /// old size is strictly better than one that flashes.
    private func reconfigureCapture(level: QualityLevel,
                                    controller: AdaptiveQualityController,
                                    wantedScale: StreamQuality) {
        guard let stream, !captureReconfiguring else { return }
        let size = controller.plan.encodedSize(level)
        let fps = controller.plan.frameRate(level)
        let clamped = H264Level.effectiveFrameRate(requested: fps,
                                                   width: size.wide, height: size.high)
        guard size != encoderSize || clamped != lastConfiguredCaptureFps else { return }
        captureReconfiguring = true
        let generation = captureReconfigureGeneration &+ 1
        captureReconfigureGeneration = generation
        let config = makeStreamConfiguration(pixelsWide: size.wide, pixelsHigh: size.high,
                                             fps: clamped, wantsAudio: audioEnabled)
        let wanted = size
        // A completion handler that never fires would leave `captureReconfiguring`
        // true for the rest of the session and silently disable every later
        // adaptation — which is what a stream dying mid-reconfiguration does.
        // Release the flag on a deadline, matched by generation so a late
        // completion cannot clear a newer reconfiguration's flag.
        queue.asyncAfter(deadline: .now() + captureReconfigureTimeout) { [weak self] in
            guard let self, self.captureReconfiguring,
                  self.captureReconfigureGeneration == generation else { return }
            self.captureReconfiguring = false
            Log.info("adaptive: ScreenCaptureKit never answered the reconfiguration to "
                     + "\(wanted.wide)x\(wanted.high) @\(clamped)fps within "
                     + "\(Int(self.captureReconfigureTimeout))s — releasing the gate, "
                     + "staying at \(self.encoderSize.wide)x\(self.encoderSize.high)")
        }
        // The completion-handler form, not the `async` one: this runs on
        // `queue` and the callback comes back to it, so no `Task` and no hop
        // across an isolation boundary is involved.
        stream.updateConfiguration(config) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.captureReconfigureGeneration == generation else { return }
                self.captureReconfiguring = false
                if let error {
                    Log.info("adaptive: ScreenCaptureKit refused a live reconfiguration "
                             + "(\(error)) — staying at "
                             + "\(self.encoderSize.wide)x\(self.encoderSize.high) "
                             + "and at capture scale \(self.activeScale.rawValue)")
                    return
                }
                // Only now. See `applyAdaptiveState`: until ScreenCaptureKit has
                // taken the new size, the scale every rebuild path multiplies by
                // has to stay what is actually on the wire.
                self.activeScale = wantedScale
                self.lastConfiguredCaptureFps = clamped
                Log.info("adaptive: capture now \(wanted.wide)x\(wanted.high) @\(clamped)fps "
                         + "at scale \(wantedScale.rawValue) "
                         + "(the encoder rebuilds on the first frame of the new size)")
            }
        }
    }

    /// Rebuild the compression session because the captured size changed under
    /// it. On `queue`, from the capture callback, before the frame is encoded.
    private func rebuildEncoderForNewCaptureSize(_ size: (wide: Int, high: Int)) {
        guard size.wide > 0, size.high > 0 else { return }
        let was = encoderSize
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        do {
            try setupEncoder(width: size.wide, height: size.high)
            noteEncodedSize(pixelsWide: size.wide, pixelsHigh: size.high)
            // A new SPS means the receiver rebuilds its decoder (PROTOCOL.md
            // 5.2) and needs an IDR to start from. Once, here — not per frame.
            //
            // Whatever is already queued is left alone: those frames were
            // encoded against the OLD parameter sets, they arrive before the
            // new SPS does, and the receiver decodes them with the decoder it
            // still has. Flushing the queue here would also zero an in-flight
            // count that a live `send` completion is about to decrement.
            needsKeyframe = true
            Log.info("adaptive: encoder rebuilt \(was.wide)x\(was.high) → \(size.wide)x\(size.high)"
                     + " — one keyframe, no display change")
        } catch {
            Log.info("adaptive: could not rebuild the encoder at \(size.wide)x\(size.high) "
                     + "(\(error)) — the stream stops until the next capture restart")
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120Hz
        timer.setEventHandler { [weak self] in self?.pollCursorPosition() }
        timer.resume()
        cursorTimer = timer
        scheduleCursorImagePoll()
    }

    /// Sprite changes (arrow ↔ I-beam ↔ resize…) must land fast or the wrong
    /// cursor shows over hot areas — poll at 30Hz on the main thread (NSCursor
    /// is AppKit), hash the raw bitmap, and only PNG-encode + send on change.
    ///
    /// A dedicated timer (cancelled+replaced here, like cursorTimer above) — not
    /// a self-rescheduling asyncAfter chain. Every rebuild re-enters
    /// startCursorEcho, and sleep/wake rebuilds happen often; a recursive chain
    /// guarded only by `stopped` would stack one extra 30Hz main-thread
    /// TIFF-encode loop per rebuild, creeping CPU to ~50% until a restart (#75).
    private func scheduleCursorImagePoll() {
        cursorImageTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.033, repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.localCursor else { return }
            self.pollCursorImage()
        }
        timer.resume()
        cursorImageTimer = timer
    }

    /// One `stats` report from the receiver, whichever channel carried it.
    ///
    /// Two copies of every report are sent (PROTOCOL.md 6.3): one over TCP,
    /// which is what every previous build read, and one as a datagram on the
    /// cursor flow, which is the one that arrives when the TCP connection is
    /// backed up behind video. `StatsDedupe` applies whichever lands first and
    /// counts the other.
    private func handleReceiverStats(_ obj: [String: Any], via path: StatsChannel.Path) {
        let sequence = (obj[StatsChannel.sequenceKey] as? NSNumber)?.uint64Value
        guard statsDedupe.accept(sequence: sequence, path: path) else { return }
        if !loggedStatsPath, path == .udp {
            loggedStatsPath = true
            Log.info("adaptive: receiver stats are arriving over the UDP cursor channel — "
                     + "the control loop can see the link even while TCP is backed up")
        }
        if let json = try? JSONSerialization.data(withJSONObject: obj),
           let line = String(data: json, encoding: .utf8) {
            // The receiver's own audio counters ride in `line` (aPkt/aKB); ours
            // are appended so a discrepancy between sent and arrived is visible
            // on one line. The audio counters are written on `audioQueue`; read
            // and clear them under the lock that owns the boundary.
            audioLock.lock()
            let aSent = audioPacketsSent
            let aDropped = audioDropsThisWindow
            audioPacketsSent = 0
            audioDropsThisWindow = 0
            audioLock.unlock()
            Log.info("PHONE-STATS \(line) | mac enc↓=\(dropsEncThisWindow) net↓=\(dropsNetThisWindow)"
                     + " queue=\(sendQueue.depth)/\(maxSendQueueDepth) peak=\(sendQueue.peakDepth)"
                     + " aSent=\(aSent) a↓=\(aDropped) via \(path.rawValue) (\(statsDedupe.pathSummary))")
            dropsEncThisWindow = 0
            dropsNetThisWindow = 0
        }
        // The receiver's half of the adaptive-quality evidence. Stored for the
        // next tick to consume **once**: reports arrive every 5 s at best and a
        // tick runs every 0.5 s, so counting one on every tick in between would
        // read a single bad window as ten.
        let report = ReceiverReport(stalls: obj["stalls"] as? Int ?? 0,
                                    e2eP50: (obj["e2e50"] as? NSNumber)?.doubleValue ?? 0,
                                    e2eP95: (obj["e2e95"] as? NSNumber)?.doubleValue ?? 0,
                                    rtt: (obj["rtt"] as? NSNumber)?.doubleValue ?? 0,
                                    mbps: (obj["mbps"] as? NSNumber)?.doubleValue ?? 0,
                                    fps: (obj["fps"] as? NSNumber)?.intValue ?? 0)
        receiverReport = report
        receiverReportAt = Date()
        // The path class is settled from the first measured round trip
        // (PathClass.classify): a relayed tailnet hop and a direct one need
        // different operating points and cannot be told apart from the dial.
        settlePathClass(rttMs: report.rtt)
    }

    /// Read datagrams the receiver sends back up the cursor flow.
    ///
    /// The cursor channel has only ever run Mac → receiver, but a UDP
    /// `NWConnection` is bidirectional: a datagram the receiver sends on the
    /// flow it accepted comes back to this socket's ephemeral port. Nothing but
    /// `stats` travels this way, and anything else is ignored.
    private func receiveCursorDatagrams(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.cursorConnection === conn else { return }
            if error != nil { return }
            if let data, !data.isEmpty,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               obj["type"] as? String == "stats" {
                // A datagram proves the far end is alive just as a TCP frame
                // does; without this a session whose TCP has gone quiet but
                // whose UDP has not would still be declared dead.
                self.lastReceived = Date()
                self.handleReceiverStats(obj, via: .udp)
            }
            self.receiveCursorDatagrams(on: conn)
        }
    }

    private func pollCursorPosition() {
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.0004 || abs(y - lastCursorSent.y) > 0.0004 {
                lastCursorSent = (x, y, true)
                sendCursor(String(format: "\"x\":%.4f,\"y\":%.4f,\"v\":1", x, y))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            sendCursor("\"v\":0")
        }
    }

    /// Cursor position: UDP side channel while it is up, TCP otherwise. The
    /// datagram carries a sequence so the receiver can drop reordered ones;
    /// the TCP frame is byte-identical to the pre-side-channel wire. Never
    /// blocks: a send on a dead UDP socket just fails in its completion.
    private func sendCursor(_ fields: String) {
        cursorSeq &+= 1
        let message = "{\"type\":\"cursor\",\(fields),\"s\":\(cursorSeq)}"
        if let cursorConnection, cursorConnectionReady {
            cursorConnection.send(content: Data(message.utf8),
                                  completion: .contentProcessed { _ in })
            if cursorChannelConfirmed { return }
        }
        sendJSONFrame(message)
    }

    /// Dial the receiver's UDP cursor port (must be called on `queue`). WiFi
    /// only: usbmuxd tunnels TCP streams, there is no UDP through it. The
    /// host is the one the live TCP connection actually reached, so a
    /// Bonjour or Thunderbolt-bridged dial lands on the same interface. Any
    /// failure here is silent: the cursor keeps riding TCP.
    private func openCursorChannel(port: Int) {
        guard case .tcp = transport, let conn = connection, connectionReady,
              port > 0, port <= Int(UInt16.max),
              let udpPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            closeCursorChannel()
            return
        }
        if let existing = cursorConnection, cursorChannelPort == udpPort {
            switch existing.state {
            case .failed, .cancelled: break   // dead flow, dial again below
            default: return   // rotation re-hello: keep the flow and its sequence
            }
        }
        guard case .hostPort(let host, _)? = conn.currentPath?.remoteEndpoint else {
            Log.info("cursor channel: no remote host for \(endpointName), cursor stays on TCP")
            closeCursorChannel()
            return
        }
        closeCursorChannel()
        let params = NWParameters.udp
        params.serviceClass = .responsiveData
        let udp = NWConnection(host: host, port: udpPort, using: params)
        cursorConnection = udp
        cursorChannelPort = udpPort
        // cursorSeq is session-scoped (reset in becomeReady), not per flow:
        // TCP frames carry the same sequence, and a flow-local restart would
        // read as stale against a floor the TCP path already advanced.
        udp.stateUpdateHandler = { [weak self] state in
            guard let self, self.cursorConnection === udp else { return }
            switch state {
            case .ready:
                self.cursorConnectionReady = true
                Log.info("cursor channel ready: udp \(host):\(udpPort)")
                // The flow now also carries the receiver's stats back to us
                // (PROTOCOL.md 6.3) — start reading before the first report is
                // due, which is within five seconds.
                self.receiveCursorDatagrams(on: udp)
                // Probe immediately: positions only flow while the cursor is
                // on the captured display, which can be minutes away — the
                // ack round-trip must not wait for that.
                if self.lastCursorSent.visible {
                    self.sendCursor(String(format: "\"x\":%.4f,\"y\":%.4f,\"v\":1",
                                           self.lastCursorSent.x, self.lastCursorSent.y))
                } else {
                    self.sendCursor("\"v\":0")
                }
                // No ack = nobody is listening (firewall, dead listener):
                // drop the channel and let the TCP fallback carry on.
                self.queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.cursorConnection === udp,
                          !self.cursorChannelConfirmed else { return }
                    Log.info("cursor channel: no ack after 3s — staying on TCP")
                    self.closeCursorChannel()
                }
            case .failed(let error):
                Log.info("cursor channel failed: \(error), cursor stays on TCP")
                self.closeCursorChannel()
            case .waiting(let error):
                Log.info("cursor channel waiting: \(error), cursor stays on TCP")
                self.cursorConnectionReady = false
            case .cancelled:
                self.cursorConnectionReady = false
            default:
                break
            }
        }
        udp.start(queue: queue)
    }

    private func closeCursorChannel() {
        cursorChannelConfirmed = false
        cursorConnectionReady = false
        cursorConnection?.cancel()
        cursorConnection = nil
        cursorChannelPort = nil
    }

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        guard connectionReady, captureDisplayID != 0,
              let cursor = NSCursor.currentSystem else { return }
        let displaySize = CGDisplayBounds(captureDisplayID).size   // points, current mode
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let hash = tiff.hashValue ^ Int(displaySize.width) &* 31
        guard hash != lastCursorPNGHash else { return }
        guard let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]),
              png.count < 24_000 else { return }
        lastCursorPNGHash = hash
        let size = image.size            // Mac points
        let hot = cursor.hotSpot
        // Normalized against the display so the phone can size/anchor the
        // sprite without knowing capture scale or HiDPI factor.
        let msg = String(format:
            "{\"type\":\"cursorImg\",\"nw\":%.5f,\"nh\":%.5f,\"ax\":%.3f,\"ay\":%.3f,\"png\":\"%@\"}",
            size.width / displaySize.width,
            size.height / displaySize.height,
            size.width > 0 ? hot.x / size.width : 0,
            size.height > 0 ? hot.y / size.height : 0,
            png.base64EncodedString())
        queue.async { self.sendJSONFrame(msg) }
    }

    // MARK: - Control messages (phone -> Mac)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            // A retired socket can still deliver: migration and redial swap
            // `connection` while reads are in flight. Anything arriving on a
            // connection that is no longer the live one is from a session that
            // has already been reset, and acting on it (a stale key-down
            // restarting auto-repeat, a stale button-down) would re-arm input
            // nobody is holding (review #5).
            guard let self, self.connection === conn else { return }
            guard error == nil, let data, data.count == 4 else {
                if let error {
                    Log.info("control receive ended: \(error)")
                    // A receive error on the live connection is fatal to it.
                    // Route through linkDied so a cable session ends instead
                    // of silently waiting for the watchdog to redial. Skip
                    // ECANCELED: that is our own cancel (stop, migrate,
                    // redial), not the link dying.
                    var isOwnCancel = false
                    if case .posix(let code) = error, code == .ECANCELED { isOwnCancel = true }
                    // The connection identity was already checked above.
                    if !isOwnCancel { self.linkDied("receive failed: \(error)") }
                }
                return
            }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                // Same guard as above: the connection can be retired between
                // the length read and the payload read.
                guard let self, self.connection === conn else { return }
                guard error == nil, let payload, payload.count == len else { return }
                self.handleControl(payload)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data) {
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            handleUnparseableControlLogAction(
                unparseableControlLogPolicy.record(
                    payload.count,
                    at: ProcessInfo.processInfo.systemUptime
                )
            )
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the phone can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "stats":
            handleReceiverStats(obj, via: .tcp)
        case "cursorAck":
            // The receiver saw our first datagram: the side channel delivers,
            // stop mirroring positions onto TCP (PROTOCOL.md 6.3).
            if cursorConnection != nil, !cursorChannelConfirmed {
                cursorChannelConfirmed = true
                Log.info("cursor channel confirmed by the receiver")
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                let previous = lastHello
                lastHello = info
                // A fresh dial classifies before the hello names the device —
                // now that it has, decide again (see the comment on the func).
                if let conn = connection { refreshDirectLinkClassification(for: conn) }
                Task { @MainActor in self.onHello?(info) }
                if let port = info.cursorPort {
                    openCursorChannel(port: port)
                } else {
                    closeCursorChannel()
                }
                let addrs = info.addrs ?? []
                if addrs != peerAddrs {
                    let firstHello = peerAddrs.isEmpty
                    peerAddrs = addrs
                    // A re-hello with a changed address set usually means a
                    // cable was just plugged — probe now, not in up to 10s,
                    // and cancel any stale round still in flight.
                    if upgradeTimer != nil, !firstHello {
                        Log.info("receiver addrs changed (\(addrs.count)) — probing cable paths now")
                        probeForCablePath(force: true)
                    }
                }
                // Version handshake (issue #132). Reply with our identity, and
                // if the receiver is below the version we support, tell it to
                // update. Both are additive: older receivers ignore unknown
                // message types. Sending on every hello is idempotent — the
                // phone dedupes by content.
                sendWelcome()
                // Only now, with `welcome` already handed to the connection
                // untagged, may we start tagging. The receiver cannot know our
                // protocol version until it reads that message, so a frame
                // tagged before this point would arrive at a peer still
                // deframing by the legacy rules and be misread as video.
                // Ordering, not just the value, is what makes this correct.
                let tagged = info.protocolVersion >= WireProtocol.taggedFrameVersion
                if tagged != peerSpeaksTaggedFrames {
                    peerSpeaksTaggedFrames = tagged
                    Log.info("framing: \(tagged ? "tagged" : "legacy") (receiver pv \(info.protocolVersion))")
                }
                // Stamping is per-receiver and re-asserted on every hello: an
                // adopted connection may be a different receiver than the last
                // one, and a receiver that does not ask must keep receiving the
                // exact bytes it always did.
                let wantsSeq = info.wantsAudioSequence
                if wantsSeq != peerWantsAudioSequence {
                    peerWantsAudioSequence = wantsSeq
                    audioLock.lock()
                    peerWantsAudioSequenceForEncoder = wantsSeq
                    audioLock.unlock()
                    let how = wantsSeq
                        ? "stamping every packet — the receiver counts duplicates"
                        : "not stamped (the receiver did not ask)"
                    Log.info("audio seq: \(how)")
                }
                if info.protocolVersion < WireProtocol.minSupportedPeer {
                    Log.info("receiver protocol \(info.protocolVersion) below supported \(WireProtocol.minSupportedPeer) — requesting update")
                    sendUpdateRequired(kind: info.kind)
                }
                if let continuation = helloContinuation {
                    helloContinuation = nil
                    continuation.resume(returning: info)
                } else if mode == .extend, stream != nil, let previous,
                          previous.pixelsWide != info.pixelsWide
                          || previous.pixelsHigh != info.pixelsHigh {
                    // Phone rotated — rebuild after a short debounce so a
                    // flurry of orientation flips settles into one rebuild.
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard let current = self.lastHello,
                              current.pixelsWide == info.pixelsWide,
                              current.pixelsHigh == info.pixelsHigh else { return }
                        await self.reconfigure(info)
                    }
                }
            }
        case "touch":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                let button = obj["button"] as? String ?? "left"
                inputInjector?.handleTouch(phase: phase, x: x, y: y, button: button)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "pointer":
            // Trackpad/mouse pointer hover on the receiver: move the cursor,
            // press nothing. Additive — a sender that predates this ignores it
            // and the pointer simply does not track, as before.
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handlePointer(phase: phase, x: x, y: y)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "scroll":
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                // `phase` is additive and optional: a sender that does not know
                // about it produces exactly the event this always produced.
                inputInjector?.handleScroll(dx: dx, dy: dy,
                                            phase: WireInput.scrollPhase(obj["phase"]))
            }
        case "zoom":
            // Additive pinch-to-zoom. Delivered as ⌘=/⌘- keystrokes per
            // threshold step by default (`zoomMode keys`), or as a synthetic
            // NSEventTypeMagnify stream (`zoomMode magnify`) — see
            // InputInjector.handleZoom and `ZoomMode` for why that is no longer
            // the default.
            //
            // `x`/`y` are the pinch centroid, additive and normalized exactly
            // like `touch`. Both or neither: half a coordinate is not a point,
            // and guessing the other half would put the gesture somewhere the
            // fingers never were.
            let zx = WireInput.normalizedCoordinate(obj["x"])
            let zy = WireInput.normalizedCoordinate(obj["y"])
            let centroid = (zx != nil && zy != nil) ? (zx, zy) : (nil, nil)
            if let scale = WireInput.zoomScale(obj["scale"]) {
                inputInjector?.handleZoom(scale: scale,
                                          phase: obj["phase"] as? String ?? "changed",
                                          x: centroid.0, y: centroid.1)
            } else if let phase = obj["phase"] as? String,
                      phase == "began" || phase == "ended" || phase == "cancelled" {
                // The boundary messages carry no scale; they only reset the
                // accumulator, and dropping them would let one gesture's
                // leftover fraction leak into the next.
                inputInjector?.handleZoom(scale: 1, phase: phase,
                                          x: centroid.0, y: centroid.1)
            }
        case "pencil":
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handlePencil(
                    phase: phase, x: x, y: y,
                    pressure: obj["pressure"] as? Double ?? 0,
                    azimuth: obj["azimuth"] as? Double ?? 0,
                    altitude: obj["altitude"] as? Double ?? (.pi / 2),
                    rotation: obj["rotation"] as? Double ?? 0)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "proximity":
            if let entering = obj["entering"] as? Bool,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleProximity(entering: entering, x: x, y: y)
            }
        case "key":
            // `UInt16(code)` traps on a negative or >65535 value, so any peer
            // that can reach port 9000 — the wire is unauthenticated — could
            // crash the sender with one JSON message. Every peer-supplied
            // number on this path is range-checked, never converted blindly.
            if let code = obj["code"] as? Int, let usage = WireInput.hidUsage(code),
               let down = obj["down"] as? Bool {
                let mod = WireInput.modifierMask(obj["mod"] as? Int)
                let char = obj["char"] as? String
                inputInjector?.handleKey(hidUsage: usage, down: down,
                                         rawModifiers: mod, characters: char)
            }
        case "modSidebar":
            if let raw = obj["flags"] as? Int, let flags = WireInput.stickyFlags(raw) {
                inputInjector?.setStickyModifiers(flags)
            }
        case "kf":
            // The phone's decoder lost sync (e.g. it attached mid-GOP and
            // periodic keyframes are off) — force an IDR on the next frame.
            Log.info("phone requested keyframe")
            needsKeyframe = true
        case WireMessage.sleeping:
            // The device locked and is about to close on us. Hand the
            // session to the controller right away: it tears the virtual
            // display down (returning the cursor to a visible screen) and
            // starts a wake-waiting replacement session.
            Log.info("receiver went to sleep — ending session, reconnect armed for wake")
            Task { @MainActor in self.onPeerSleeping?() }
        case RejectionMessage.type:
            // The receiver is pointed at a different Mac. Not an error and not
            // a failure: back off for as long as it asked and let the other
            // sender have the device.
            let ms = RejectionMessage.clampRetryAfterMs(obj["retryAfterMs"])
            let reason = obj["reason"] as? String ?? "unspecified"
            let until = Date().addingTimeInterval(Double(ms) / 1000)
            let readable = reason == RejectionMessage.reasonOtherMacSelected
                ? "other Mac selected" : reason
            Log.info("rejected by receiver (\(readable)) — retrying in \(ms / 1000) s")
            // The machine-readable half, on its own line, for the external
            // watchdog to grep. Deliberately not merged into the line above:
            // a human line is allowed to be reworded, this one is a contract.
            Log.info(RejectionMessage.markerLine(until: until, receiver: endpointName,
                                                 reason: reason))
            Task { @MainActor in self.onRejectedByReceiver?(ms, reason) }
        case WireMessage.closing:
            // The app on the device is quitting for real — end the session
            // without the silence grace and without waiting for a wake.
            Log.info("receiver app closed — ending session")
            Task { @MainActor in self.onPeerClosed?() }
        default:
            // Unknown types are a normal consequence of the additive wire
            // protocol: a newer peer can send messages this build predates.
            // Log each type once per session, never per message. A peer can
            // drive this at input rates (a pencil stroke is ~240 messages/sec),
            // so the policy also caps distinct types and reports that cap once.
            switch unknownTypeLogPolicy.record(type) {
            case .logType(let type):
                Log.info("unknown control message type: \(type) — ignoring (logged once)")
            case .logSuppression(let limit):
                Log.info("additional unknown control message types suppressed after \(limit) distinct types")
            case .none:
                break
            }
        }
    }

    private func waitForHello() async throws -> PhoneInfo {
        if let lastHello { return lastHello }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let hello = self.lastHello {
                    continuation.resume(returning: hello)
                } else {
                    self.helloContinuation = continuation
                }
            }
        }
    }

    // MARK: - Encoder setup

    /// Create the compression session into `encoder`, optionally requiring an
    /// encoder that supports low-latency rate control.
    private func createCompressionSession(width: Int, height: Int, lowLatency: Bool) -> OSStatus {
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        return VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
    }

    private func setupEncoder(width: Int, height: Int) throws {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
        // The spec filters which encoder VideoToolbox is allowed to pick, so an
        // unsupported key fails creation outright rather than being ignored the
        // way the properties below are: this key *requires* an encoder that
        // offers the mode, and Macs whose only encoder is AMD have none (#133).
        // Retrying without it is close to free — the guarantees the mode makes
        // (infinite GOP, no reordering, High profile) are all set explicitly
        // below, and the default rate controller only pipelines when it is fed
        // faster than real time, which the pendingEncodes backpressure already
        // prevents. Measured on Apple silicon at a paced 60fps: 5.3ms mean
        // submit→emit without the spec vs 6.1ms with it, 1 frame held either
        // way. (Overfeeding it at ~320fps does queue ~8 frames, hence the cap.)
        var status = createCompressionSession(width: width, height: height, lowLatency: lowLatency)
        var usedFallback = false
        if encoder == nil, lowLatency {
            Log.info("VTCompressionSessionCreate failed with low-latency rate control (status \(status)) — retrying without an encoder specification")
            status = createCompressionSession(width: width, height: height, lowLatency: false)
            usedFallback = true
        }
        guard let encoder else {
            // Returning here used to leave the session "connected, all green"
            // with a dead encoder and a black receiver. Throw so the failure
            // reaches the UI as a red "Failed:" status.
            Log.info("FATAL: VTCompressionSessionCreate failed (status \(status))")
            throw NSError(domain: "MacSender", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "This Mac's video encoder could not be started (VideoToolbox error \(status))"
            ])
        }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        // Same clamp as `startCapture`, from the same numbers — the encoder and
        // the capture rate limiter must agree, or SCK delivers frames the
        // encoder is over budget for.
        let timing = StreamTiming.encoder(rate: frameRate, quality: quality,
                                          width: width, height: height)
        let targetFPS = timing.expectedFrameRate
        let effectiveBitrate = timing.bitrate
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: timing.maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        // The configured value, remembered before adaptation touches anything:
        // it is the CEILING the controller clamps to, and it is a property of
        // the settings (rate x quality preset), not of the encoded size — so a
        // capture-scale change rebuilds the session without moving it.
        configuredBitrate = effectiveBitrate
        // A rebuild caused by adaptation must come back at the rate adaptation
        // had settled on, not at the configured one; anything else would be a
        // free step back up that nothing decided.
        let startBitrate = adaptive.map { min($0.targetBps, effectiveBitrate) } ?? effectiveBitrate
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: startBitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: timing.expectedFrameRate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        encoderSize = (width, height)
        Log.info("encoder ready: \(width)x\(height) H.264 \(startBitrate / 1_000_000)Mbps"
                 + "\(startBitrate == effectiveBitrate ? "" : " (ceiling \(effectiveBitrate / 1_000_000)Mbps)")"
                 + " @\(targetFPS)fps (asked \(frameRate.rawValue)) quality=\(quality.rawValue)"
                 + " scale=\(activeScale.rawValue)"
                 + " lowLatencyRC=\(lowLatency && !usedFallback)\(usedFallback ? " (fallback)" : "")")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        // Audio arrives on audioQueue, video on queue — dispatched by SCK to
        // whichever queue the output was registered with, so this method runs
        // on both and must route before touching any video state.
        if type == .audio {
            guard stream === self.stream, CMSampleBufferIsValid(sampleBuffer) else { return }
            handleAudio(sampleBuffer)
            return
        }
        guard stream === self.stream,
              type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let generation = captureGenerationNow

        lastPixelBuffer = pixelBuffer
        lastCaptureAt = Date()
        capFrames += 1

        // No receiver, or a pipeline stage is backed up: skip this frame.
        guard connectionReady else { return }
        // Adaptive quality's last rung: deliver fewer frames to the encoder.
        // Done HERE, before the encode, for the same reason the backpressure
        // drops are — a frame that is not going to help is work not spent, and
        // a pre-encode skip leaves the H.264 reference chain intact (n → n+2 is
        // a normal P-frame), so nothing has to be re-keyed.
        if let cap = deliveredFrameCap {
            let now = CACurrentMediaTime()
            // A hair under the interval: the capture clock and this one beat
            // against each other, and rejecting a frame that is 0.1 ms early
            // would halve the delivered rate rather than cap it.
            if now - lastDeliveredFrameAt < (1.0 / Double(max(cap, 1))) * 0.95 { return }
            lastDeliveredFrameAt = now
        }
        if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
        // There is deliberately NO send-queue gate here any more. Round 8
        // dropped the newest capture once three writes were outstanding, which
        // means the frames that eventually reach the receiver are the oldest
        // ones — `fps 1` against `capFps 28` in the operator's log is exactly
        // that. The queue below keeps the newest and evicts the oldest, so the
        // freshest picture must be allowed to reach it. The cost is encode work
        // on a frame that may be evicted; it is bounded, because the first
        // thing the controller does on a congested link is cut the capture rate.

        // A capture whose size no longer matches the compression session means
        // a scale change landed: rebuild the encoder here, on this queue,
        // before the frame is handed over. Doing it from the size of the buffer
        // rather than from a flag makes the change safe in either order.
        let bufferSize = (wide: CVPixelBufferGetWidth(pixelBuffer),
                          high: CVPixelBufferGetHeight(pixelBuffer))
        if encoderSize != bufferSize {
            rebuildEncoderForNewCaptureSize(bufferSize)
            guard encoderSize == bufferSize else { return }
        }

        pipelineLock.lock()
        framesEncodedTotal += 1
        pipelineLock.unlock()
        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), generation: generation)
    }

    // MARK: - Audio capture (runs on audioQueue)

    /// Encode one captured audio buffer and put it on the wire.
    ///
    /// Everything here is best-effort by design: audio must never be able to
    /// stall video or end a session. A receiver too old to understand audio
    /// frames, an encoder that will not build, a backed-up socket — each drops
    /// the audio and leaves the display running.
    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let encoder = audioEncoder else { return }

        // Audio frames only exist in the tagged framing of protocol 4+. Sending
        // one to an older receiver would be read as video and corrupt the
        // decoder, so this gate is load-bearing, not an optimisation.
        //
        // `connectionReady` and `peerSpeaksTaggedFrames` are decided on
        // `queue`; this reads the single published boolean instead of the two
        // fields, because reading them directly from here is a data race on
        // every connection transition.
        audioLock.lock()
        let gateOpen = audioGateOpen
        let gateReason = audioGateReason
        audioLock.unlock()
        guard gateOpen else {
            if !loggedAudioUnsupportedPeer {
                loggedAudioUnsupportedPeer = true
                Log.info("audio: not sent — \(gateReason)")
            }
            return
        }

        // Late audio is worse than absent audio: if the socket is already
        // backed up, drop this packet rather than deepening the queue.
        // `sendQueueDepthPublished` is the video queue's depth, republished
        // from `queue` under this lock — the audio path must not reach across
        // for the queue itself.
        pipelineLock.lock()
        let backedUp = sendQueueDepthPublished >= maxSendQueueDepth
        pipelineLock.unlock()
        if backedUp {
            audioLock.lock()
            audioDropsThisWindow += 1
            audioLock.unlock()
            return
        }

        guard let format = sampleBuffer.formatDescription.map({ AVAudioFormat(cmAudioFormatDescription: $0) }),
              encoder.prepare(for: format),
              let pcm = Self.pcmBuffer(from: sampleBuffer, format: format),
              let encoded = encoder.encode(pcm) else { return }

        // Capture time on our own clock, matching the units the video path
        // stamps frames with, so the receiver can align the two with the
        // ping/pong offset it already maintains.
        // Wall clock, matching the video path's `cap` stamp (see the telemetry
        // prefix in the capture callback). CMSampleBuffer presentation stamps
        // are mach uptime — seconds since boot — so using them here put audio
        // on a different epoch from video: the receiver's latency calculation
        // landed far outside its sanity window, was discarded, and both
        // aE2e50 and avSkew read a permanent 0.
        let ptsMs = Date().timeIntervalSince1970 * 1000

        // The sequence number. Handed out here and nowhere else, so it is
        // strictly increasing per packet by construction: a duplicate on the
        // receiver therefore cannot have been produced by this Mac, and the
        // receiver's duplicate counter means what it says.
        audioLock.lock()
        let stamping = peerWantsAudioSequenceForEncoder
        audioLock.unlock()
        var sequence: UInt32?
        if stamping {
            sequence = nextAudioSequence
            nextAudioSequence &+= 1
        }

        let packet = AudioPacket(codec: .aacLC,
                                 hasConfig: encoded.hasConfig,
                                 sampleRate: encoder.sampleRate,
                                 channels: encoder.channels,
                                 ptsMs: ptsMs,
                                 sequence: sequence,
                                 payload: encoded.data)
        sendAudio(packet.encoded())
        audioLock.lock()
        audioPacketsSent += 1
        audioLock.unlock()
    }

    /// Copy a captured audio buffer into a PCM buffer the converter accepts.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer,
                                  format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return pcm
    }

    /// Frame and send an audio packet. Separate from `sendFramed` because
    /// audio must not touch the video path's pending-send accounting, which
    /// drives frame-drop decisions.
    ///
    /// The hop back to `queue` is deliberate. `connection`, `connectionReady`
    /// and `peerSpeaksTaggedFrames` are all decided there, and reading them
    /// from `audioQueue` — as this did — is a data race that a reconnect can
    /// lose: the window between "the socket was replaced" and "the flag says
    /// so" is exactly when a stale reference gets a frame. The expensive part
    /// (PCM copy, AAC encode) stays on `audioQueue`; what crosses is a ~350
    /// byte `Data` about 47 times a second, and `NWConnection.send` does not
    /// block, so video is queued behind a dispatch, never behind audio work.
    private func sendAudio(_ payload: Data) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection,
                  self.connectionReady, self.peerSpeaksTaggedFrames else { return }
            let frame = FrameCodec.encode(payload, type: .audio, tagged: true)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    private func isPipelineBackedUp() -> Bool {
        pipelineLock.lock()
        let encodeBusy = pendingEncodes >= maxPendingEncodes
        pipelineLock.unlock()
        return encodeBusy || sendQueue.isFull
    }

    /// Schedule (or reset) a one-shot replay of `lastPixelBuffer` after drops.
    private func scheduleDropReplayTimer() {
        dropReplayTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let replayDelayMs = max(15, 1000 / frameRate.rawValue)
        timer.schedule(deadline: .now() + .milliseconds(replayDelayMs))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.dropReplayTimer = nil
            self.replayLastFrameAfterDrop()
        }
        timer.resume()
        dropReplayTimer = timer
    }

    private func cancelDropReplayTimer() {
        dropReplayTimer?.cancel()
        dropReplayTimer = nil
    }

    /// Re-encode the most recent pixel buffer once backpressure clears.
    private func replayLastFrameAfterDrop() {
        guard !stopped, connectionReady, let pixelBuffer = lastPixelBuffer else { return }
        if isPipelineBackedUp() {
            scheduleDropReplayTimer()
            return
        }
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()),
               generation: captureGenerationNow)
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        pipelineLock.lock()
        let drop: Bool
        switch reason {
        case "pending_encode":
            drop = pendingEncodes >= maxPendingEncodes
        default:
            drop = false
        }
        pipelineLock.unlock()
        guard drop else { return false }
        scheduleDropReplayTimer()
        if reason == "pending_encode" {
            dropsEncThisWindow += 1
            dropsEncTotal += 1
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, generation: UInt64) {
        guard generation == captureGenerationNow, let encoder else { return }
        // A cached buffer from before a scale change belongs to a different
        // compression session. The replay paths (`replayLastFrameAfterDrop`,
        // the watchdog's static-screen IDR) reach here without going past the
        // capture callback's size check, so it is repeated here.
        guard CVPixelBufferGetWidth(pixelBuffer) == encoderSize.wide,
              CVPixelBufferGetHeight(pixelBuffer) == encoderSize.high else { return }
        pipelineLock.lock()
        pendingEncodes += 1
        pipelineLock.unlock()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            defer {
                self.pipelineLock.lock()
                self.pendingEncodes = max(0, self.pendingEncodes - 1)
                self.pipelineLock.unlock()
            }
            guard status == noErr, let buffer else {
                // A session rejecting every frame looks healthy in all other
                // counters — the receiver just stays black. Don't be silent.
                self.pipelineLock.lock()
                let logAction = self.encodeOutputFailureLogPolicy.record(
                    status,
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.pipelineLock.unlock()
                self.handleEncodeOutputFailureLogAction(logAction)
                return
            }
            guard generation == self.captureGenerationNow else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus == noErr {
            // Encode submission commits this frame to the pipeline; stale in-flight
            // encodes started before a drop won't reach here again, so cancel replay.
            cancelDropReplayTimer()
        } else {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            // A dead encoder session keeps failing, and this runs per frame, so
            // an unthrottled line here is ~60/sec for as long as the problem
            // lasts. Report at most once a second and carry the count: the
            // status code is the diagnosis, the rate is just a number.
            let logAction = encodeFailureLogPolicy.record(
                submitStatus,
                at: ProcessInfo.processInfo.systemUptime
            )
            pipelineLock.unlock()
            handleEncodeFailureLogAction(logAction)
        }
    }

    private func handleEncodeFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeFailureLog() {
        pipelineLock.lock()
        let report = encodeFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeFailures(report) }
    }

    private func reportEncodeFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        Log.info("VTCompressionSessionEncodeFrame failed: \(report.detail) (\(report.count) since last report)")
    }

    private func handleEncodeOutputFailureLogAction(_ action: ThrottledLogPolicy<OSStatus>.Action) {
        switch action {
        case .report(let report):
            reportEncodeOutputFailures(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushEncodeOutputFailureLog()
            }
        case .none:
            break
        }
    }

    private func flushEncodeOutputFailureLog() {
        pipelineLock.lock()
        let report = encodeOutputFailureLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime)
        pipelineLock.unlock()
        if let report { reportEncodeOutputFailures(report) }
    }

    private func reportEncodeOutputFailures(_ report: ThrottledLogPolicy<OSStatus>.Report) {
        // VideoToolbox can reject a frame with noErr + a nil buffer (e.g.
        // above the H.264 level pixel-rate ceiling) — call that case out.
        let cause = report.detail == noErr ? "nil buffer despite noErr" : "status \(report.detail)"
        Log.info("encoder output rejected: \(cause) (\(report.count) since last report)")
    }

    // Runs on `queue`, where the policy and the control connection both live.
    private func handleUnparseableControlLogAction(_ action: ThrottledLogPolicy<Int>.Action) {
        switch action {
        case .report(let report):
            reportUnparseableControl(report)
        case .schedule(let delay):
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushUnparseableControlLog()
            }
        case .none:
            break
        }
    }

    private func flushUnparseableControlLog() {
        if let report = unparseableControlLogPolicy.flush(at: ProcessInfo.processInfo.systemUptime) {
            reportUnparseableControl(report)
        }
    }

    private func reportUnparseableControl(_ report: ThrottledLogPolicy<Int>.Report) {
        Log.info("unparseable control message (\(report.detail) bytes, \(report.count) since last report)")
    }

    // MARK: - H.264 -> Annex B

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    /// Control messages on the video channel (pong etc.) — framed JSON without
    /// start codes; the receiver routes payloads starting with '{'.
    // MARK: - Version handshake (issue #132)

    /// Identify ourselves to the receiver: our protocol version and the oldest
    /// receiver version we still support.
    /// This Mac's name, for the receiver's "Connect to" list. `localizedName`
    /// is the Sharing pane's computer name — what the user calls this machine.
    static let hostName: String =
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    /// A UUID persisted in this sender's defaults domain. Stable across
    /// restarts and renames, which is what the receiver's preference is keyed
    /// on. Computed once per process.
    static let senderID: String = SenderIdentityStore.localSenderID()

    private func sendWelcome() {
        // `host` and `senderID` are additive at pv 4 with no bump: a receiver
        // that predates them ignores unknown fields, exactly as PROTOCOL.md
        // section 6 requires, and a Mac that predates them is simply a Mac the
        // receiver cannot tell apart from any other.
        //
        // Built with JSONSerialization rather than string interpolation because
        // a computer name is user-supplied text: "Alice's MacBook «Pro»" has to
        // survive being put on a wire.
        let dict: [String: Any] = [
            "type": WireMessage.welcome,
            "pv": WireProtocol.version,
            "min": WireProtocol.minSupportedPeer,
            "host": Self.hostName,
            "senderID": Self.senderID,
            // Additive capability (PROTOCOL.md 6.3): this sender reads `stats`
            // datagrams off the UDP cursor flow. A receiver that has never
            // heard of it keeps sending the TCP copy alone, which is what every
            // build before this one did.
            StatsChannel.capabilityKey: true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
            return
        }
        sendJSONFrame(json)
    }

    /// Ask the receiver to update (built via JSONSerialization because the
    /// message text is user-facing prose). Dormant while minSupportedPeer is
    /// 1, but the copy must fit the platform the day a floor is raised: a
    /// Mac receiver updates via Sparkle/the site, not the App Store.
    private func sendUpdateRequired(kind: String) {
        let isMac = kind == "Mac"
        let dict: [String: Any] = [
            "type": WireMessage.updateRequired,
            "target": isMac ? "mac" : "ios",
            "store": isMac ? "https://opendisplay.app" : AppStore.updateURL.absoluteString,
            "message": isMac
                ? "The OpenDisplay Receiver app on that Mac is too old for this Mac. Use Check for Updates… there to reconnect."
                : "This \(kind) app is too old for this Mac. Update OpenDisplay from the App Store to reconnect.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            sendJSONFrame(json)
        }
    }

    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        let frame = FrameCodec.encode(Data(json.utf8), type: .json,
                                      tagged: peerSpeaksTaggedFrames)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// Put an encoded frame on the wire, through the latency-first queue.
    ///
    /// Runs on `queue` (the VideoToolbox completion hops here via `encode`'s
    /// caller), which is the only executor allowed to touch `connection` and
    /// therefore the only one allowed to touch the queue.
    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        let frame = FrameCodec.encode(payload, type: .video,
                                      tagged: peerSpeaksTaggedFrames)
        let evicted = sendQueue.enqueue(frame)
        if !evicted.isEmpty {
            // These are frames the link could not take: the same fact `net↓`
            // has always counted, measured where it actually happens now.
            dropsNetThisWindow += evicted.count
            dropsNetTotal += evicted.count
            // An evicted frame breaks the reference chain for everything after
            // it. Ask for an IDR so recovery is immediate — throttled, because
            // an IDR is a bitrate spike and one per evicted frame would deepen
            // the very queue it is recovering from.
            if keyframeAfterDrop.shouldRequestIdr(evictedFrames: evicted.count,
                                                  at: ProcessInfo.processInfo.systemUptime) {
                needsKeyframe = true
            }
        }
        publishSendQueueDepth()
        pumpSendQueue(connection)
    }

    /// Write the next queued frame if the link has a slot free.
    private func pumpSendQueue(_ connection: NWConnection) {
        guard let frame = sendQueue.dequeue() else { return }
        let startedAt = CACurrentMediaTime()
        writeStartedAt = startedAt
        publishSendQueueDepth()
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            // `NWConnection` completions arrive on the connection's queue,
            // which is `queue` — the same executor the rest of this state
            // lives on, so no hop and no lock is needed for the queue itself.
            self.sendQueue.completed()
            self.writeStartedAt = 0
            let elapsedMs = (CACurrentMediaTime() - startedAt) * 1000
            self.writeCompletionsThisTick.append(elapsedMs)
            if let error {
                Log.info("send error: \(error)")
                self.publishSendQueueDepth()
                return
            }
            self.framesSent += 1
            self.bytesSent += frame.count
            self.bytesDeliveredTotal += frame.count
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                let frames = self.framesSent
                self.bytesSent = 0
                self.statsWindowStart = Date()
                Task { @MainActor in self.onStats?(frames, mbps) }
            }
            self.publishSendQueueDepth()
            if let connection = self.connection, self.connectionReady {
                self.pumpSendQueue(connection)
            }
        })
    }

    /// Republish the depth for the audio path, which lives on another queue and
    /// must not reach across for it.
    private func publishSendQueueDepth() {
        pipelineLock.lock()
        sendQueueDepthPublished = sendQueue.depth
        pipelineLock.unlock()
    }

    /// A new connection inherits nothing: the frames queued for the old socket
    /// are for a peer that is gone, and the IDR throttle must not suppress the
    /// keyframe the new peer needs.
    private func resetSendQueue() {
        sendQueue.reset()
        keyframeAfterDrop.reset()
        writeStartedAt = 0
        writeCompletionsThisTick.removeAll(keepingCapacity: true)
        publishSendQueueDepth()
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        await MainActor.run { onStatus?(text) }
    }

    /// Invalidate the retired ScreenCaptureKit/VideoToolbox callbacks before
    /// changing the display or encoder they feed.
    private func invalidateCapturePipeline(discardingLastFrame: Bool = false) {
        inputInjector?.reset()
        pipelineLock.lock()
        captureGeneration &+= 1
        pipelineLock.unlock()
        captureDisplayID = 0
        if discardingLastFrame {
            lastPixelBuffer = nil
            lastCaptureAt = .distantPast
        }
    }
}
