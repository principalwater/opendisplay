import XCTest

final class FrameRateTests: XCTestCase {

    func testRawValuesAndCases() {
        XCTAssertEqual(FrameRate.allCases.count, 4)
        XCTAssertEqual(FrameRate.fps30.rawValue, 30)
        XCTAssertEqual(FrameRate.fps60.rawValue, 60)
        XCTAssertEqual(FrameRate.fps90.rawValue, 90)
        XCTAssertEqual(FrameRate.fps120.rawValue, 120)
    }

    func testLabelsContainProMotion() {
        XCTAssertTrue(FrameRate.fps120.label.contains("ProMotion"))
        XCTAssertTrue(FrameRate.fps60.label.contains("Default"))
        XCTAssertTrue(FrameRate.fps30.label.contains("Low Power"))
    }

    func testBitrateScaling() {
        let bestBase = StreamQuality.best.bitrate // 18_000_000
        let balancedBase = StreamQuality.balanced.bitrate // 10_000_000
        let fastBase = StreamQuality.fast.bitrate // 6_000_000

        // 60 FPS should preserve base bitrate
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .best), bestBase)
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .balanced), balancedBase)
        XCTAssertEqual(FrameRate.fps60.bitrate(for: .fast), fastBase)

        // 120 FPS should boost bitrate by 1.6x (28.8 Mbps for best)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .best), 28_800_000)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .balanced), 16_000_000)
        XCTAssertEqual(FrameRate.fps120.bitrate(for: .fast), 9_600_000)

        // 90 FPS should scale by 1.25x
        XCTAssertEqual(FrameRate.fps90.bitrate(for: .best), Int(Double(bestBase) * 1.25))

        // 30 FPS should scale down to 0.75x to conserve bandwidth
        XCTAssertEqual(FrameRate.fps30.bitrate(for: .best), Int(Double(bestBase) * 0.75))
    }

    func testInitFromRawValueFallback() {
        XCTAssertEqual(FrameRate(rawValue: 120), .fps120)
        XCTAssertEqual(FrameRate(rawValue: 60), .fps60)
        XCTAssertNil(FrameRate(rawValue: 144))
    }
}

/// The fork's additions to #276: the default, and the H.264 level ceiling that
/// decides whether the requested rate is actually reachable.
final class FrameRatePolicyTests: XCTestCase {

    // MARK: - The fork default

    func testTheDefaultIs120() {
        // This fork drives one panel — an 11" iPad Pro M1, i.e. ProMotion — and
        // 60 on a 120 Hz panel is the thing it was asked to fix.
        XCTAssertEqual(FrameRate.forkDefault, .fps120)
        XCTAssertEqual(FrameRate.resolve(nil), .fps120)
    }

    func testAStoredRateIsHonoured() {
        XCTAssertEqual(FrameRate.resolve(30), .fps30)
        XCTAssertEqual(FrameRate.resolve(60), .fps60)
        XCTAssertEqual(FrameRate.resolve(90), .fps90)
        XCTAssertEqual(FrameRate.resolve(120), .fps120)
    }

    func testAnAbsentKeyReadsAsZeroAndFallsBack() {
        // `UserDefaults.integer(forKey:)` answers 0 for a key that was never
        // written, which names no case.
        XCTAssertEqual(FrameRate.resolve(0), .fps120)
    }

    func testAnUnusableStoredValueFallsBackRatherThanRefusing() {
        XCTAssertEqual(FrameRate.resolve(144), .fps120)
        XCTAssertEqual(FrameRate.resolve(-1), .fps120)
        XCTAssertEqual(FrameRate.resolve("120"), .fps120)
    }

    // MARK: - The H.264 level ceiling

    func test120FitsOnTheIPadPro11ThisForkTargets() {
        // 2388x1668 is 150x105 macroblocks = 15,750; L5.2's 2,073,600/s gives
        // 131 fps. If this ever fails, 120 has stopped being reachable at Best
        // quality on the target device and the picker is lying.
        let ceiling = H264Level.maxFrameRate(width: 2388, height: 1668)
        XCTAssertGreaterThanOrEqual(ceiling, 120)
        XCTAssertEqual(H264Level.effectiveFrameRate(requested: 120, width: 2388, height: 1668), 120)
    }

