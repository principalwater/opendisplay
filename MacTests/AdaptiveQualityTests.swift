import XCTest

/// The congestion controller.
///
/// Round 8's ladder is gone and every number here comes from the session that
/// killed it — the operator's 2026-09-18 15:29–15:33 LTE/Tailscale-relay run,
/// in which the controller's *lowest* rung (10 Mbps) was three times what the
/// path delivered (0.1–3.2 Mbps), it made ten level changes in two minutes,
/// three of them one second apart, and several of them on evidence that did
/// not exist (`e2e95=0ms rtt=0ms`).
///
/// Everything that can go wrong with a controller like this is a policy or a
/// timing property, and every one of them is checkable here without a network.
final class AdaptiveQualityTests: XCTestCase {

    // MARK: - Fixtures

    /// The operator's actual configuration: an 11" iPad Pro at Best, 120 fps.
    private func plan(bitrate: Int = 28_800_000, fps: Int = 120,
                      scale: StreamQuality = .best,
                      floorKbps: Int = AdaptiveQualityController.defaultFloorKbps) -> AdaptivePlan {
        AdaptivePlan(configuredBitrateBps: bitrate, configuredFps: fps, configuredScale: scale,
                     baseWide: 2388, baseHigh: 1668, floorBps: floorKbps * 1000)
    }

    private func controller(_ plan: AdaptivePlan? = nil,
                            pathClass: PathClass = .lan,
                            knownTailnetEndpoint: Bool = false,
                            start: OperatingPoint? = nil) -> AdaptiveQualityController {
        AdaptiveQualityController(plan: plan ?? self.plan(), pathClass: pathClass,
                                  knownTailnetEndpoint: knownTailnetEndpoint,
                                  start: start, now: 0)
    }

    /// A tick the sender itself can see is bad: the queue is full and frames
    /// are being evicted.
    private func congested(bytes: Int = 90_000) -> LinkSample {
        LinkSample(sendQueueDepth: 3, maxSendQueueDepth: 3, oldestWriteAgeMs: 400,
                   writeCompletionP95Ms: 380, evictedFrames: 2, framesEncoded: 20,
                   bytesDelivered: bytes)
    }

    /// Nothing waiting, nothing late.
    private func clean(bytes: Int = 200_000) -> LinkSample {
        LinkSample(sendQueueDepth: 0, maxSendQueueDepth: 3, framesEncoded: 60,
                   bytesDelivered: bytes)
    }

    /// One frame waiting and a write in progress: not clean, not congested.
    private func neither() -> LinkSample {
        LinkSample(sendQueueDepth: 2, maxSendQueueDepth: 3, oldestWriteAgeMs: 40,
                   framesEncoded: 60, bytesDelivered: 120_000)
    }

    /// Drive `controller` through `seconds` of one sample, at 0.5 s ticks,
    /// collecting every change.
    @discardableResult
    private func run(_ controller: inout AdaptiveQualityController,
                     _ sample: LinkSample, seconds: Double, from start: Double = 0,
                     applying: Bool = true) -> [AdaptiveQualityController.Change] {
        var out: [AdaptiveQualityController.Change] = []
        var t = start
        while t < start + seconds {
            t += 0.5
            if let change = controller.ingest(sample, at: t) {
                out.append(change)
                if applying { controller.noteApplied(at: t) }
            }
        }
        return out
    }

    // MARK: - Path class

    func testADirectCableIsAlwaysLanWhateverTheRoundTripSays() {
        XCTAssertEqual(PathClass.classify(directLink: true, wired: true,
                                          tailnet: false, rttMs: 900), .lan)
    }

