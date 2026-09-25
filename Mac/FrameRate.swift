import Foundation

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size — only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    var bitrate: Int {
        switch self {
        case .best: return 18_000_000
        case .balanced: return 10_000_000
        case .fast: return 6_000_000
        }
    }

    var label: String {
        switch self {
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Pixel-perfect at the device's native resolution. Highest bandwidth and latency."
        case .balanced: return "75% capture resolution — noticeably lower latency, slight softness."
        case .fast: return "Half resolution — lowest latency and bandwidth, visibly softer. Good for WiFi."
        }
    }
}

/// User-selectable target frame rate for the capture stream and virtual display.
/// Supports high-refresh ProMotion displays (120 Hz) on iPad Pro and iPhone Pro.
///
/// **Fork default: 120.** This branch exists to drive one panel — an 11" iPad
/// Pro M1, which is ProMotion — and 60 on a 120 Hz panel is exactly the thing
/// the operator asked to fix. Upstream keeps 60 because it ships to every
/// device; here the device is known.
enum FrameRate: Int, CaseIterable, Identifiable {
    case fps30 = 30
    case fps60 = 60
    case fps90 = 90
    case fps120 = 120

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fps30: return "30 FPS (Low Power)"
        case .fps60: return "60 FPS (Default)"
        case .fps90: return "90 FPS"
        case .fps120: return "120 FPS (ProMotion)"
        }
    }

    var explanation: String {
        switch self {
        case .fps30: return "Lowest CPU and power usage. Best for static content or saving battery."
        case .fps60: return "Standard smooth frame rate for general use."
        case .fps90: return "High refresh rate with balanced CPU and bandwidth overhead."
        case .fps120: return "Ultra-smooth ProMotion 120 Hz for compatible iPad Pro and iPhone Pro displays."
        }
    }

    // MARK: - The setting

    static let defaultsKey = "frameRate"
    /// What this fork uses when nothing is stored.
    static let forkDefault = FrameRate.fps120

    /// `UserDefaults.integer(forKey:)` answers 0 for an absent key, and a
    /// stored value that names no case (someone writing 144) is treated the
    /// same way: fall back rather than refuse to stream.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> FrameRate {
        resolve(defaults.object(forKey: defaultsKey))
    }

    static func resolve(_ stored: Any?) -> FrameRate {
        guard let raw = stored as? Int, let rate = FrameRate(rawValue: raw) else {
            return forkDefault
        }
        return rate
    }

    /// Auto-scaled bitrate to ensure picture clarity is preserved at higher frame rates.
    /// Boosts up to ~28.8 Mbps at 120 FPS for Best quality.
    ///
    /// Note what this curve does and does not claim. At Best, 60 fps gets
    /// 18 Mbps over a 2388x1668 frame — about 0.075 bits per pixel per frame;
    /// 120 fps gets 28.8 Mbps, i.e. about 0.060. The per-frame budget *drops*,
    /// and that is deliberate rather than an oversight: at twice the frame rate
    /// there is half as much motion between consecutive frames, so inter-frame
    /// prediction is cheaper per frame and equal perceived quality costs
    /// roughly 1.3–1.7x, not 2x. 1.6 sits inside that range.
    ///
    /// The practical consequence is worth stating in the settings UI and in the
    /// report: **120 fps at Best quality is a cable (or strong 5 GHz)
    /// setting.** 28.8 Mbps is comfortable over usbmuxd and marginal over a
    /// tailnet hop; the Balanced and Fast presets exist for that case, and the
    /// sender's `enc↓`/`net↓` counters in the log say which one is biting.
    func bitrate(for quality: StreamQuality) -> Int {
        let base = quality.bitrate
        switch self {
        case .fps30:
            return Int(Double(base) * 0.75)
        case .fps60:
            return base
        case .fps90:
            return Int(Double(base) * 1.25)
        case .fps120:
            return Int(Double(base) * 1.6)
        }
    }
}

// MARK: - H.264 level ceiling

/// What the H.264 level actually permits, as a rate ceiling.
///
/// A frame rate the encoder accepts is not automatically one a decoder will
/// take: High profile at level 5.2 — what this build asks VideoToolbox for
/// (`kVTProfileLevel_H264_High_AutoLevel`) tops out at — permits 2,073,600
/// macroblocks per second, and above that a hardware decoder is entitled to
/// refuse the stream. Upstream PR #275 discovered the same ceiling from the
/// other end (a 5K receiver at 60 fps); this is the same arithmetic, generalised
/// so it can clamp 120 instead of being hardcoded to 60.
///
/// Numbers for the panels this fork cares about, at Best quality (native):
///
/// | Panel | Encoded | MB/frame | Level ceiling |
/// |---|---|---|---|
/// | iPad Pro 11" M1 | 2388x1668 | 15,750 | **131 fps** — 120 fits |
/// | iPad Pro 12.9" M1 | 2732x2048 | 21,888 | 94 fps — 120 clamps to 94 |
/// | iPad Pro 13" M4 | 2752x2064 | 22,188 | 93 fps |
/// | iPad Air 11" | 2360x1640 | 15,244 | 136 fps |
///
/// So on the target device 120 is reachable at every quality preset, and on a
/// larger panel the stream is clamped **loudly** rather than being offered a
/// rate its decoder may reject.
enum H264Level {