    func testABiggerPanelClampsInsteadOfOfferingARateItsDecoderMayRefuse() {
        // 12.9" iPad Pro: 2732x2048 = 171x128 macroblocks = 21,888, so ~94 fps.
        let effective = H264Level.effectiveFrameRate(requested: 120, width: 2732, height: 2048)
        XCTAssertLessThan(effective, 120)
        XCTAssertGreaterThan(effective, 60, "60 must still be reachable there")
    }

    func testARequestBelowTheCeilingIsHonouredExactly() {
        // The common case has to be byte-for-byte the requested setting — no
        // rounding, no "helpful" adjustment.
        for rate in FrameRate.allCases {
            XCTAssertEqual(
                H264Level.effectiveFrameRate(requested: rate.rawValue, width: 1280, height: 720),
                rate.rawValue)
        }
    }

    func testLoweringTheQualityPresetRaisesTheCeiling() {
        // Fast quality halves the encoded size, so it quarters the macroblock
        // count — which is the escape hatch when a panel cannot take 120 at
        // native resolution.
        let native = H264Level.maxFrameRate(width: 2732, height: 2048)
        let half = H264Level.maxFrameRate(width: 1366, height: 1024)
        XCTAssertGreaterThan(half, native)
        XCTAssertGreaterThanOrEqual(half, 120)
    }

    func testMacroblockCountRoundsUpToWholeBlocks() {
        // A 1-pixel-wider frame still costs a whole extra column of blocks.
        XCTAssertEqual(H264Level.macroblocks(width: 16, height: 16), 1)
        XCTAssertEqual(H264Level.macroblocks(width: 17, height: 16), 2)
        XCTAssertEqual(H264Level.macroblocks(width: 2388, height: 1668), 150 * 105)
    }

    func testDegenerateSizesCannotDivideByZeroOrGoNegative() {
        // Encoded size is 0 until capture announces one.
        XCTAssertGreaterThan(H264Level.maxFrameRate(width: 0, height: 0), 0)
        XCTAssertEqual(H264Level.effectiveFrameRate(requested: 0, width: 0, height: 0), 1)
    }

    // MARK: - Bitrate

    func testTheBitrateCurveIsMonotonic() {
        for quality in StreamQuality.allCases {
            let rates = FrameRate.allCases.sorted { $0.rawValue < $1.rawValue }
            let bitrates = rates.map { $0.bitrate(for: quality) }
            XCTAssertEqual(bitrates, bitrates.sorted(), "\(quality) must not cost less at a higher rate")
        }
    }

    func testPerFrameBudgetShrinksAtHigherRates() {
        // Documented, deliberate, and worth pinning so nobody "fixes" it into
        // a 2x curve by accident: at twice the frame rate there is half as much
        // motion between frames, so equal quality costs ~1.3-1.7x, not 2x.
        let sixty = Double(FrameRate.fps60.bitrate(for: .best)) / 60
        let oneTwenty = Double(FrameRate.fps120.bitrate(for: .best)) / 120
        XCTAssertLessThan(oneTwenty, sixty)
        XCTAssertGreaterThan(oneTwenty / sixty, 0.7, "but not a collapse either")
    }
}

// MARK: - The setting, read the way the app reads it

/// `FrameRate.fromDefaults` against a real `UserDefaults`, because the app
/// reads it from one: `resolve` alone cannot catch a typo in the key name or a
/// value that survives the round trip as the wrong type.
final class FrameRateDefaultsTests: XCTestCase {

    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "alfheim.framerate.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil
        super.tearDown()
    }

    func testAnEmptyDomainGivesTheForkDefault() {
        XCTAssertNil(suite.object(forKey: FrameRate.defaultsKey))
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps120)
    }

    func testAStoredValueBeatsTheForkDefault() {
        for rate in FrameRate.allCases {
            suite.set(rate.rawValue, forKey: FrameRate.defaultsKey)
            XCTAssertEqual(FrameRate.fromDefaults(suite), rate)
        }
    }

    func testTheKeyIsTheOneTheSettingsPanelWrites() {
        // The picker's `didSet` writes `UserDefaults.standard` under this name,
        // and the README/report tell the operator to `defaults write` it.
        XCTAssertEqual(FrameRate.defaultsKey, "frameRate")
        suite.set(30, forKey: "frameRate")
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps30)
    }

    func testDeletingTheKeyReturnsToTheForkDefault() {
        // `defaults delete` has to put the build back at its documented
        // default — that is why the default is "absent means 120" rather than
        // a value written at first launch.
        suite.set(30, forKey: FrameRate.defaultsKey)
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps30)
        suite.removeObject(forKey: FrameRate.defaultsKey)
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps120)
    }

    func testAGarbageValueDoesNotRefuseToStream() {
        for junk in [144, 0, -60] {
            suite.set(junk, forKey: FrameRate.defaultsKey)
            XCTAssertEqual(FrameRate.fromDefaults(suite), .fps120, "\(junk)")
        }
        suite.set("120", forKey: FrameRate.defaultsKey)
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps120)
        suite.set(true, forKey: FrameRate.defaultsKey)
        XCTAssertEqual(FrameRate.fromDefaults(suite), .fps120)
    }
}

