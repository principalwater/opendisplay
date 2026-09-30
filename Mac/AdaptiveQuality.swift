// Adaptive quality — a congestion controller, not a five-rung ladder.
//
// Pure, and in its own file for the usual reason: `MacSender` owns
// ScreenCaptureKit, VideoToolbox and a socket, and none of those can be stood
// up in a test. What is here is only the decision — given what the last tick
// measured, what bitrate should the encoder be asked for, at what frame rate,
// at what capture scale.
//
// ## Why this was rewritten
//
// Round 8 shipped a ladder of five fixed fractions of the configured bitrate
// (100/70/50/35/35+60fps) with a 1 s step-down hold and a 10 s recovery. The
// operator's 2026-09-18 15:29–15:33 session over LTE (iPhone tethering →
// Tailscale → **DERP relay**, i.e. the video rides one TCP connection through
// a relay) is the evidence that it does not work, and each number below is
// from that log:
//
// * **The floor was three times the link.** The receiver's `mbps` ranged over
//   0.1–3.2. The ladder's bottom rung is 35% of 28.8 Mbps = **10 Mbps**. At
//   its most degraded the controller was still asking for about three times
//   what the path could carry, so the path was in permanent congestion and no
//   amount of stepping could end it. Nothing below 10 Mbps was expressible.
// * **It oscillated.** Ten level changes in two minutes — down 1, up 0, down 1,
//   down 2, up 1, down 2, down 3, up 2, up 1, up 0 — and three of them one
//   second apart (15:29:55 / :56 / :57), before the previous change could
//   possibly have shown up in any statistic.
// * **It was blind when it mattered.** Several step-downs carry
//   `e2e95=0ms rtt=0ms`: there was no fresh receiver report at that instant.
//   Reports travel over the *same congested TCP connection as the video*, so
//   on a bad link they arrive every 10–60 s instead of every 5
//   (15:31:00 → 15:31:54 → 15:32:01 → 15:32:21 → 15:33:04). The controller
//   was steering on encoder drops, which are a CPU signal, not a link signal.
// * **Head-of-line blocking made latency explode.** `e2e95` reached 608, 1560
//   and 1902 ms while `fps` collapsed to 1–16 against a `capFps` of 7–28.
//   Once a TCP queue builds on a relayed path it does not drain until the
//   sender stops pushing.
//
// ## What replaced it
//
// 1. A **continuous target rate**: estimate what the path actually delivers,
//    aim at 85% of it, clamp to `[floor, configured]` with the floor at
//    `adaptiveFloorKbps` (default **800 kbps**, not 10 Mbps).
// 2. **Ranked signals**: the sender's own backlog first (immediate, needs no
//    receiver), then a delay gradient against a per-session baseline (a queue
//    building, with zero drops), then drop counters. AIMD — ×0.7 down,
//    +10% up.
// 3. **Timing discipline**: 2.5 s cooldown after any change, 15 s of clean
//    signals before any increase, 60 s penalty memory on a rate that just
//    failed, never more than one change per cooldown.
// 4. **Deeper levers** when bitrate alone cannot help: frame rate 120→60→30
//    (the *capture* rate too), then capture scale best→balanced→fast.
//    **Round 10 caps the ladder at the frame rate by default**
//    (`adaptiveMaxLever`, `Mac/DisplayLifecycle.swift`): round 9's scale change
//    was the last thing the operator's session did before the Mac stopped
//    drawing its own lock screen. The bug was not in this file — it was a fight
//    between the capture rebuild and `VirtualDisplay`'s enforcement loop, and it
//    is fixed there — but the lever stays out of the ladder until a real session
//    proves it.
// 5. A **per-path-class memory**, so the next LTE session starts where the
//    last one settled instead of at 28.8 Mbps.
//
// The two effects that are *not* here, because they are not decisions:
// `Mac/VideoSendQueue.swift` bounds what may sit unsent, and the receiver's
// stats now also ride the UDP cursor channel (PROTOCOL.md 6.3) so this
// controller can see the link while TCP is backed up.

import Foundation

// MARK: - Path class

/// Which kind of path this session runs over, as far as a congestion
/// controller needs to care.
///
/// The tailnet classes are RTT buckets for operating-point memory. RTT alone
/// cannot identify a direct versus DERP route: a nearby DERP may be faster
/// than a long-distance direct hop. The stored case names remain stable for
/// existing preferences, while log labels describe only what was measured.
enum PathClass: String, CaseIterable, Equatable {
    case lan
    // Keep the raw values so previously learned operating points still load.
    case tailnetLowRTT = "tailnetDirect"
    case tailnetHighRTT = "tailnetRelay"

    /// What the log calls it.
    var label: String {
        switch self {
        case .lan: return "lan"
        case .tailnetLowRTT: return "tailnet-low-rtt"
        case .tailnetHighRTT: return "tailnet-high-rtt"
        }
    }

    /// Round trips at or below this are a local network. A LAN hop is 1–8 ms;
    /// the operator's relayed session measured 60–156 ms.
    static let lanRttMs = 12.0
    /// Split remembered tailnet operating points by observed RTT. This is a
    /// latency bucket, not a test for the actual Tailscale route.
    static let highRttThresholdMs = 60.0

    /// Classify a session.
    ///
    /// **The address is checked before the interface**, and that ordering is a
    /// bug fix rather than a preference. The operator's relayed session logs
    /// `connection path to …: utun4 wired=true direct=false`: Tailscale's own
    /// tunnel is not WiFi, not loopback and not cellular, so the sender's
    /// long-standing "is this wired?" test answers **yes** for it. An
    /// interface-first classifier would call an LTE session over a DERP relay
    /// a LAN and hand it the LAN's 28.8 Mbps operating point.
    ///
    /// - Parameters:
    ///   - directLink: the sender's existing `direct=` flag — a host-to-host
    ///     cable to a Mac receiver.
    ///   - wired: the path really is Ethernet/Thunderbolt. Callers must test
    ///     `.wiredEthernet` specifically; "not WiFi" is not the same question.
    ///   - tailnet: the endpoint address is a tailnet address (see
    ///     `TailnetAddress`). Known immediately from the dial, which matters:
    ///     the first RTT measurement is five seconds away, and the first five
    ///     seconds of an LTE session are exactly when a 28.8 Mbps start does
    ///     its damage.
    ///   - rttMs: the receiver's measured control-channel round trip, or nil
    ///     before the first report.
    static func classify(directLink: Bool, wired: Bool,
                         tailnet: Bool, rttMs: Double?) -> PathClass {
        if tailnet {
            // No measurement yet: use the low-RTT memory bucket until the
            // first report. The start rate is capped for either bucket.
            guard let rttMs, rttMs > 0 else { return .tailnetLowRTT }
            return rttMs < highRttThresholdMs ? .tailnetLowRTT : .tailnetHighRTT
        }
        if directLink || wired { return .lan }
        guard let rttMs, rttMs > 0 else { return .lan }
        if rttMs < lanRttMs { return .lan }
        return rttMs < highRttThresholdMs ? .tailnetLowRTT : .tailnetHighRTT
    }
}