    /// High@L5.2, macroblocks per second.
    static let maxMacroblocksPerSecond = 2_073_600

    static func macroblocks(width: Int, height: Int) -> Int {
        max(1, ((max(width, 1) + 15) / 16) * ((max(height, 1) + 15) / 16))
    }

    /// The highest frame rate this encoded size stays inside the level at.
    static func maxFrameRate(width: Int, height: Int) -> Int {
        max(1, maxMacroblocksPerSecond / macroblocks(width: width, height: height))
    }

    /// The rate to actually encode at: the user's choice, clamped by the level.
    ///
    /// Never rounded up — a request below the ceiling is honoured exactly, so
    /// the common case is byte-for-byte the requested setting.
    static func effectiveFrameRate(requested: Int, width: Int, height: Int) -> Int {
        min(max(requested, 1), maxFrameRate(width: width, height: height))
    }
}

// MARK: - Where the chosen rate actually lands

/// The three places the chosen frame rate has to reach, as pure arithmetic.
///
/// This exists because #275 and #276 are both bugs about one of the three
/// drifting away from the others: the ScreenCaptureKit rate limiter, the
/// VideoToolbox encoder and the `CGVirtualDisplayMode` the panel runs at must
/// agree, and `resize()` silently dropping back to 60 on the first rotation is
/// exactly the shape of failure this prevents. Keeping the arithmetic here —
/// with no capture session, no encoder and no display attached to it — is also
/// the only way `MacTests` can check any of it: `MacSender` is `@MainActor`,
/// owns ScreenCaptureKit, and `VirtualDisplay` drives a private API that would
/// attach a real monitor to the tester's Mac.
enum StreamTiming {

    /// Timescale for `SCStreamConfiguration.minimumFrameInterval` with a
    /// numerator of 1, i.e. the interval is `1/result` seconds.
    ///
    /// Double the target rate, never below 120: SCK's rate limiter drops a
    /// frame that arrives a hair early rather than delaying it, so asking for
    /// exactly 1/N beats against the compositor and measures ~0.85N (60
    /// requested, ~51 delivered). Asking for twice the rate costs nothing —
    /// the display does not produce frames that are not there — and lets every
    /// frame through.
    static func captureIntervalTimescale(fps: Int) -> Int {
        max(120, max(fps, 1) * 2)
    }

    /// Everything the encoder is configured with that depends on the rate.
    /// Built from the **level-clamped** rate, from the same numbers
    /// `startCapture` limits ScreenCaptureKit to, so the encoder can never be
    /// asked for frames capture was told not to deliver (or the reverse).
    struct EncoderTiming: Equatable {
        /// `kVTCompressionPropertyKey_ExpectedFrameRate`.
        let expectedFrameRate: Int
        /// `kVTCompressionPropertyKey_MaxKeyFrameInterval` — one IDR per
        /// minute's worth of frames. There are no periodic keyframes in this
        /// pipeline by design (each one is a bitrate spike, TCP never loses
        /// data, and a keyframe is forced on reconnect); this is the ceiling
        /// that stops VideoToolbox inserting its own.
        let maxKeyFrameInterval: Int
        /// `kVTCompressionPropertyKey_AverageBitRate`. Follows the *requested*
        /// rate, not the clamped one: the clamp is a decoder-conformance
        /// ceiling, and spending the full budget on fewer frames is the right
        /// trade when it bites.
        let bitrate: Int
    }

    static func encoder(rate: FrameRate, quality: StreamQuality,
                        width: Int, height: Int) -> EncoderTiming {
        let fps = H264Level.effectiveFrameRate(requested: rate.rawValue,
                                               width: width, height: height)
        return EncoderTiming(expectedFrameRate: fps,
                             maxKeyFrameInterval: fps * 60,
                             bitrate: rate.bitrate(for: quality))
    }

    /// The `CGVirtualDisplayMode` to publish. **Both** the initial
    /// `applySettings` and `resize()` — the rotation path — build their mode
    /// from this, which is the point: a rotation that rebuilt the mode at a
    /// hardcoded 60 would drop a 120 Hz session to 60 the first time the iPad
    /// turned, and nothing in the picture would say so.
    ///
    /// Not clamped by `H264Level`: this is the rate macOS *composites* the
    /// virtual panel at, and the level ceiling is about what a hardware
    /// decoder will accept. A display running faster than the stream is
    /// harmless — capture and the encoder do the limiting.
    struct DisplayMode: Equatable {
        let pointsWide: Int
        let pointsHigh: Int
        let refreshRate: Double
    }

    static func displayMode(pointsWide: Int, pointsHigh: Int, targetFPS: Double) -> DisplayMode {
        // A zero or negative rate would let WindowServer pick, which is how a
        // 120 Hz session quietly becomes whatever the saved arrangement said.
        let rate = targetFPS.isFinite && targetFPS > 0
            ? targetFPS
            : Double(FrameRate.forkDefault.rawValue)
        return DisplayMode(pointsWide: max(pointsWide, 1),
                           pointsHigh: max(pointsHigh, 1),
                           refreshRate: rate)
    }
}