// MARK: - Where the rate lands

/// The capture limiter, the encoder and the virtual display mode, as the pure
/// arithmetic they are reduced to in `StreamTiming`. Each of the three is a
/// place a hardcoded 60 used to live.
final class StreamTimingTests: XCTestCase {

    // MARK: SCStreamConfiguration.minimumFrameInterval

    func testCaptureAsksForDoubleTheRate() {
        // 1/(2N), not 1/N: SCK's rate limiter drops a frame that arrives a
        // hair early instead of delaying it, which measured ~51fps at 60.
        XCTAssertEqual(StreamTiming.captureIntervalTimescale(fps: 60), 120)
        XCTAssertEqual(StreamTiming.captureIntervalTimescale(fps: 90), 180)
        XCTAssertEqual(StreamTiming.captureIntervalTimescale(fps: 120), 240)
    }

    func testCaptureNeverAsksForLessThan120() {
        // At 30 the floor bites: 60 would still beat against the compositor.
        XCTAssertEqual(StreamTiming.captureIntervalTimescale(fps: 30), 120)
        XCTAssertEqual(StreamTiming.captureIntervalTimescale(fps: 1), 120)
    }

    func testCaptureIntervalCannotBeZeroOrNegative() {
        // A CMTime with timescale 0 is invalid and SCK would reject the whole
        // configuration — the display stops, not just the rate limiter.
        for fps in [0, -1, Int.min + 1] {
            XCTAssertGreaterThanOrEqual(StreamTiming.captureIntervalTimescale(fps: fps), 120)
        }
    }

    func testEveryPickerRateIsRepresentable() {
        for rate in FrameRate.allCases {
            let timescale = StreamTiming.captureIntervalTimescale(fps: rate.rawValue)
            XCTAssertEqual(timescale, max(120, rate.rawValue * 2))
            XCTAssertLessThan(timescale, Int(Int32.max))
        }
    }

    // MARK: The encoder

    func testExpectedFrameRateIsTheRateCaptureWasLimitedTo() {
        // Both numbers come from `H264Level.effectiveFrameRate` over the same
        // encoded size. If they ever disagree, SCK delivers frames the encoder
        // is over budget for.
        let size = (w: 2388, h: 1668)
        for rate in FrameRate.allCases {
            let timing = StreamTiming.encoder(rate: rate, quality: .best, width: size.w, height: size.h)
            XCTAssertEqual(timing.expectedFrameRate,
                           H264Level.effectiveFrameRate(requested: rate.rawValue,
                                                        width: size.w, height: size.h))
        }
    }

    func testTheTargetPanelEncodesAtTheFullRequestedRate() {
        let timing = StreamTiming.encoder(rate: .fps120, quality: .best, width: 2388, height: 1668)
        XCTAssertEqual(timing.expectedFrameRate, 120)
        XCTAssertEqual(timing.bitrate, 28_800_000)
    }

    func testMaxKeyFrameIntervalIsAMinutesWorthOfFrames() {
        // No periodic IDRs by design: this is the ceiling that stops
        // VideoToolbox inserting its own, and it has to follow the rate or a
        // 120fps stream gets a keyframe spike every 30 seconds.
        XCTAssertEqual(StreamTiming.encoder(rate: .fps30, quality: .best, width: 1280, height: 720)
                        .maxKeyFrameInterval, 30 * 60)
        XCTAssertEqual(StreamTiming.encoder(rate: .fps120, quality: .best, width: 1280, height: 720)
                        .maxKeyFrameInterval, 120 * 60)
    }