/// Whether an address belongs to a tailnet.
///
/// Tailscale hands out `100.64.0.0/10` (the CGNAT range) for IPv4 and
/// `fd7a:115c:a1e0::/48` for IPv6, and MagicDNS names end in `.ts.net`. Any of
/// the three is proof the session is not on the local wire, which is the only
/// question this answers.
enum TailnetAddress {

    static func isTailnet(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        // Strip an IPv6 zone id ("fe80::1%en0") and any port suffix a caller
        // may have left on a host:port string.
        let bare = trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed
        if bare.lowercased().hasSuffix(".ts.net") { return true }
        if isTailnetIPv4(bare) { return true }
        return bare.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func isTailnetIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0, value <= 255 else { return false }
            octets.append(value)
        }
        // 100.64.0.0/10 — the first octet is 100 and the second is 64…127.
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127
    }
}

// MARK: - The evidence

/// One tick's worth of evidence about the link.
///
/// Split deliberately into what the **sender** knows (always current, needs no
/// cooperation, and is the top-ranked signal for exactly that reason) and what
/// the **receiver** last said (richer, but possibly a minute old on the link
/// where it matters most — hence `receiverIsFresh`).
struct LinkSample: Equatable {

    // ── (a) Sender-local: immediate, independent of the receiver ───────────

    /// Encoded frames written or waiting to be written, right now.
    var sendQueueDepth = 0
    /// What `VideoSendQueue` allows before it evicts. Passed in rather than
    /// hardcoded so the two can never disagree.
    var maxSendQueueDepth = 3
    /// How long the oldest outstanding `NWConnection.send` has been
    /// outstanding, ms. This is the sender's own measure of "the socket is not
    /// taking bytes", and it needs nothing from the far end.
    var oldestWriteAgeMs = 0.0
    /// 95th percentile write-completion latency over this tick, ms.
    var writeCompletionP95Ms = 0.0
    /// Frames the send queue dropped (oldest-first) in this tick.
    var evictedFrames = 0
    /// Captures skipped because an encode was still in flight. **Not a link
    /// signal** — see `LinkHealth`.
    var senderEncDrops = 0
    /// Frames submitted to the encoder in this tick.
    var framesEncoded = 0
    /// Bytes whose send completion fired in this tick: the sender's own lower
    /// bound on what the path took.
    var bytesDelivered = 0
    /// Length of this tick, seconds. Never zero.
    var tickSeconds = 0.5

    // ── (b)/(c) Receiver-reported: richer, and possibly stale ──────────────

    /// True only on the tick a *new* report is consumed. Every rule that reads
    /// a receiver field is gated on this, because the round-8 controller's
    /// worst decisions were taken with `e2e95=0ms rtt=0ms` in the log line.
    var receiverIsFresh = false
    /// Age of the newest report, seconds. Reported so the log can say how
    /// blind the controller currently is.
    var receiverAgeSeconds = 0.0
    /// The receiver's own goodput measurement over its 1 s window, Mbps.
    var receiverGoodputMbps = 0.0
    var receiverE2eP50Ms = 0.0
    var receiverE2eP95Ms = 0.0
    /// Frames the receiver saw arrive more than 50 ms late.
    var receiverStalls = 0
    /// Control-channel round trip as the receiver measured it, ms. Used to
    /// classify the path, never as a congestion signal on its own.
    var receiverRttMs = 0.0

    init(sendQueueDepth: Int = 0, maxSendQueueDepth: Int = 3,
         oldestWriteAgeMs: Double = 0, writeCompletionP95Ms: Double = 0,
         evictedFrames: Int = 0, senderEncDrops: Int = 0, framesEncoded: Int = 0,
         bytesDelivered: Int = 0, tickSeconds: Double = 0.5,
         receiverIsFresh: Bool = false, receiverAgeSeconds: Double = 0,
         receiverGoodputMbps: Double = 0, receiverE2eP50Ms: Double = 0,
         receiverE2eP95Ms: Double = 0, receiverStalls: Int = 0,
         receiverRttMs: Double = 0) {
        self.sendQueueDepth = sendQueueDepth
        self.maxSendQueueDepth = maxSendQueueDepth
        self.oldestWriteAgeMs = oldestWriteAgeMs
        self.writeCompletionP95Ms = writeCompletionP95Ms
        self.evictedFrames = evictedFrames
        self.senderEncDrops = senderEncDrops
        self.framesEncoded = framesEncoded
        self.bytesDelivered = bytesDelivered
        self.tickSeconds = max(tickSeconds, 0.001)
        self.receiverIsFresh = receiverIsFresh
        self.receiverAgeSeconds = receiverAgeSeconds
        self.receiverGoodputMbps = receiverGoodputMbps
        self.receiverE2eP50Ms = receiverE2eP50Ms
        self.receiverE2eP95Ms = receiverE2eP95Ms
        self.receiverStalls = receiverStalls
        self.receiverRttMs = receiverRttMs
    }

    /// Bits per second the sender itself watched leave. A *lower* bound on the
    /// path's capacity: it can be small because the path is slow, or because
    /// the screen was static and there was nothing to send.
    var senderDeliveredBps: Double {
        Double(bytesDelivered) * 8 / tickSeconds
    }

    /// Whether anything was waiting. When nothing was, a small delivered rate
    /// says nothing about capacity (the classic app-limited sample) and must
    /// never be allowed to pull the estimate down.
    var wasSaturated: Bool {
        sendQueueDepth >= 2 || evictedFrames > 0
    }
}

// MARK: - Rate estimation