    func testATailnetDialWithNoMeasurementYetUsesTheLowRttBucket() {
        // The first receiver report can move the session to the other
        // latency bucket without assuming how Tailscale routed it.
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: true, rttMs: nil), .tailnetLowRTT)
    }

    func testATailnetAddressIsNeverLanHoweverWiredItsInterfaceLooks() {
        // The bug this ordering exists for. The operator's relayed session logs
        // `connection path to …: utun4 wired=true direct=false` — Tailscale's
        // own tunnel is not WiFi, not loopback and not cellular, so the
        // sender's long-standing "is this wired?" test says yes. Classifying
        // interface-first would hand an LTE/DERP session the LAN's 28.8 Mbps.
        XCTAssertEqual(PathClass.classify(directLink: false, wired: true,
                                          tailnet: true, rttMs: 114), .tailnetHighRTT)
        XCTAssertEqual(PathClass.classify(directLink: false, wired: true,
                                          tailnet: true, rttMs: nil), .tailnetLowRTT)
    }

    func testANonTailnetDialWithNoMeasurementIsLan() {
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: false, rttMs: nil), .lan)
    }

    func testTheOperatorsMeasuredRoundTripUsesTheHighRttBucket() {
        // 114 and 156 ms are the two `rtt` values in the 15:29–15:33 window.
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: true, rttMs: 114), .tailnetHighRTT)
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: true, rttMs: 156), .tailnetHighRTT)
    }

    func testAFastTailnetHopUsesTheLowRttBucket() {
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: true, rttMs: 38), .tailnetLowRTT)
    }

    func testAMillisecondRoundTripOnTheLocalWireIsLan() {
        XCTAssertEqual(PathClass.classify(directLink: false, wired: false,
                                          tailnet: false, rttMs: 3), .lan)
    }

    func testTheClassesHaveStableNamesForTheLogAndForTheStore() {
        XCTAssertEqual(PathClass.lan.label, "lan")
        XCTAssertEqual(PathClass.tailnetLowRTT.label, "tailnet-low-rtt")
        XCTAssertEqual(PathClass.tailnetHighRTT.label, "tailnet-high-rtt")
        XCTAssertEqual(PathClass.tailnetLowRTT.rawValue, "tailnetDirect")
        XCTAssertEqual(PathClass.tailnetHighRTT.rawValue, "tailnetRelay")
        XCTAssertEqual(Set(PathClass.allCases.map(\.rawValue)).count, 3)
    }

    // MARK: - Tailnet addresses

    func testTheCGNATRangeIsRecognisedAsATailnet() {
        XCTAssertTrue(TailnetAddress.isTailnet("100.64.0.1"))
        XCTAssertTrue(TailnetAddress.isTailnet("100.101.102.103"))
        XCTAssertTrue(TailnetAddress.isTailnet("100.127.255.254"))
    }

    func testAddressesJustOutsideTheRangeAreNot() {
        XCTAssertFalse(TailnetAddress.isTailnet("100.63.0.1"))
        XCTAssertFalse(TailnetAddress.isTailnet("100.128.0.1"))
        XCTAssertFalse(TailnetAddress.isTailnet("192.168.1.14"))
        XCTAssertFalse(TailnetAddress.isTailnet("10.0.0.1"))
    }

    func testTheIPv6PrefixAndMagicDNSCountToo() {
        XCTAssertTrue(TailnetAddress.isTailnet("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailnetAddress.isTailnet("[fd7a:115c:a1e0:ab12:4843:cd96:6264:3]"))
        XCTAssertTrue(TailnetAddress.isTailnet("ipad-pro.tailnet.ts.net"))
        XCTAssertFalse(TailnetAddress.isTailnet("fe80::1%en0"))
        XCTAssertFalse(TailnetAddress.isTailnet("ipad.local"))
    }

    // MARK: - The sample

    func testDeliveredBitsPerSecondIsMeasuredOverTheTickNotAssumed() {
        let sample = LinkSample(bytesDelivered: 125_000, tickSeconds: 0.5)
        XCTAssertEqual(sample.senderDeliveredBps, 2_000_000, accuracy: 1)
    }

    func testATickWithNothingQueuedIsNotASaturatedMeasurement() {
        XCTAssertFalse(LinkSample(sendQueueDepth: 1).wasSaturated)
        XCTAssertTrue(LinkSample(sendQueueDepth: 2).wasSaturated)
        XCTAssertTrue(LinkSample(sendQueueDepth: 0, evictedFrames: 1).wasSaturated)
    }

    // MARK: - Rate estimation

    func testTheFirstObservationSeedsTheEstimateOutright() {
        var estimator = DeliveredRateEstimator()
        estimator.ingest(LinkSample(bytesDelivered: 125_000, tickSeconds: 0.5))
        XCTAssertEqual(estimator.estimateBps, 2_000_000, accuracy: 1)
    }

    func testTheReceiversGoodputIsUsedWhenItIsHigherThanWhatTheSocketTook() {
        // On a backed-up connection the two disagree, and the larger is the
        // better lower bound on the path.
        let sample = LinkSample(bytesDelivered: 12_500, tickSeconds: 0.5,
                                receiverIsFresh: true, receiverGoodputMbps: 3.2)
        XCTAssertEqual(DeliveredRateEstimator.observation(sample) ?? 0, 3_200_000, accuracy: 1)
    }

    func testAStaleReceiverReportContributesNothingToTheEstimate() {
        let sample = LinkSample(bytesDelivered: 12_500, tickSeconds: 0.5,
                                receiverIsFresh: false, receiverGoodputMbps: 3.2)
        XCTAssertEqual(DeliveredRateEstimator.observation(sample) ?? 0, 200_000, accuracy: 1)
    }

    func testAnAppLimitedTickMayNeverPullTheEstimateDown() {
        // THE rule that keeps a static screen from reading as a dead link. The
        // stream sends almost nothing because nothing changed, not because the
        // path collapsed, and a controller that cannot tell the two apart
        // degrades a perfect session to the floor and stays there.
        var estimator = DeliveredRateEstimator()
        estimator.ingest(LinkSample(sendQueueDepth: 2, bytesDelivered: 1_250_000,
                                    tickSeconds: 0.5))
        let before = estimator.estimateBps
        estimator.ingest(LinkSample(sendQueueDepth: 0, bytesDelivered: 100, tickSeconds: 0.5))
        XCTAssertEqual(estimator.estimateBps, before, accuracy: 1)
    }

    func testAnAppLimitedTickMayStillRaiseIt() {
        var estimator = DeliveredRateEstimator()
        estimator.ingest(LinkSample(sendQueueDepth: 2, bytesDelivered: 12_500, tickSeconds: 0.5))
        let before = estimator.estimateBps
        estimator.ingest(LinkSample(sendQueueDepth: 0, bytesDelivered: 1_250_000,
                                    tickSeconds: 0.5))
        XCTAssertGreaterThan(estimator.estimateBps, before)
    }

    func testASaturatedTickMovesTheEstimateBothWays() {
        var estimator = DeliveredRateEstimator()
        estimator.ingest(LinkSample(sendQueueDepth: 2, bytesDelivered: 1_250_000,
                                    tickSeconds: 0.5))
        let before = estimator.estimateBps
        estimator.ingest(LinkSample(sendQueueDepth: 3, evictedFrames: 1,
                                    bytesDelivered: 12_500, tickSeconds: 0.5))
        XCTAssertLessThan(estimator.estimateBps, before)
    }

    func testATickThatDeliveredNothingAtAllIsNotAnObservation() {
        var estimator = DeliveredRateEstimator(seedBps: 5_000_000)
        estimator.ingest(LinkSample(bytesDelivered: 0))
        XCTAssertEqual(estimator.estimateBps, 5_000_000, accuracy: 1)
        XCTAssertEqual(estimator.samples, 0)
    }

    // MARK: - The delay gradient

    func testTheBaselineIsNotTrustedUntilItHasSeenAFewReports() {
        var baseline = DelayBaseline()
        baseline.observe(e2eP50Ms: 54)
        XCTAssertFalse(baseline.isReady)
        baseline.observe(e2eP50Ms: 56)
        baseline.observe(e2eP50Ms: 60)
        XCTAssertTrue(baseline.isReady)
    }

    func testTheBaselineTakesTheLowestLatencyTheSessionHasSeen() {
        var baseline = DelayBaseline()
        [63, 54, 60, 56].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        // 54 is the floor; the two observations above it move it by 2% of the
        // difference each, which is the slow upward drift and nothing more.
        XCTAssertEqual(baseline.baselineMs, 54, accuracy: 0.25)
    }

    func testAQueueBuildingIsCongestionWithZeroDropsAndZeroStalls() {
        // The operator's own numbers: a 54 ms floor, then 146 ms with `stalls`
        // reported but nothing lost. Round 8 had no way to express this.
        var baseline = DelayBaseline()
        [54, 56, 54].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        XCTAssertTrue(baseline.isQueueBuilding(e2eP50Ms: 146, e2eP95Ms: 200))
        XCTAssertFalse(baseline.isQueueBuilding(e2eP50Ms: 63, e2eP95Ms: 120))
    }

    func testTheGradientNeedsAMeaningfulRiseNotJustJitter() {
        var baseline = DelayBaseline()
        [8, 9, 8].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        // Doubling 8 ms is 16 ms, which is noise; the 60 ms floor is what
        // stops a LAN session chasing its own jitter.
        XCTAssertEqual(baseline.triggerP50Ms, 68, accuracy: 0.001)
        XCTAssertFalse(baseline.isQueueBuilding(e2eP50Ms: 20, e2eP95Ms: 40))
    }

    func testAnAbsoluteLatencyCeilingFiresEvenBeforeTheBaselineIsReady() {
        // 608, 1342, 1560 and 1902 ms are the `e2e95` values the operator
        // actually saw. None of them needs a baseline to be a catastrophe.
        var baseline = DelayBaseline()
        baseline.observe(e2eP50Ms: 60)
        XCTAssertFalse(baseline.isReady)
        XCTAssertTrue(baseline.isQueueBuilding(e2eP50Ms: 0, e2eP95Ms: 608))
        XCTAssertTrue(baseline.isQueueBuilding(e2eP50Ms: 0, e2eP95Ms: 1902))
    }

    func testTheBaselineDriftsUpwardsSlowlyRatherThanPinningTheSession() {
        var baseline = DelayBaseline()
        baseline.observe(e2eP50Ms: 10)
        for _ in 0..<200 { baseline.observe(e2eP50Ms: 100) }
        XCTAssertGreaterThan(baseline.baselineMs, 50)
        XCTAssertLessThan(baseline.baselineMs, 100)
    }

    // MARK: - The verdict, and the order signals are trusted in

    func testAnEvictedFrameIsSenderBacklog() {
        XCTAssertEqual(LinkHealth.verdict(congested(), baseline: DelayBaseline()),
                       .congested(.senderBacklog))
    }

    func testAFullQueueIsCongestionBeforeAnythingIsEvicted() {
        let sample = LinkSample(sendQueueDepth: 3, maxSendQueueDepth: 3, framesEncoded: 60)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: DelayBaseline()),
                       .congested(.senderBacklog))
    }

    func testAWriteThatHasNotCompletedForAQuarterOfASecondIsCongestion() {
        // The sender's own measure, needing nothing from the far end — which
        // is the whole reason it is ranked first.
        let sample = LinkSample(sendQueueDepth: 1, oldestWriteAgeMs: 400, framesEncoded: 60)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: DelayBaseline()),
                       .congested(.senderBacklog))
    }

    func testTheDelayGradientIsCongestionWithNoSenderSymptomAtAll() {
        var baseline = DelayBaseline()
        [54, 56, 54].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        let sample = LinkSample(sendQueueDepth: 0, framesEncoded: 60, bytesDelivered: 1000,
                                receiverIsFresh: true, receiverE2eP50Ms: 146,
                                receiverE2eP95Ms: 200)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: baseline),
                       .congested(.delayGradient))
    }

    func testReceiverStallsAreCongestionAndAreRankedLast() {
        let sample = LinkSample(sendQueueDepth: 0, framesEncoded: 60,
                                receiverIsFresh: true, receiverStalls: 7)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: DelayBaseline()),
                       .congested(.receiverDrops))
    }

    func testTheSendersOwnBacklogOutranksEverythingTheReceiverSays() {
        var baseline = DelayBaseline()
        [54, 56, 54].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        let sample = LinkSample(sendQueueDepth: 3, maxSendQueueDepth: 3, evictedFrames: 4,
                                framesEncoded: 60, receiverIsFresh: true,
                                receiverE2eP50Ms: 900, receiverE2eP95Ms: 1902,
                                receiverStalls: 9)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: baseline),
                       .congested(.senderBacklog),
                       "all three fired; the reason reported must be the most trusted one")
    }

    func testTheDelayGradientOutranksDropCounters() {
        var baseline = DelayBaseline()
        [54, 56, 54].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        let sample = LinkSample(sendQueueDepth: 0, framesEncoded: 60,
                                receiverIsFresh: true, receiverE2eP50Ms: 300,
                                receiverE2eP95Ms: 400, receiverStalls: 7)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: baseline),
                       .congested(.delayGradient))
    }

    func testEncoderDropsAreNotCongestion() {
        // This single rule is most of the round-8 oscillation. At 15:29:55,
        // :56 and :57 the controller stepped down three times on `enc↓=18`,
        // `enc↓=21`, `enc↓=31` with `net↓=0` on two of the three. Encoder
        // pressure is a CPU measurement; lowering the bitrate does not make an
        // encoder faster.
        let sample = LinkSample(sendQueueDepth: 0, senderEncDrops: 31, framesEncoded: 40,
                                bytesDelivered: 200_000)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: DelayBaseline()), .clean)
    }

    func testAStaleReceiverReportCannotProduceAVerdictOfItsOwn() {
        // Round 8 logged `e2e95=0ms rtt=0ms` on step-downs because a missing
        // report and a zero-latency report were the same value.
        let sample = LinkSample(sendQueueDepth: 0, framesEncoded: 60, bytesDelivered: 1000,
                                receiverIsFresh: false, receiverAgeSeconds: 54,
                                receiverE2eP95Ms: 1902, receiverStalls: 9)
        XCTAssertEqual(LinkHealth.verdict(sample, baseline: DelayBaseline()), .clean)
    }

    func testCleanDoesNotRequireAFreshReceiverReport() {
        // Requiring one would freeze the controller on exactly the link where
        // reports are rare — the operator's gaps were 7 to 54 seconds.
        XCTAssertEqual(LinkHealth.verdict(clean(), baseline: DelayBaseline()), .clean)
    }

    func testAFreshReportShowingAQueueMakesATickNotClean() {
        var baseline = DelayBaseline()
        [54, 56, 54].forEach { baseline.observe(e2eP50Ms: Double($0)) }
        let sample = LinkSample(sendQueueDepth: 0, framesEncoded: 60, bytesDelivered: 1000,
                                receiverIsFresh: true, receiverE2eP50Ms: 146,
                                receiverE2eP95Ms: 180)
        XCTAssertNotEqual(LinkHealth.verdict(sample, baseline: baseline), .clean)
    }

    func testAPartlyBusyTickIsNeitherAndHoldsTheOperatingPoint() {
        XCTAssertEqual(LinkHealth.verdict(neither(), baseline: DelayBaseline()), .neither)
    }

    // MARK: - The plan and its rungs

    func testTheLadderIsFrameRateFirstThenScale() {
        let levels = AdaptivePlan.rungs(configuredFps: 120, configuredScale: .best)
        XCTAssertEqual(levels.map(\.frameRateCap), [nil, 60, 30, 30, 30])
        XCTAssertEqual(levels.map(\.scale), [.best, .best, .best, .balanced, .fast])
        XCTAssertEqual(levels.map(\.index), [0, 1, 2, 3, 4])
    }

    func testASessionAlreadyAtTheBottomHasNothingLeftToGive() {
        let levels = AdaptivePlan.rungs(configuredFps: 30, configuredScale: .fast)
        XCTAssertEqual(levels.count, 1)
        XCTAssertEqual(levels[0], QualityLevel(index: 0, frameRateCap: nil, scale: .fast))
    }

    func testTheLadderNeverOffersARungAboveTheConfiguredPoint() {
        let levels = AdaptivePlan.rungs(configuredFps: 60, configuredScale: .balanced)
        XCTAssertEqual(levels.map(\.frameRateCap), [nil, 30, 30])
        XCTAssertEqual(levels.map(\.scale), [.balanced, .balanced, .fast])
    }

    func testTheEncodedSizesAreTheOnesTheBriefAsksFor() {
        let plan = self.plan()
        XCTAssertEqual(plan.encodedSize(plan.levels[0]).wide, 2388)
        XCTAssertEqual(plan.encodedSize(plan.levels[0]).high, 1668)
        // 0.75 and 0.5 of the panel, rounded down to even as the encoder wants.
        XCTAssertEqual(plan.encodedSize(plan.levels[3]).wide, 1790)
        XCTAssertEqual(plan.encodedSize(plan.levels[3]).high, 1250)
        XCTAssertEqual(plan.encodedSize(plan.levels[4]).wide, 1194)
        XCTAssertEqual(plan.encodedSize(plan.levels[4]).high, 834)
    }

    func testEachRungNeedsStrictlyLessRateThanTheOneAboveIt() {
        let plan = self.plan()
        let needs = plan.levels.map { plan.minimumViableBps($0) }
        XCTAssertEqual(needs, needs.sorted(by: >))
        // Half the configured bits per pixel per frame at the top rung.
        XCTAssertEqual(needs[0], 14_400_000)
        // …and the bottom rung is inside the 800 kbps floor's reach.
        XCTAssertLessThan(needs[4], 1_000_000)
    }

    func testARateBuysTheShallowestRungItCanActuallyPayFor() {
        let plan = self.plan()
        XCTAssertEqual(plan.viableIndex(targetBps: 28_800_000), 0)
        XCTAssertEqual(plan.viableIndex(targetBps: 8_000_000), 1)
        XCTAssertEqual(plan.viableIndex(targetBps: 4_000_000), 2)
        XCTAssertEqual(plan.viableIndex(targetBps: 2_500_000), 3)
        // 1.3 Mbps — what 0.85 of the operator's measured goodput comes to.
        XCTAssertEqual(plan.viableIndex(targetBps: 1_300_000), 4)
        XCTAssertEqual(plan.viableIndex(targetBps: 100_000), 4)
    }

    // MARK: - The floor

    func testTheFloorIsEightHundredKilobitsNotTenMegabits() {
        // The number this whole rewrite exists for. Round 8's lowest rung was
        // 35% of 28.8 Mbps = 10 Mbps, on a path measured at 0.1–3.2.
        XCTAssertEqual(AdaptiveQualityController.defaultFloorKbps, 800)
        XCTAssertEqual(AdaptiveQualityController.resolveFloorKbps(nil), 800)
    }

    func testTheFloorKeyIsHonouredAndClamped() {
        XCTAssertEqual(AdaptiveQualityController.resolveFloorKbps(NSNumber(value: 1500)), 1500)
        XCTAssertEqual(AdaptiveQualityController.resolveFloorKbps(NSNumber(value: 1)), 64)
        XCTAssertEqual(AdaptiveQualityController.resolveFloorKbps(NSNumber(value: 999_999)), 20_000)
        XCTAssertEqual(AdaptiveQualityController.resolveFloorKbps("800"), 800,
                       "a malformed value falls back rather than refusing to stream")
    }

    func testTheFloorCanNeverExceedTheConfiguredCeiling() {
        let tiny = AdaptivePlan(configuredBitrateBps: 500_000, configuredFps: 30,
                                configuredScale: .fast, baseWide: 2388, baseHigh: 1668,
                                floorBps: 800_000)
        XCTAssertEqual(tiny.floorBps, 500_000)
    }

    // MARK: - The control law

    func testTheTargetStartsAtTheConfiguredRateWhenNothingIsRemembered() {
        let controller = self.controller()
        XCTAssertEqual(controller.targetBps, 28_800_000)
        XCTAssertEqual(controller.levelIndex, 0)
    }

    func testOneDecisionTakesAnLTESessionFromTwentyEightMegabitsToTheEvidence() {
        // The round-8 ladder needed four steps to reach 10 Mbps and could go no
        // further. Here the first decision lands on 85% of what the link is
        // measured to deliver.
        var controller = self.controller()
        let sample = congested(bytes: 100_000)   // 1.6 Mbps over a 0.5 s tick
        let changes = run(&controller, sample, seconds: 3)
        XCTAssertEqual(changes.count, 1, "one change per cooldown, no more")
        let change = try! XCTUnwrap(changes.first)
        XCTAssertEqual(change.targetBps, Int(1_600_000 * 0.85), accuracy: 40_000)
        XCTAssertEqual(change.reason, .congestion(.senderBacklog))
    }

    func testTheFirstDecisionAlsoDropsStraightToTheRungThatRateCanCarry() {
        var controller = self.controller()
        run(&controller, congested(bytes: 100_000), seconds: 3)
        XCTAssertEqual(controller.levelIndex, 4)
        XCTAssertEqual(controller.level.frameRateCap, 30)
        XCTAssertEqual(controller.level.scale, .fast,
                       "on a 1.3 Mbps link 1194x834 at 30 fps beats 2388x1668 at 1 fps")
    }

    func testCongestionMustPersistForASecondBeforeAnythingHappens() {
        var controller = self.controller()
        XCTAssertNil(controller.ingest(congested(), at: 0.5))
        XCTAssertNil(controller.ingest(congested(), at: 1.0))
        XCTAssertNotNil(controller.ingest(congested(), at: 1.6))
    }

    func testASingleBadTickSurroundedByGoodOnesChangesNothing() {
        var controller = self.controller()
        XCTAssertNil(controller.ingest(congested(), at: 0.5))
        XCTAssertNil(controller.ingest(clean(), at: 1.0))
        XCTAssertNil(controller.ingest(congested(), at: 1.5))
        XCTAssertEqual(controller.targetBps, 28_800_000)
    }

    func testNoTwoChangesMayHappenInsideTheCooldown() {
        // 15:29:55, :56 and :57 — three step-downs in three seconds, each
        // judged on evidence that predated the previous one. It cannot happen
        // again: the cooldown is 2.5 s and it is checked before every change.
        var controller = self.controller()
        var changes: [Double] = []
        var t = 0.0
        while t < 12 {
            t += 0.5
            if controller.ingest(congested(), at: t) != nil {
                changes.append(t)
                controller.noteApplied(at: t)
            }
        }
        XCTAssertGreaterThan(changes.count, 1)
        for (a, b) in zip(changes, changes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, AdaptiveQualityController.cooldownSeconds,
                                        "two changes \(b - a)s apart")
        }
    }

    func testTheCooldownIsTwoAndAHalfSecondsAndIsReported() {
        var controller = self.controller()
        XCTAssertEqual(controller.cooldownRemaining(at: 0), 0)
        _ = run(&controller, congested(), seconds: 2)
        XCTAssertGreaterThan(controller.cooldownRemaining(at: 2.0), 0)
        XCTAssertEqual(controller.cooldownRemaining(at: 20), 0)
    }

    func testAnIncreaseNeedsFifteenSecondsOfCleanSignals() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 2000, levelIndex: 4))
        XCTAssertEqual(controller.targetBps, 2_000_000)
        XCTAssertTrue(run(&controller, clean(), seconds: 14).isEmpty)
        let changes = run(&controller, clean(), seconds: 3, from: 14)
        XCTAssertEqual(changes.count, 1)
    }

    func testAnIncreaseIsTenPercentOfTheCurrentTargetNotAJumpToTheCeiling() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 2000, levelIndex: 4))
        let changes = run(&controller, clean(), seconds: 20)
        let change = try! XCTUnwrap(changes.first)
        XCTAssertEqual(change.targetBps, 2_200_000, accuracy: 1000)
    }

    func testRecoveryClimbsOneRungAtATimeAndOnlyWithHeadroom() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 2600, levelIndex: 4))
        // Level 3 needs 2.02 Mbps; the headroom rule asks for 1.25x of that,
        // i.e. 2.52 Mbps, so 2.6 buys exactly one rung and no more.
        let changes = run(&controller, clean(), seconds: 40)
        XCTAssertGreaterThanOrEqual(changes.count, 1)
        XCTAssertEqual(changes[0].level.index, 3)
        XCTAssertEqual(changes[0].previousLevel.index, 4)
        for (a, b) in zip(changes, changes.dropFirst()) {
            XCTAssertLessThanOrEqual(a.level.index - b.level.index, 1,
                                     "recovery gives back one rung at a time")
        }
    }

    func testARateThatJustFailedIsNotRetriedForAMinute() {
        var controller = self.controller()
        run(&controller, congested(bytes: 500_000), seconds: 3)   // 8 Mbps link
        let failedFrom = 28_800_000
        // Now perfectly clean for two minutes. Within the first minute the ramp
        // must stay under what failed; after it, the ceiling is the configured
        // rate again.
        var t = 3.0
        var duringPenalty: [Int] = []
        while t < 60 {
            t += 0.5
            if let change = controller.ingest(clean(bytes: 2_000_000), at: t) {
                duringPenalty.append(change.targetBps)
                controller.noteApplied(at: t)
            }
        }
        XCTAssertFalse(duringPenalty.isEmpty)
        for target in duringPenalty {
            XCTAssertLessThan(target, failedFrom)
            XCTAssertLessThanOrEqual(target, Int(Double(failedFrom) * 0.95))
        }
    }

    func testThePenaltyExpiresOnItsOwnClock() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 20_000, levelIndex: 0))
        run(&controller, congested(bytes: 900_000), seconds: 3)   // fails at 20 Mbps
        var t = 3.0
        while t < 400 {
            t += 0.5
            if controller.ingest(clean(bytes: 4_000_000), at: t) != nil {
                controller.noteApplied(at: t)
            }
        }
        XCTAssertEqual(controller.targetBps, 28_800_000,
                       "after the penalty and enough clean windows the ceiling is reachable again")
    }

    func testTheTargetNeverExceedsTheConfiguredRate() {
        var controller = self.controller()
        run(&controller, clean(bytes: 50_000_000), seconds: 600)
        XCTAssertEqual(controller.targetBps, 28_800_000)
    }

    func testTheTargetNeverGoesBelowTheFloor() {
        var controller = self.controller()
        run(&controller, congested(bytes: 100), seconds: 600)
        XCTAssertEqual(controller.targetBps, AdaptiveQualityController.defaultFloorKbps * 1000)
        XCTAssertEqual(controller.levelIndex, 4)
    }

    func testAtTheFloorAndTheBottomRungTheControllerStopsDecidingThings() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 800, levelIndex: 4))
        XCTAssertTrue(run(&controller, congested(bytes: 100), seconds: 60).isEmpty,
                      "nothing left to give is not a decision, and must not consume a cooldown")
    }

    func testAnImperfectButNotCongestedLinkHoldsItsOperatingPoint() {
        var controller = self.controller(start: OperatingPoint(targetKbps: 4000, levelIndex: 2))
        XCTAssertTrue(run(&controller, neither(), seconds: 120).isEmpty)
        XCTAssertEqual(controller.targetBps, 4_000_000)
        XCTAssertEqual(controller.levelIndex, 2)
    }

    func testTheDecreaseIsMultiplicativeOnceTheEstimateIsAlreadyBeingObeyed() {
        // The escape hatch: when the target is already inside what the estimate
        // says the path carries and it is *still* congested, the estimate is
        // optimistic and only a multiplicative cut finds the real limit.
        var controller = self.controller(start: OperatingPoint(targetKbps: 1000, levelIndex: 4))
        // Deliver 1.2 Mbps (estimate ≈ 1.2, evidence ≈ 1.02, target 1.0) while
        // reporting a full queue.
        let sample = LinkSample(sendQueueDepth: 3, maxSendQueueDepth: 3, evictedFrames: 1,
                                framesEncoded: 20, bytesDelivered: 75_000)
        let changes = run(&controller, sample, seconds: 3)
        let change = try! XCTUnwrap(changes.first)
        XCTAssertEqual(change.targetBps, 800_000,
                       "×0.7 of 1.0 Mbps is 0.7, clamped up to the 800 kbps floor")
    }

    // MARK: - Remembering where a path class settled

    func testUnknownTailnetStartsAtFourMbpsWithAPlayableFrameRate() {
        let controller = self.controller(pathClass: .tailnetLowRTT,
                                         knownTailnetEndpoint: true)
        XCTAssertEqual(controller.targetBps, 4_000_000)
        XCTAssertEqual(controller.level.frameRateCap, 30)
    }

    func testAHighRememberedTailnetRateCannotOverloadAChangedRouteAtStartup() {
        let controller = self.controller(pathClass: .tailnetLowRTT,
                                         knownTailnetEndpoint: true,
                                         start: OperatingPoint(targetKbps: 28_800, levelIndex: 0))
        XCTAssertEqual(controller.targetBps, 4_000_000)
        XCTAssertEqual(controller.level.frameRateCap, 30)
    }

    func testLateTailnetClassificationCapsAnUnrememberedLocalStart() {
        var controller = self.controller(pathClass: .lan)
        XCTAssertEqual(controller.targetBps, 28_800_000)
        XCTAssertTrue(controller.reclassify(as: .tailnetLowRTT, remembered: nil,
                                            knownTailnetEndpoint: true))
        XCTAssertEqual(controller.targetBps, 4_000_000)
        XCTAssertEqual(controller.level.frameRateCap, 30)
    }

    func testSlowWifiRttCannotApplyTailnetMemoryOrStartupCap() {
        let measuredClass = PathClass.classify(directLink: false, wired: false,
                                                tailnet: false, rttMs: 25)
        var controller = self.controller(pathClass: .lan)
        XCTAssertFalse(controller.reclassify(
            as: measuredClass,
            remembered: OperatingPoint(targetKbps: 1400, levelIndex: 4),
            knownTailnetEndpoint: false))
        XCTAssertEqual(controller.targetBps, 28_800_000)
        XCTAssertNil(controller.stableOperatingPoint(at: 30))
    }

    func testRememberedSlowTailnetPointDoesNotEnterFastStartupProbe() {
        var controller = self.controller(pathClass: .tailnetHighRTT,
                                         knownTailnetEndpoint: true,
                                         start: OperatingPoint(targetKbps: 1400, levelIndex: 4))
        for step in 1...10 {
            var sample = clean()
            sample.receiverIsFresh = step == 10
            XCTAssertNil(controller.ingest(sample, at: Double(step) / 2))
        }
        XCTAssertEqual(controller.targetBps, 1_400_000)
    }

    func testTailnetProbesRapidlyWhileFramesAreFlowingAndTheLinkIsClean() {
        var controller = self.controller(pathClass: .tailnetLowRTT,
                                         knownTailnetEndpoint: true)
        var targets: [Int] = []
        for step in 1...32 {
            var sample = clean()
            sample.receiverIsFresh = step.isMultiple(of: 10) // reports every five seconds
            if step == 9 { XCTAssertEqual(controller.targetBps, 4_000_000) }
            if let change = controller.ingest(sample, at: Double(step) / 2) {
                targets.append(change.targetBps)
                controller.noteApplied(at: Double(step) / 2)
            }
        }
        XCTAssertEqual(targets, [8_000_000, 16_000_000, 28_800_000])
        XCTAssertEqual(controller.levelIndex, 0)
    }

    func testTailnetDoesNotProbeWhileNoFramesAreFlowing() {
        var controller = self.controller(pathClass: .tailnetLowRTT,
                                         knownTailnetEndpoint: true)
        let idle = LinkSample(sendQueueDepth: 0)
        XCTAssertTrue(run(&controller, idle, seconds: 20).isEmpty)
        XCTAssertEqual(controller.targetBps, 4_000_000)
        XCTAssertTrue(run(&controller, clean(), seconds: 2, from: 20).isEmpty)
    }

    func testCongestionEndsStartupProbing() {
        var controller = self.controller(pathClass: .tailnetLowRTT,
                                         knownTailnetEndpoint: true)
        XCTAssertFalse(run(&controller, congested(), seconds: 3).isEmpty)
        let afterCongestion = controller.targetBps
        XCTAssertTrue(run(&controller, clean(), seconds: 10, from: 3).isEmpty)
        XCTAssertEqual(controller.targetBps, afterCongestion)
    }

    func testASessionStartsFromTheRememberedOperatingPointNotAtFullRate() {
        let controller = self.controller(pathClass: .tailnetHighRTT,
                                         knownTailnetEndpoint: true,
                                         start: OperatingPoint(targetKbps: 1400, levelIndex: 4))
        XCTAssertEqual(controller.targetBps, 1_400_000)
        XCTAssertEqual(controller.levelIndex, 4)
        XCTAssertTrue(controller.startDescription.contains("tailnet-high-rtt"))
        XCTAssertTrue(controller.startDescription.contains("1.40"))
    }

    func testARememberedPointIsClampedToThisSessionsPlan() {
        let controller = self.controller(start: OperatingPoint(targetKbps: 99_000, levelIndex: 42))
        XCTAssertEqual(controller.targetBps, 28_800_000)
        XCTAssertEqual(controller.levelIndex, 4)
    }

    func testAPointIsOnlyRememberedOnceItHasActuallyHeldStill() {
        var controller = self.controller()
        controller.noteApplied(at: 0)
        XCTAssertNil(controller.stableOperatingPoint(at: 10))
        XCTAssertNotNil(controller.stableOperatingPoint(at: 25))
    }

    func testAChangeRestartsTheStabilityClock() {
        var controller = self.controller()
        controller.noteApplied(at: 0)
        XCTAssertNotNil(controller.stableOperatingPoint(at: 25))
        run(&controller, congested(), seconds: 3, from: 25)
        XCTAssertNil(controller.stableOperatingPoint(at: 30))
    }

    func testReclassifyingAdoptsTheOtherClassesPointOnlyBeforeAnythingWasDecided() {
        var fresh = self.controller(pathClass: .tailnetLowRTT)
        XCTAssertTrue(fresh.reclassify(as: .tailnetHighRTT,
                                       remembered: OperatingPoint(targetKbps: 1200, levelIndex: 4),
                                       knownTailnetEndpoint: true))
        XCTAssertEqual(fresh.targetBps, 1_200_000)
        XCTAssertEqual(fresh.pathClass, .tailnetHighRTT)

        var decided = self.controller(pathClass: .tailnetLowRTT)
        run(&decided, congested(bytes: 200_000), seconds: 3)
        let afterDecision = decided.targetBps
        XCTAssertFalse(decided.reclassify(as: .tailnetHighRTT,
                                          remembered: OperatingPoint(targetKbps: 1200,
                                                                     levelIndex: 4),
                                          knownTailnetEndpoint: true))
        XCTAssertEqual(decided.targetBps, afterDecision,
                       "measured evidence beats a remembered number from another class")
        XCTAssertEqual(decided.pathClass, .tailnetHighRTT, "the class itself is still corrected")
    }

    func testAFreshCaptureIsJudgedOnItsOwnEvidence() {
        var controller = self.controller()
        run(&controller, congested(bytes: 100_000), seconds: 3)
        XCTAssertLessThan(controller.targetBps, 28_800_000)
        controller.resetForNewCapture(at: 100)
        XCTAssertEqual(controller.targetBps, 28_800_000)
        XCTAssertEqual(controller.levelIndex, 0)
        XCTAssertFalse(controller.hasDecided)
    }

    // MARK: - The store

    func testAnEmptyStoreRemembersNothing() {
        XCTAssertNil(OperatingPointStore.decode(nil, for: .lan))
        XCTAssertNil(OperatingPointStore.decode(["lan": ["level": 2]], for: .lan))
        XCTAssertNil(OperatingPointStore.decode(["lan": ["kbps": 0]], for: .lan))
    }

    func testAPointSurvivesARoundTrip() {
        let stored = OperatingPointStore.encode(nil,
                                                point: OperatingPoint(targetKbps: 1400,
                                                                      levelIndex: 4),
                                                for: .tailnetHighRTT)
        XCTAssertEqual(OperatingPointStore.decode(stored, for: .tailnetHighRTT),
                       OperatingPoint(targetKbps: 1400, levelIndex: 4))
    }

    func testWritingOneClassLeavesTheOthersAlone() {
        // An evening on LTE must not erase what the LAN learned.
        var stored = OperatingPointStore.encode(nil,
                                                point: OperatingPoint(targetKbps: 28_800,
                                                                      levelIndex: 0),
                                                for: .lan)
        stored = OperatingPointStore.encode(stored,
                                            point: OperatingPoint(targetKbps: 1400, levelIndex: 4),
                                            for: .tailnetHighRTT)
        XCTAssertEqual(OperatingPointStore.decode(stored, for: .lan)?.targetKbps, 28_800)
        XCTAssertEqual(OperatingPointStore.decode(stored, for: .tailnetHighRTT)?.targetKbps, 1400)
        XCTAssertNil(OperatingPointStore.decode(stored, for: .tailnetLowRTT))
    }

    func testTheStoreIsPropertyListSafe() {
        let stored = OperatingPointStore.encode(nil,
                                                point: OperatingPoint(targetKbps: 900,
                                                                      levelIndex: 3),
                                                for: .tailnetLowRTT)
        XCTAssertTrue(PropertyListSerialization.propertyList(stored, isValidFor: .binary),
                      "this goes straight into UserDefaults")
    }

    // MARK: - The setting

    func testAdaptiveQualityIsOnWhenTheKeyHasNeverBeenWritten() {
        XCTAssertTrue(AdaptiveQualityController.resolveEnabled(nil))
    }

    func testAdaptiveQualityHonoursAnExplicitFalse() {
        XCTAssertFalse(AdaptiveQualityController.resolveEnabled(false))
    }

    func testAMalformedValueLeavesItOn() {
        XCTAssertTrue(AdaptiveQualityController.resolveEnabled("no"))
    }

    func testTheKeysAreTheOnesDocumented() {
        XCTAssertEqual(AdaptiveQualityController.defaultsKey, "adaptiveQuality")
        XCTAssertEqual(AdaptiveQualityController.floorDefaultsKey, "adaptiveFloorKbps")
        XCTAssertEqual(OperatingPointStore.defaultsKey, "adaptiveOperatingPoints")
    }

    func testTheLevelsDescribeThemselvesForThePanel() {
        let plan = self.plan()
        XCTAssertEqual(plan.levels[0].statusText, "full quality")
        XCTAssertEqual(plan.levels[1].label, "60 fps, best")
        XCTAssertEqual(plan.levels[4].label, "30 fps, fast")
        XCTAssertEqual(QualityLevel.unconstrained.index, 0)
    }

    // MARK: - Reporting

    func testADecisionLineCarriesTheEstimateTheTargetTheReasonAndTheLevel() {
        var controller = self.controller(pathClass: .tailnetHighRTT)
        let sample = congested(bytes: 100_000)
        var change: AdaptiveQualityController.Change?
        var t = 0.0
        while change == nil, t < 5 {
            t += 0.5
            change = controller.ingest(sample, at: t)
        }
        let line = controller.decisionLine(try! XCTUnwrap(change), sample: sample, at: t)
        XCTAssertTrue(line.contains("target "), line)
        XCTAssertTrue(line.contains("estimate "), line)
        XCTAssertTrue(line.contains("sender-backlog"), line)
        XCTAssertTrue(line.contains("level 4/4"), line)
        XCTAssertTrue(line.contains("30 fps, fast 1194x834"), line)
        XCTAssertTrue(line.contains("cooldown 2.5s"), line)
        XCTAssertTrue(line.contains("path tailnet-high-rtt"), line)
        // A decision taken blind must say so instead of printing zeroes.
        XCTAssertTrue(line.contains("no fresh receiver report"), line)
    }

    func testThePanelLineSaysWhereTheControllerStands() {
        let controller = self.controller(pathClass: .tailnetHighRTT,
                                         start: OperatingPoint(targetKbps: 1400, levelIndex: 4))
        let line = controller.panelLine(sample: clean(), at: 12)
        XCTAssertTrue(line.contains("adaptive panel:"), line)
        XCTAssertTrue(line.contains("1.40 Mbps"), line)
        XCTAssertTrue(line.contains("30 fps"), line)
        XCTAssertTrue(line.contains("fast 1194x834"), line)
        XCTAssertTrue(line.contains("estimate "), line)
        XCTAssertTrue(line.contains("path tailnet-high-rtt"), line)
    }

    // MARK: - The whole failure, replayed

    func testTheOperatorsSessionSettlesInsteadOfOscillating() {
        // A path that delivers ~1.5 Mbps and reports late, exactly as the
        // 15:29–15:33 window did. Round 8 made ten *level* changes here — down
        // 1, up 0, down 1, down 2, up 1, down 2, down 3, up 2, up 1, up 0 —
        // and twice returned the whole session to 100% of 28.8 Mbps on a link
        // that had never once carried it.
        var controller = self.controller(pathClass: .tailnetHighRTT,
                                         knownTailnetEndpoint: true)
        var changes: [AdaptiveQualityController.Change] = []
        var times: [Double] = []
        var t = 0.0
        var sinceReport = 0.0
        while t < 120 {
            t += 0.5
            sinceReport += 0.5
            // Reports arrive every 20 s on this link, not every 5.
            let fresh = sinceReport >= 20
            if fresh { sinceReport = 0 }
            let overBudget = controller.targetBps > 1_600_000
            let sample = LinkSample(
                sendQueueDepth: overBudget ? 3 : 0,
                maxSendQueueDepth: 3,
                oldestWriteAgeMs: overBudget ? 500 : 20,
                writeCompletionP95Ms: overBudget ? 450 : 18,
                evictedFrames: overBudget ? 3 : 0,
                senderEncDrops: 20,          // always noisy; must not matter
                framesEncoded: 30,
                bytesDelivered: 95_000,      // ~1.5 Mbps
                tickSeconds: 0.5,
                receiverIsFresh: fresh,
                receiverAgeSeconds: sinceReport,
                receiverGoodputMbps: 1.5,
                receiverE2eP50Ms: overBudget ? 900 : 60,
                receiverE2eP95Ms: overBudget ? 1902 : 90,
                receiverStalls: overBudget ? 7 : 0,
                receiverRttMs: 114)
            if let change = controller.ingest(sample, at: t) {
                changes.append(change)
                times.append(t)
                controller.noteApplied(at: t)
            }
        }

        // 1. The visible thing — the frame rate and the captured size — moves
        //    exactly once, on the way down, and never comes back.
        let leverChanges = changes.filter(\.changesLever)
        XCTAssertEqual(leverChanges.count, 1)
        XCTAssertEqual(controller.levelIndex, 4)

        // 2. Everything else is a ±10% bitrate probe: one property write on a
        //    live compression session, invisible to the user. That is what AIMD
        //    is *for*, and it is a different thing from round 8's ten
        //    frame-rate and 30%-bitrate steps.
        for change in changes.dropFirst() {
            let ratio = Double(change.targetBps) / Double(change.previousTargetBps)
            XCTAssertGreaterThan(ratio, 0.7)
            XCTAssertLessThan(ratio, 1.3)
        }

        // 3. Never back to the configured rate. Round 8 did that twice.
        for change in changes.dropFirst() {
            XCTAssertLessThan(change.targetBps, 3_000_000)
        }

        // 4. Every change respects the cooldown.
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, AdaptiveQualityController.cooldownSeconds)
        }

        // 5. And it converges: the penalty memory tightens the ceiling on each
        //    failed probe, so the session ends inside what the path delivers.
        XCTAssertLessThanOrEqual(controller.targetBps, 1_600_000)
        XCTAssertGreaterThan(controller.targetBps, 1_000_000)
    }
}