    func testTheClampMovesTheKeyFrameIntervalWithIt() {
        // 12.9": 120 is over the level ceiling, so both encoder numbers must
        // describe the rate that is actually encoded.
        let timing = StreamTiming.encoder(rate: .fps120, quality: .best, width: 2732, height: 2048)
        XCTAssertLessThan(timing.expectedFrameRate, 120)
        XCTAssertEqual(timing.maxKeyFrameInterval, timing.expectedFrameRate * 60)
    }

    func testTheBitrateFollowsTheRequestedRateNotTheClamp() {
        // Deliberate: the clamp is a decoder-conformance ceiling, and spending
        // the whole budget on fewer frames is the right trade when it bites.
        let clamped = StreamTiming.encoder(rate: .fps120, quality: .best, width: 2732, height: 2048)
        XCTAssertEqual(clamped.bitrate, FrameRate.fps120.bitrate(for: .best))
        for quality in StreamQuality.allCases {
            XCTAssertEqual(StreamTiming.encoder(rate: .fps90, quality: quality,
                                                width: 1280, height: 720).bitrate,
                           FrameRate.fps90.bitrate(for: quality))
        }
    }

    func testEncoderTimingSurvivesAnUnannouncedSize() {
        // Encoded size is 0 until capture reports one.
        let timing = StreamTiming.encoder(rate: .fps120, quality: .best, width: 0, height: 0)
        XCTAssertGreaterThan(timing.expectedFrameRate, 0)
        XCTAssertEqual(timing.maxKeyFrameInterval, timing.expectedFrameRate * 60)
    }

    // MARK: The CGVirtualDisplayMode

    func testTheDisplayModeRunsAtTheChosenRate() {
        for rate in FrameRate.allCases {
            let mode = StreamTiming.displayMode(pointsWide: 1194, pointsHigh: 834,
                                                targetFPS: Double(rate.rawValue))
            XCTAssertEqual(mode.refreshRate, Double(rate.rawValue))
            XCTAssertEqual(mode.pointsWide, 1194)
            XCTAssertEqual(mode.pointsHigh, 834)
        }
    }

    func testRotationRebuildsTheModeAtTheSameRate() {
        // `resize()` is the rotation path, and it builds its mode from this
        // same function: a 120 Hz session must not drop to 60 the first time
        // the iPad turns. Landscape and portrait, one rate.
        let landscape = StreamTiming.displayMode(pointsWide: 1194, pointsHigh: 834, targetFPS: 120)
        let portrait = StreamTiming.displayMode(pointsWide: 834, pointsHigh: 1194, targetFPS: 120)
        XCTAssertEqual(landscape.refreshRate, portrait.refreshRate)
        XCTAssertEqual(portrait.pointsWide, 834)
        XCTAssertEqual(portrait.pointsHigh, 1194)
    }

    func testTheDisplayModeIsNotClampedByTheEncodersLevelCeiling() {
        // The panel is composited by WindowServer; the level ceiling is about
        // what a hardware *decoder* accepts. A display running faster than the
        // stream is harmless — capture and the encoder do the limiting.
        let mode = StreamTiming.displayMode(pointsWide: 1366, pointsHigh: 1024, targetFPS: 120)
        XCTAssertEqual(mode.refreshRate, 120)
    }

    func testADegenerateRateFallsBackInsteadOfLettingWindowServerChoose() {
        for bad in [0.0, -60.0, Double.nan, Double.infinity] {
            XCTAssertEqual(StreamTiming.displayMode(pointsWide: 100, pointsHigh: 100,
                                                    targetFPS: bad).refreshRate,
                           Double(FrameRate.forkDefault.rawValue), "\(bad)")
        }
    }

    func testADegenerateSizeStaysAValidMode() {
        let mode = StreamTiming.displayMode(pointsWide: 0, pointsHigh: -10, targetFPS: 60)
        XCTAssertGreaterThan(mode.pointsWide, 0)
        XCTAssertGreaterThan(mode.pointsHigh, 0)
    }
}