/// What the path delivers, smoothed.
///
/// Two sources, and the rule that keeps them honest: a sample taken while
/// nothing was queued (`wasSaturated == false`) may only *raise* the estimate,
/// never lower it. Without that rule a static screen — which sends almost
/// nothing — reads as a collapsed link, the target follows it down, and the
/// session never recovers even though the path was fine the whole time.
struct DeliveredRateEstimator: Equatable {

    /// EWMA weight for a real (saturated) capacity measurement.
    static let alpha = 0.3

    private(set) var estimateBps: Double = 0
    private(set) var samples = 0

    init(seedBps: Double = 0) {
        estimateBps = max(0, seedBps)
    }

    /// The best single number this tick offers, or nil when it offers none.
    static func observation(_ sample: LinkSample) -> Double? {
        let sender = sample.senderDeliveredBps
        let receiver = sample.receiverIsFresh ? sample.receiverGoodputMbps * 1_000_000 : 0
        // The receiver measures what actually arrived; the sender measures what
        // the socket accepted. The larger is the better lower bound on the
        // path, and on a backed-up TCP connection they disagree by a lot.
        let best = max(sender, receiver)
        return best > 0 ? best : nil
    }

    mutating func ingest(_ sample: LinkSample) {
        guard let observation = Self.observation(sample) else { return }
        samples += 1
        guard estimateBps > 0 else {
            estimateBps = observation
            return
        }
        // A saturated tick measured the path and may move the estimate either
        // way. An app-limited tick only proves a lower bound, so it may raise
        // the estimate and must never lower it.
        guard sample.wasSaturated || observation > estimateBps else { return }
        estimateBps += (observation - estimateBps) * Self.alpha
    }

    /// Seed from a remembered operating point so the first decision of a
    /// session is not taken against a zero.
    mutating func seed(_ bps: Double) {
        guard bps > 0, estimateBps == 0 else { return }
        estimateBps = bps
    }
}

// MARK: - Delay gradient

/// A per-session latency baseline, and the rule for "the queue is building".
///
/// This is the signal the round-8 controller had no way to express. A relayed
/// TCP path fills its queue *without dropping anything*: every byte arrives,
/// just later and later. `e2e50` climbing from 54 ms to 146 ms with `stalls`
/// at zero is congestion, and the only evidence of it is the gradient.
struct DelayBaseline: Equatable {

    /// How many observations before the baseline is trusted. One sample is a
    /// number, not a baseline.
    static let minimumSamples = 3
    /// The latency floor is allowed to drift upward this fast when every
    /// observation sits above it, so a session that began on a good link and
    /// moved to a worse one is not pinned to an unreachable baseline forever.
    static let driftRate = 0.02
    /// Absolute ceiling on `e2e95`, whatever the baseline says. Four times the
    /// "feels direct" threshold, and past anything a healthy path produces.
    static let hardCeilingP95Ms = 300.0
    /// The gradient must clear this many ms above the baseline before it
    /// counts, so ordinary jitter on a mobile link is not congestion.
    static let minimumRiseMs = 60.0

    private(set) var baselineMs = 0.0
    private(set) var samples = 0

    var isReady: Bool { samples >= Self.minimumSamples && baselineMs > 0 }

    /// Feed one fresh `e2e50`.
    mutating func observe(e2eP50Ms: Double) {
        guard e2eP50Ms > 0, e2eP50Ms.isFinite else { return }
        samples += 1
        if baselineMs == 0 || e2eP50Ms < baselineMs {
            baselineMs = e2eP50Ms
        } else {
            baselineMs += (e2eP50Ms - baselineMs) * Self.driftRate
        }
    }

    /// The `e2e50` at which the median is judged to be queueing: the baseline
    /// doubled, or 60 ms above it, whichever is further away.
    var triggerP50Ms: Double {
        max(baselineMs * 2, baselineMs + Self.minimumRiseMs)
    }

    /// Whether this report shows a queue building rather than a link that is
    /// simply far away.
    func isQueueBuilding(e2eP50Ms: Double, e2eP95Ms: Double) -> Bool {
        if e2eP95Ms > Self.hardCeilingP95Ms { return true }
        guard isReady else { return false }
        return e2eP50Ms > triggerP50Ms
    }

    mutating func reset() {
        baselineMs = 0
        samples = 0
    }
}

// MARK: - The verdict

/// Which signal fired, in the order they are trusted.
///
/// The order is the design. `senderBacklog` needs nothing from the far end and
/// is true the instant it is true; `delayGradient` needs a fresh report but
/// sees congestion even when no frames have been evicted.
enum CongestionSignal: String, Equatable, CaseIterable {
    case senderBacklog
    case delayGradient

    var label: String {
        switch self {
        case .senderBacklog: return "sender-backlog"
        case .delayGradient: return "delay-gradient"
        }
    }
}

enum LinkVerdict: Equatable {
    case congested(CongestionSignal)
    case clean
    case neither
}

enum LinkHealth {

    /// A single write outstanding for longer than this is a socket that is not
    /// taking bytes. One frame at 30 fps is 33 ms; a quarter of a second is
    /// already seven frames of standing latency.
    static let stalledWriteMs = 250.0

    /// Encoder drops are **not** a link signal, and this is the single line
    /// that fixes the round-8 oscillation.
    ///
    /// `enc↓` counts captures skipped because VideoToolbox was still busy with
    /// the previous frame. That is a CPU/encoder measurement. The operator's
    /// three one-second step-downs at 15:29:55/56/57 read `net↓=0 enc↓=18`,
    /// `net↓=18 enc↓=21`, `net↓=0 enc↓=31` — two of the three were decided
    /// purely on encoder pressure, on a link that was not dropping a thing at
    /// that instant. Lowering the bitrate does not make an encoder faster;
    /// lowering the frame rate does, and that is what the lever ladder is for.
    static func encoderDropsAreNotCongestion() -> Bool { true }

    static func verdict(_ sample: LinkSample, baseline: DelayBaseline) -> LinkVerdict {
        // (a) The sender's own backlog. Always current, always available.
        if sample.evictedFrames > 0 { return .congested(.senderBacklog) }
        if sample.sendQueueDepth >= sample.maxSendQueueDepth { return .congested(.senderBacklog) }
        if sample.oldestWriteAgeMs > stalledWriteMs { return .congested(.senderBacklog) }
        if sample.writeCompletionP95Ms > stalledWriteMs { return .congested(.senderBacklog) }

        // (b) The delay gradient. Only from a report that actually arrived.
        if sample.receiverIsFresh,
           baseline.isQueueBuilding(e2eP50Ms: sample.receiverE2eP50Ms,
                                    e2eP95Ms: sample.receiverE2eP95Ms) {
            return .congested(.delayGradient)
        }

        // Receiver `stalls` count arrival gaps >50ms, including idle capture
        // and encoder pacing. They do not establish network congestion.

        // Clean means nothing went wrong, not "not much did" — recovery is the
        // direction that can make things worse, so its bar is the higher one.
        // A stale receiver does not block cleanliness: the sender's own
        // backlog is enough to say the socket is draining, and requiring a
        // fresh report would freeze the controller on exactly the link where
        // reports are rare.
        let senderClean = sample.evictedFrames == 0
            && sample.sendQueueDepth <= 1
            && sample.oldestWriteAgeMs <= stalledWriteMs / 2
        guard senderClean else { return .neither }
        if sample.receiverIsFresh {
            guard !baseline.isQueueBuilding(e2eP50Ms: sample.receiverE2eP50Ms,
                                            e2eP95Ms: sample.receiverE2eP95Ms)
            else { return .neither }
        }
        return .clean
    }
}

// MARK: - Levers

/// One rung of the deeper-lever ladder: a frame rate and a capture scale.
///
/// **Bitrate is deliberately not here any more.** It is continuous now, and a
/// rung is what you reach for when bitrate alone cannot help — when the target
/// rate has fallen so far that the current pixel rate cannot be encoded
/// legibly at it. On a 3 Mbps mobile link, 1194×834 at 30 fps is a far better
/// picture than 2388×1668 at 1 fps, which is what the operator actually got.
struct QualityLevel: Equatable {
    /// 0 is the configured operating point; higher is more degraded.
    let index: Int
    /// Frames per second to capture *and* deliver, or nil for "whatever the
    /// settings say". Lowering the capture rate as well as the delivered one
    /// is the point: it saves the encode the frame would have cost.
    let frameRateCap: Int?
    /// The capture scale. Only the encoded size changes — the virtual display
    /// keeps its mode, so the desktop layout does not move.
    let scale: StreamQuality

    var label: String {
        let rate = frameRateCap.map { "\($0) fps" } ?? "full rate"
        return "\(rate), \(scale.rawValue)"
    }

    /// What the panel shows. Level 0 has no adjective, because "adaptive
    /// quality is on and doing nothing" is a state the user should not have to
    /// think about.
    var statusText: String {
        index == 0 ? "full quality" : "reduced: \(label)"
    }

    /// The configured operating point, for a panel that has not yet heard from
    /// a controller. Only `index` is read there, and it is 0 — the row shows
    /// nothing until something is actually reduced.
    static let unconstrained = QualityLevel(index: 0, frameRateCap: nil, scale: .best)
}

/// The ladder for one session, plus the arithmetic that says when a rung is no
/// longer viable.
struct AdaptivePlan: Equatable {

    /// What the settings asked for, in bits per second — the ceiling, never
    /// exceeded.
    let configuredBitrateBps: Int
    let configuredFps: Int
    let configuredScale: StreamQuality
    /// The encoded size at scale 1.0, i.e. the panel's pixels. The rungs'
    /// sizes are fractions of this.
    let baseWide: Int
    let baseHigh: Int
    /// The lowest rate this controller may ever ask for.
    let floorBps: Int
    /// How deep the ladder is allowed to go. `.frameRate` drops the
    /// capture-scale rungs entirely, which is the shipping default — see
    /// `AdaptiveLeverCap`.
    let maxLever: AdaptiveLeverCap
    let levels: [QualityLevel]

    /// A rung stays viable while the target can pay **half** the bits per
    /// pixel per frame the configured operating point asks for.
    ///
    /// Half, and not a constant, because the configured point is the only
    /// honest reference: Best at 120 fps spends 28.8 Mbps over 2388×1668×120 =
    /// 0.060 bits/pixel/frame, and half of that is soft but legible screen
    /// content. Deriving it means a session configured at Fast/30 — already
    /// spending four times that density — gets a ladder measured against its
    /// own choice rather than against somebody else's.
    static let viabilityFraction = 0.5

    /// `maxLever` defaults to `.scale` — the *full* ladder — because that is
    /// what this type describes when nobody has capped it. What ships is
    /// `AdaptiveLeverCap.standard` (`.frameRate`), resolved from defaults by
    /// `AdaptiveQualityController.maxLever` and passed in by the sender. The two
    /// defaults differ on purpose: the plan's is "no restriction", the app's is
    /// "the restriction we currently believe in".
    init(configuredBitrateBps: Int, configuredFps: Int, configuredScale: StreamQuality,
         baseWide: Int, baseHigh: Int, floorBps: Int,
         maxLever: AdaptiveLeverCap = .scale) {
        self.configuredBitrateBps = max(1, configuredBitrateBps)
        self.configuredFps = max(1, configuredFps)
        self.configuredScale = configuredScale
        self.baseWide = max(1, baseWide)
        self.baseHigh = max(1, baseHigh)
        self.floorBps = max(1, min(floorBps, max(1, configuredBitrateBps)))
        self.maxLever = maxLever
        self.levels = Self.rungs(configuredFps: max(1, configuredFps),
                                 configuredScale: configuredScale,
                                 maxLever: maxLever)
    }

    /// Frame rate first, then scale — and only rungs strictly below the
    /// configured point.
    ///
    /// The order is the brief's, and it is right: halving the frame rate costs
    /// smoothness on a link that is not delivering smoothness anyway, while
    /// halving the scale costs sharpness on text, which is what a desktop is
    /// mostly made of. A session already configured at 30 fps and Fast has one
    /// rung — there is nothing left to give.
    ///
    /// **`maxLever` decides whether the scale rungs exist at all.** Round 9's
    /// scale change was the last thing the operator's session did before it
    /// froze the Mac, and the lever stays out of the ladder by default until it
    /// has been proven on a real link. Note what capping does *not* do: the
    /// continuous rate control, the ranked signals and the frame-rate rungs are
    /// untouched, so a capped ladder is still a working congestion controller —
    /// which is the whole reason this is a cap and not an off switch.
    static func rungs(configuredFps: Int, configuredScale: StreamQuality,
                      maxLever: AdaptiveLeverCap = .scale) -> [QualityLevel] {
        var out = [QualityLevel(index: 0, frameRateCap: nil, scale: configuredScale)]
        let rateSteps = [60, 30].filter { $0 < configuredFps }
        for rate in rateSteps {
            out.append(QualityLevel(index: out.count, frameRateCap: rate, scale: configuredScale))
        }
        guard maxLever == .scale else { return out }
        let lowestRate = rateSteps.last
        let scaleSteps: [StreamQuality] = [.balanced, .fast].filter { $0.scale < configuredScale.scale }
        for scale in scaleSteps {
            out.append(QualityLevel(index: out.count, frameRateCap: lowestRate, scale: scale))
        }
        return out
    }

    /// The encoded size at a rung. Even, because the encoder wants even.
    func encodedSize(_ level: QualityLevel) -> (wide: Int, high: Int) {
        let w = Int(Double(baseWide) * level.scale.scale) & ~1
        let h = Int(Double(baseHigh) * level.scale.scale) & ~1
        return (max(2, w), max(2, h))
    }

    func frameRate(_ level: QualityLevel) -> Int {
        min(configuredFps, level.frameRateCap ?? configuredFps)
    }

    /// Encoded pixels per second at a rung.
    func pixelRate(_ level: QualityLevel) -> Double {
        let size = encodedSize(level)
        return Double(size.wide) * Double(size.high) * Double(frameRate(level))
    }

    /// The lowest target rate at which this rung is still worth showing.
    func minimumViableBps(_ level: QualityLevel) -> Int {
        let top = pixelRate(levels[0])
        guard top > 0 else { return floorBps }
        let share = pixelRate(level) / top
        let bps = Double(configuredBitrateBps) * share * Self.viabilityFraction
        return max(1, Int(bps.rounded()))
    }

    /// How much better than the rung above's requirement the target must be
    /// before climbing back. Pure hysteresis: without it a target sitting on a
    /// boundary would rebuild the encoder every cooldown.
    static let recoveryHeadroom = 1.25

    /// The shallowest rung this rate can actually pay for.
    ///
    /// Used on the way **down** only, and it may skip rungs: a target that has
    /// just fallen from 28.8 to 1.3 Mbps belongs at 1194×834/30 immediately,
    /// not three cooldowns from now — seven and a half seconds of 2388×1668 at
    /// 1.3 Mbps is the picture the operator complained about. Recovery is the
    /// direction that goes one rung at a time.
    func viableIndex(targetBps: Int) -> Int {
        for level in levels where targetBps >= minimumViableBps(level) {
            return level.index
        }
        return levels.count - 1
    }
}

// MARK: - The remembered operating point

/// Where a path class was last seen to be stable.
struct OperatingPoint: Equatable {
    var targetKbps: Int
    var levelIndex: Int
}

/// Persistence for `OperatingPoint`, as pure dictionary arithmetic so it can be
/// tested without touching `UserDefaults`.
enum OperatingPointStore {

    static let defaultsKey = "adaptiveOperatingPoints"

    /// How long a point has to hold still before it is worth remembering. Long
    /// enough that the transient on the way down is never what gets stored.
    static let stableAfterSeconds = 20.0

    static func decode(_ stored: Any?, for pathClass: PathClass) -> OperatingPoint? {
        guard let root = stored as? [String: Any],
              let entry = root[pathClass.rawValue] as? [String: Any],
              let kbps = (entry["kbps"] as? NSNumber)?.intValue, kbps > 0
        else { return nil }
        let level = (entry["level"] as? NSNumber)?.intValue ?? 0
        return OperatingPoint(targetKbps: kbps, levelIndex: max(0, level))
    }

    /// Merge one class's point into whatever was stored, leaving the others
    /// alone: a session on LTE must not erase what the LAN learned.
    static func encode(_ stored: Any?, point: OperatingPoint,
                       for pathClass: PathClass) -> [String: Any] {
        var root = (stored as? [String: Any]) ?? [:]
        root[pathClass.rawValue] = ["kbps": point.targetKbps, "level": point.levelIndex]
        return root
    }
}

// MARK: - The controller

/// Continuous target rate, ranked signals, AIMD, timing discipline, levers.
///
/// Every threshold is a constant on this type so the log line and the tests
/// quote the same number.
struct AdaptiveQualityController {

    // ── Settings ───────────────────────────────────────────────────────────

    static let defaultsKey = "adaptiveQuality"
    static let floorDefaultsKey = "adaptiveFloorKbps"

    /// **800 kbps.** The round-8 floor was 10 Mbps, on a path measured at
    /// 0.1–3.2. A floor is the rate below which the picture is not worth
    /// sending at all, and 800 kbps at 1194×834/30 is soft but usable; the old
    /// one was simply a number the link had never once been able to carry.
    static let defaultFloorKbps = 800

    /// **On by default.** The setting exists to turn it off for a cabled
    /// session where the full bitrate is always available.
    static func resolveEnabled(_ stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    /// Clamped hard: a floor of zero would let the controller ask for nothing,
    /// and a floor above the configured bitrate would make the ceiling
    /// meaningless. 64 kbps–20 Mbps covers every sane answer.
    static func resolveFloorKbps(_ stored: Any?) -> Int {
        guard let number = stored as? NSNumber, number.intValue > 0 else { return defaultFloorKbps }
        return min(max(number.intValue, 64), 20_000)
    }

    static var isEnabled: Bool {
        resolveEnabled(UserDefaults.standard.object(forKey: defaultsKey))
    }

    static var floorKbps: Int {
        resolveFloorKbps(UserDefaults.standard.object(forKey: floorDefaultsKey) as? NSNumber)
    }

    /// How deep the ladder may go this session (`adaptiveMaxLever`).
    ///
    /// A guard rail rather than a switch: capping the lever leaves the
    /// continuous rate control, the ranked signals, the cooldowns and the
    /// frame-rate rungs exactly as they are. Round 9's controller settled at
    /// 3.17 Mbps / 30 fps against an estimate of 2.87 Mbps, which is right; it
    /// was the lever below that which cost the operator the machine.
    static var maxLever: AdaptiveLeverCap {
        AdaptiveLeverCap.resolve(UserDefaults.standard.object(forKey: AdaptiveLeverCap.defaultsKey))
    }

    // ── Control law constants ──────────────────────────────────────────────

    /// Aim here, as a share of the estimate. The 15% that is left over is the
    /// headroom a queue needs in order to drain.
    static let targetShareOfEstimate = 0.85
    /// Multiplicative decrease.
    static let decreaseFactor = 0.7
    /// Additive increase, as a share of the current target.
    static let increaseFactor = 1.10

    /// **No change may follow another inside this window.** A bitrate written
    /// to VideoToolbox takes a frame or two to affect the wire and several
    /// seconds to affect a receiver report; the round-8 controller made three
    /// changes in three seconds and judged each on evidence that predated the
    /// previous one.
    static let cooldownSeconds = 2.5
    /// How long every signal has to stay clean before anything goes up.
    static let increaseAfterCleanSeconds = 15.0
    /// How long a rate that just failed stays off the table.
    static let penaltySeconds = 60.0
    /// Congestion has to persist this long before the first decrease. Short —
    /// a second of a stalled stream is already visible — but not zero, so a
    /// single burst (a window opening, a keyframe) costs nothing.
    static let congestionHoldSeconds = 1.0
    /// An unknown routed path should become interactive before it is asked to
    /// carry the configured desktop bitrate. A fast path probes back up.
    static let tailnetStartupBps = 4_000_000
    static let startupProbeSeconds = cooldownSeconds
    static let startupProbeFactor = 2.0

    // ── State ──────────────────────────────────────────────────────────────

    let plan: AdaptivePlan
    private(set) var pathClass: PathClass
    private var knownTailnetEndpoint: Bool
    private(set) var targetBps: Int
    private(set) var levelIndex: Int
    private(set) var estimator: DeliveredRateEstimator
    private(set) var baseline = DelayBaseline()
    /// Set by the first decision of the session. Until then the starting point
    /// is still the remembered one and a class correction may replace it.
    private(set) var hasDecided = false

    private var lastChangeAt: TimeInterval?
    private var congestedSince: TimeInterval?
    private var cleanSince: TimeInterval?
    private var penaltyCeilingBps: Int?
    private var penaltyUntil: TimeInterval?
    private var stableSince: TimeInterval?
    private var lastSignal: CongestionSignal?
    private var startupProbing = false

    var level: QualityLevel { plan.levels[min(levelIndex, plan.levels.count - 1)] }
    var estimateBps: Int { Int(estimator.estimateBps.rounded()) }

    init(plan: AdaptivePlan, pathClass: PathClass, knownTailnetEndpoint: Bool,
         start: OperatingPoint?,
         now: TimeInterval = 0) {
        self.plan = plan
        self.pathClass = pathClass
        self.knownTailnetEndpoint = knownTailnetEndpoint
        self.estimator = DeliveredRateEstimator()
        let requestedBps = start.map { $0.targetKbps * 1000 } ?? plan.configuredBitrateBps
        self.targetBps = Self.startTarget(requestedBps,
                                          knownTailnetEndpoint: knownTailnetEndpoint, plan: plan)
        self.levelIndex = plan.viableIndex(targetBps: targetBps)
        if let start {
            self.levelIndex = max(min(max(0, start.levelIndex), plan.levels.count - 1),
                                  levelIndex)
            self.estimator.seed(Double(targetBps) / Self.targetShareOfEstimate)
        }
        self.startupProbing = targetBps < plan.configuredBitrateBps
            && (pathClass == .lan || (knownTailnetEndpoint && requestedBps > targetBps))
        self.stableSince = now
        self.cleanSince = now
    }

    /// The starting point as the log should print it.
    var startDescription: String {
        "\(pathClass.label), target \(Self.mbps(targetBps)) Mbps, level \(levelIndex) (\(level.label))"
    }

    // ── The path class can be corrected once ───────────────────────────────

    /// Adopt a refined classification. Only moves the operating point while
    /// nothing has been decided yet — once the controller has acted on
    /// measured evidence, a remembered number from another class is worse
    /// information than what it has.
    ///
    /// Returns true when the operating point actually moved.
    @discardableResult
    mutating func reclassify(as newClass: PathClass, remembered: OperatingPoint?,
                             knownTailnetEndpoint: Bool) -> Bool {
        guard newClass != pathClass else { return false }
        pathClass = newClass
        self.knownTailnetEndpoint = knownTailnetEndpoint
        guard !hasDecided else { return false }
        let remembered = newClass == .lan || knownTailnetEndpoint ? remembered : nil
        let previousTarget = targetBps
        let previousLevel = levelIndex
        if let remembered {
            let requestedBps = remembered.targetKbps * 1000
            targetBps = Self.startTarget(requestedBps,
                                        knownTailnetEndpoint: knownTailnetEndpoint, plan: plan)
            levelIndex = max(min(max(0, remembered.levelIndex), plan.levels.count - 1),
                             plan.viableIndex(targetBps: targetBps))
            startupProbing = targetBps < plan.configuredBitrateBps
                && (newClass == .lan || (knownTailnetEndpoint && requestedBps > targetBps))
        } else if knownTailnetEndpoint {
            // A connection can first look local before its routed endpoint is
            // known. Even without a saved point, correct that optimistic start.
            targetBps = Self.startTarget(targetBps,
                                        knownTailnetEndpoint: true, plan: plan)
            levelIndex = max(levelIndex, plan.viableIndex(targetBps: targetBps))
            startupProbing = startupProbing || previousTarget > targetBps
        } else {
            // RTT alone cannot tell a slow local Wi-Fi hop from a routed one.
            // Do not import another path's operating point or startup cap.
            startupProbing = false
        }
        guard targetBps != previousTarget || levelIndex != previousLevel else { return false }
        estimator = DeliveredRateEstimator()
        if remembered != nil {
            estimator.seed(Double(targetBps) / Self.targetShareOfEstimate)
        }
        return true
    }

    // ── One tick ───────────────────────────────────────────────────────────

    enum Reason: Equatable {
        case congestion(CongestionSignal)
        case sustainedHealth
        /// The target moved a rung because bitrate alone could not carry the
        /// current pixel rate.
        case leverOnly
    }

    /// What the caller has to do, and everything the log line needs.
    struct Change: Equatable {
        let reason: Reason
        let targetBps: Int
        let previousTargetBps: Int
        let level: QualityLevel
        let previousLevel: QualityLevel
        let estimateBps: Int
        let pathClass: PathClass
        /// True when the encoder/capture geometry or rate has to move, i.e.
        /// when this costs more than a property write.
        var changesLever: Bool { level != previousLevel }
        var isDecrease: Bool { targetBps < previousTargetBps || level.index > previousLevel.index }
    }

    /// Feed one tick. Returns a decision only on the tick something actually
    /// changes; the caller logs it and applies it.
    mutating func ingest(_ sample: LinkSample, at now: TimeInterval) -> Change? {
        estimator.ingest(sample)
        if sample.receiverIsFresh { baseline.observe(e2eP50Ms: sample.receiverE2eP50Ms) }

        let verdict = LinkHealth.verdict(sample, baseline: baseline)
        switch verdict {
        case .congested(let signal):
            cleanSince = nil
            lastSignal = signal
            let since = congestedSince ?? now
            congestedSince = since
            guard now - since >= Self.congestionHoldSeconds else { return nil }
            guard canChange(at: now) else { return nil }
            return decrease(on: signal, at: now)
        case .clean:
            congestedSince = nil
            if startupProbing && (sample.framesEncoded == 0 || sample.bytesDelivered == 0) {
                cleanSince = nil
                return nil
            }
            let since = cleanSince ?? now
            cleanSince = since
            // A local socket can accept bytes faster than a remote relay
            // delivers them. Wait for the receiver's first clean report before
            // probing early; without reports, use the normal 15-second hold.
            let cleanHold = startupProbing && sample.receiverIsFresh
                ? Self.startupProbeSeconds : Self.increaseAfterCleanSeconds
            guard now - since >= cleanHold else { return nil }
            guard canChange(at: now) else { return nil }
            return increase(at: now, receiverIsFresh: sample.receiverIsFresh)
        case .neither:
            // Neither clock advances. A link that is merely imperfect holds its
            // operating point, which is what stops the controller walking up
            // and down forever.
            congestedSince = nil
            cleanSince = nil
            return nil
        }
    }

    /// Whether the cooldown has expired. Exposed so the log can print what the
    /// controller was waiting for.
    func cooldownRemaining(at now: TimeInterval) -> TimeInterval {
        guard let lastChangeAt else { return 0 }
        return max(0, Self.cooldownSeconds - (now - lastChangeAt))
    }

    private func canChange(at now: TimeInterval) -> Bool {
        cooldownRemaining(at: now) <= 0
    }

    /// The point, once it has held still long enough to be worth remembering.
    func stableOperatingPoint(at now: TimeInterval) -> OperatingPoint? {
        guard pathClass == .lan || knownTailnetEndpoint else { return nil }
        guard cleanSince != nil,
              let stableSince, now - stableSince >= OperatingPointStore.stableAfterSeconds
        else { return nil }
        return OperatingPoint(targetKbps: max(1, targetBps / 1000), levelIndex: levelIndex)
    }

    // ── Multiplicative decrease ────────────────────────────────────────────

    private mutating func decrease(on signal: CongestionSignal, at now: TimeInterval) -> Change? {
        let previousTarget = targetBps
        let previousLevel = level

        // Two regimes, and which one applies is decided by the evidence.
        //
        // * **We are over budget.** The estimate says the path carries less
        //   than we are asking for, so the answer is simply the estimate's 85%
        //   — one decision from 28.8 Mbps to ~1.3, where the round-8 ladder
        //   needed four steps and still could not go below 10. No extra
        //   multiplicative cut on top: the evidence is not a guess.
        // * **We are inside the estimate and it is congested anyway.** Then the
        //   estimate is optimistic — which is exactly what happens when the
        //   sender's bytes are leaving into a growing queue rather than
        //   arriving — and only a multiplicative cut will find the real limit.
        //
        // Cutting ×0.7 unconditionally would ratchet the target to the floor on
        // a relayed path, because the queue built during the *previous* rate
        // keeps signalling congestion for seconds after the rate is corrected.
        let evidence = estimator.estimateBps > 0
            ? estimator.estimateBps * Self.targetShareOfEstimate
            : nil
        let proposed: Double
        if let evidence, evidence < Double(previousTarget) * 0.95 {
            proposed = evidence
        } else {
            proposed = Double(previousTarget) * Self.decreaseFactor
        }
        var next = Self.clamp(Int(proposed.rounded()), plan: plan)
        if next > previousTarget { next = previousTarget }

        // Deeper lever, when bitrate alone cannot carry the current pixel rate.
        // Never shallower than where we already are — a decrease does not hand
        // anything back — and never deeper than the rate requires.
        let nextLevel = max(levelIndex, plan.viableIndex(targetBps: next))

        // At the floor, at the bottom rung, and still congested: there is
        // nothing left to give. Say nothing rather than log a change that is
        // not one — the cooldown is not consumed and no penalty is recorded,
        // so the moment anything becomes possible again it happens.
        if next == previousTarget, nextLevel == levelIndex { return nil }

        // A rate that just failed is remembered, so the recovery ramp does not
        // walk straight back into it.
        penaltyCeilingBps = previousTarget
        penaltyUntil = now + Self.penaltySeconds

        targetBps = next
        levelIndex = nextLevel
        startupProbing = false
        lastChangeAt = now
        congestedSince = now      // the next decrease needs its own hold
        stableSince = nil
        return Change(reason: .congestion(signal),
                      targetBps: targetBps, previousTargetBps: previousTarget,
                      level: level, previousLevel: previousLevel,
                      estimateBps: estimateBps, pathClass: pathClass)
    }

    // ── Additive increase ──────────────────────────────────────────────────

    private mutating func increase(at now: TimeInterval, receiverIsFresh: Bool) -> Change? {
        let previousTarget = targetBps
        let previousLevel = level

        // The penalty expires on its own clock, not on the next congestion
        // event: a rate that failed a minute ago is worth trying again, and a
        // rate that failed four seconds ago is not.
        if let until = penaltyUntil, now >= until {
            penaltyCeilingBps = nil
            penaltyUntil = nil
        }
        var ceiling = plan.configuredBitrateBps
        if let failed = penaltyCeilingBps {
            // Stay just under whatever failed; 95% of it, so the ramp can still
            // creep up to the edge rather than stopping a full step short.
            ceiling = min(ceiling, Int(Double(failed) * 0.95))
        }
        ceiling = max(ceiling, plan.floorBps)

        let increaseFactor = startupProbing && receiverIsFresh
            ? Self.startupProbeFactor : Self.increaseFactor
        var next = Self.clamp(min(Int((Double(previousTarget) * increaseFactor).rounded()),
                                  ceiling), plan: plan)
        if next < previousTarget { next = previousTarget }

        // Recover the levers in reverse order, slowly: one rung per increase,
        // and only with headroom over what that rung needs.
        var nextLevel = levelIndex
        if levelIndex > 0 {
            let above = plan.levels[levelIndex - 1]
            let required = Double(plan.minimumViableBps(above)) * AdaptivePlan.recoveryHeadroom
            if Double(next) >= required { nextLevel = levelIndex - 1 }
        }

        if next == previousTarget, nextLevel == levelIndex { return nil }

        targetBps = next
        levelIndex = nextLevel
        if targetBps == plan.configuredBitrateBps { startupProbing = false }
        lastChangeAt = now
        cleanSince = now          // one change per clean window
        stableSince = nil
        return Change(reason: nextLevel != previousLevel.index ? .leverOnly : .sustainedHealth,
                      targetBps: targetBps, previousTargetBps: previousTarget,
                      level: level, previousLevel: previousLevel,
                      estimateBps: estimateBps, pathClass: pathClass)
    }

    /// Mark the current point stable from `now` — called after applying a
    /// change, so the "has it held still?" clock starts when the change lands.
    mutating func noteApplied(at now: TimeInterval) {
        hasDecided = true
        stableSince = now
    }

    /// Back to the configured point, for a genuinely new pipeline (a rotation,
    /// a transport migration) — but **not** for the capture rebuild this
    /// controller asks for itself.
    mutating func resetForNewCapture(at now: TimeInterval) {
        targetBps = Self.startTarget(plan.configuredBitrateBps,
                                    knownTailnetEndpoint: knownTailnetEndpoint, plan: plan)
        levelIndex = plan.viableIndex(targetBps: targetBps)
        startupProbing = knownTailnetEndpoint && targetBps < plan.configuredBitrateBps
        estimator = DeliveredRateEstimator()
        baseline.reset()
        lastChangeAt = nil
        congestedSince = nil
        cleanSince = now
        penaltyCeilingBps = nil
        penaltyUntil = nil
        stableSince = now
        hasDecided = false
    }

    // ── Helpers ────────────────────────────────────────────────────────────

    private static func clamp(_ bps: Int, plan: AdaptivePlan) -> Int {
        min(max(bps, plan.floorBps), plan.configuredBitrateBps)
    }

    private static func startTarget(_ bps: Int, knownTailnetEndpoint: Bool,
                                    plan: AdaptivePlan) -> Int {
        let limit = knownTailnetEndpoint ? tailnetStartupBps : plan.configuredBitrateBps
        return clamp(min(bps, limit), plan: plan)
    }

    static func mbps(_ bps: Int) -> String {
        String(format: "%.2f", Double(bps) / 1_000_000)
    }

    // ── Reporting ──────────────────────────────────────────────────────────

    /// One line per decision: the estimate, the target, which signal fired,
    /// the level, and the cooldown state.
    func decisionLine(_ change: Change, sample: LinkSample, at now: TimeInterval) -> String {
        let what: String
        switch change.reason {
        case .congestion(let signal):
            what = "decrease ×\(String(format: "%.2f", Self.decreaseFactor)) on \(signal.label)"
        case .sustainedHealth:
            let factor = change.previousTargetBps > 0
                ? Double(change.targetBps) / Double(change.previousTargetBps) : 1
            what = "increase +\(Int(((factor - 1) * 100).rounded()))% on sustained health"
        case .leverOnly:
            what = change.isDecrease
                ? "lever down on \(lastSignal?.label ?? "congestion")"
                : "lever up on sustained health"
        }
        let size = plan.encodedSize(change.level)
        let receiver = sample.receiverIsFresh
            ? String(format: "e2e50=%.0fms e2e95=%.0fms base=%.0fms stalls=%d rtt=%.0fms",
                     sample.receiverE2eP50Ms, sample.receiverE2eP95Ms,
                     baseline.baselineMs, sample.receiverStalls, sample.receiverRttMs)
            : String(format: "no fresh receiver report (%.0fs old)", sample.receiverAgeSeconds)
        return "adaptive: target \(Self.mbps(change.targetBps)) Mbps "
            + "(was \(Self.mbps(change.previousTargetBps))) — \(what) | "
            + "estimate \(Self.mbps(change.estimateBps)) Mbps | "
            + "level \(change.level.index)/\(plan.levels.count - 1) "
            + "(\(plan.frameRate(change.level)) fps, \(change.level.scale.rawValue) "
            + "\(size.wide)x\(size.high)) | "
            + "queue \(sample.sendQueueDepth)/\(sample.maxSendQueueDepth) "
            + String(format: "write95=%.0fms", sample.writeCompletionP95Ms)
            + " evicted=\(sample.evictedFrames) | \(receiver) | "
            + String(format: "cooldown %.1fs", Self.cooldownSeconds)
            + " | path \(pathClass.label)"
    }

    /// The periodic panel line: where the controller currently stands.
    func panelLine(sample: LinkSample, at now: TimeInterval) -> String {
        let size = plan.encodedSize(level)
        let freshness = sample.receiverIsFresh
            ? "fresh"
            : String(format: "%.0fs old", sample.receiverAgeSeconds)
        return "adaptive panel: target \(Self.mbps(targetBps)) Mbps / "
            + "\(plan.frameRate(level)) fps / \(level.scale.rawValue) "
            + "\(size.wide)x\(size.high), "
            + "estimate \(Self.mbps(estimateBps)) Mbps, path \(pathClass.label) "
            + "(level \(levelIndex)/\(plan.levels.count - 1), "
            + "queue \(sample.sendQueueDepth)/\(sample.maxSendQueueDepth), "
            + String(format: "baseline %.0fms", baseline.baselineMs)
            + ", stats \(freshness)"
            + String(format: ", cooldown %.1fs)", cooldownRemaining(at: now))
    }
}
