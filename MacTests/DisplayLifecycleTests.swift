import XCTest

/// The virtual display's lifetime: what the enforcement loop is allowed to do,
/// and the guarantee that a display this process created always goes back.
///
/// Every case here comes from the round-9 session that ended with
/// `@2x mode vanished from display 185 — re-applying settings` thirty times in
/// seven seconds, a Mac that would not accept a password at its own lock
/// screen, and — after the sender died — two orphaned `CGVirtualDisplay`s in
/// CoreGraphics with the real monitor missing from `CGGetOnlineDisplayList`.
final class DisplayLifecycleTests: XCTestCase {

    // MARK: - The loop that ran thirty times

    /// The exact shape of the failure. Round 9's loop ticked every ~225 ms and
    /// re-applied settings on every single tick; over the seven seconds the
    /// operator logged, that is thirty display-reconfiguration transactions.
    /// The same seven seconds may now cost at most four.
    func testTheRoundNineLoopCannotHappenAgain() {
        var enforcement = HiDPIEnforcement()
        var applies = 0
        var now = 0.0
        while now < 7.0 {
            if case .reapplySettings = enforcement.decide(.modeMissing, reconfiguring: false, now: now) {
                applies += 1
            }
            now += 0.225
        }
        XCTAssertEqual(applies, 4, "0.5/1/2/4s backoff allows four attempts inside seven seconds")
        XCTAssertLessThan(applies, 30)
    }

    func testAMissingModeIsRetriedWithExponentialBackoff() {
        var enforcement = HiDPIEnforcement()
        // First failure: act at once. A transient mode loss should heal fast.
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 0),
                       .reapplySettings(attempt: 1))
        // 200 ms later — the tick rate — it must not act again.
        guard case .waitForBackoff = enforcement.decide(.modeMissing, reconfiguring: false, now: 0.2) else {
            return XCTFail("a second attempt 200 ms after the first is the round-9 defect")
        }
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 0.5),
                       .reapplySettings(attempt: 2))
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 1.5),
                       .reapplySettings(attempt: 3))
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 3.5),
                       .reapplySettings(attempt: 4))
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 7.5),
                       .reapplySettings(attempt: 5))
    }

    func testTheBackoffIsCapped() {
        XCTAssertEqual(HiDPIEnforcement.backoff(attempt: 1), 0.5)
        XCTAssertEqual(HiDPIEnforcement.backoff(attempt: 5), 8.0)
        // Nothing ever waits longer than the ceiling, however many attempts a
        // future maxAttempts allows.
        XCTAssertEqual(HiDPIEnforcement.backoff(attempt: 20),
                       HiDPIEnforcement.backoffCeilingSeconds)
    }

    /// "Must give up and report rather than spin."
    func testEnforcementGivesUpAndReportsInsteadOfSpinning() {
        var enforcement = HiDPIEnforcement()
        var now = 0.0
        var reported: String?
        for _ in 0..<500 {
            switch enforcement.decide(.modeMissing, reconfiguring: false, now: now) {
            case .reportLost(let reason): reported = reported ?? reason
            default: break
            }
            now += 0.2
        }
        XCTAssertNotNil(reported, "five failed re-applies must end in a report")
        XCTAssertTrue(enforcement.gaveUp)
        XCTAssertEqual(enforcement.attempts, HiDPIEnforcement.maxAttempts)
    }

    /// The report is made once. A caller that rebuilds on it must not be asked
    /// to rebuild five hundred more times.
    func testTheGiveUpIsReportedExactlyOnce() {
        var enforcement = HiDPIEnforcement()
        var now = 0.0
        var reports = 0
        for _ in 0..<500 {
            if case .reportLost = enforcement.decide(.modeMissing, reconfiguring: false, now: now) {
                reports += 1
            }
            now += 0.2
        }
        XCTAssertEqual(reports, 1)
    }

    /// The single most important line in the file. `CGDisplayCopyAllDisplayModes`
    /// returning nothing is not "the mode vanished" — it is "the display is not
    /// answering", and round 9's answer to it (re-publish the settings) is what
    /// turned a five-second bring-up into a WindowServer storm.
    func testAnUnqueryableDisplayIsNeverAnsweredWithAReapply() {
        var enforcement = HiDPIEnforcement()
        var now = 0.0
        for _ in 0..<200 {
            if case .reapplySettings = enforcement.decide(.displayNotQueryable,
                                                          reconfiguring: false, now: now) {
                XCTFail("re-applying settings to a display that is not answering is the storm")
            }
            now += 0.2
        }
    }

    /// It is still not allowed to be silent forever: a display that stops
    /// answering and stays that way is lost, and the session has to be told.
    func testADisplayThatStopsAnsweringIsEventuallyReportedLost() {
        var enforcement = HiDPIEnforcement()
        XCTAssertEqual(enforcement.decide(.displayNotQueryable, reconfiguring: false, now: 0),
                       .nothing)
        XCTAssertEqual(enforcement.decide(.displayNotQueryable, reconfiguring: false, now: 4),
                       .nothing, "four seconds is inside a normal bring-up")
        guard case .reportLost = enforcement.decide(.displayNotQueryable, reconfiguring: false,
                                                    now: HiDPIEnforcement.notQueryableGraceSeconds + 0.1)
        else { return XCTFail("a display eight seconds gone is gone") }
    }

    /// "Must never fight a reconfiguration in progress."
    func testNothingHappensWhileAReconfigurationIsInProgress() {
        var enforcement = HiDPIEnforcement()
        for observation: HiDPIEnforcement.Observation in [.modeMissing, .displayNotQueryable, .inHiDPIMode] {
            var now = 0.0
            for _ in 0..<100 {
                XCTAssertEqual(enforcement.decide(observation, reconfiguring: true, now: now),
                               .waitForReconfiguration)
                now += 0.2
            }
        }
        XCTAssertEqual(enforcement.attempts, 0)
        XCTAssertFalse(enforcement.gaveUp)
    }

    /// The precise round-9 sequence: a `resize()` followed by a five-second
    /// `findSCDisplay` poll. Throughout it the display is unqueryable, and the
    /// enforcement loop must neither re-apply anything nor convict it.
    func testAResizeFollowedByAFiveSecondPollCostsNothing() {
        var enforcement = HiDPIEnforcement()
        var now = 0.0
        while now < 5.0 {
            XCTAssertEqual(enforcement.decide(.displayNotQueryable, reconfiguring: true, now: now),
                           .waitForReconfiguration)
            now += 0.2
        }
        // The display comes back the moment the reconfiguration ends.
        XCTAssertEqual(enforcement.decide(.inHiDPIMode, reconfiguring: false, now: now), .nothing)
        XCTAssertNil(enforcement.notQueryableSince)
    }

    func testSuccessResetsTheBackoffSoTheNextFailureIsAnsweredFast() {
        var enforcement = HiDPIEnforcement()
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 0),
                       .reapplySettings(attempt: 1))
        XCTAssertEqual(enforcement.decide(.inHiDPIMode, reconfiguring: false, now: 1), .nothing)
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 1.1),
                       .reapplySettings(attempt: 1),
                       "a healed display's next failure is a new failure")
    }

    /// A give-up is permanent until something deliberate happens, because
    /// "try again in a while" is how thirty lines become three hundred.
    func testAGiveUpIsPermanentUntilAReset() {
        var enforcement = HiDPIEnforcement()
        var now = 0.0
        for _ in 0..<50 {
            _ = enforcement.decide(.modeMissing, reconfiguring: false, now: now)
            now += 1.0
        }
        XCTAssertTrue(enforcement.gaveUp)
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 3600), .nothing)
        // A rotation republishes the mode list, so the verdict is stale.
        enforcement.reset()
        XCTAssertFalse(enforcement.gaveUp)
        XCTAssertEqual(enforcement.decide(.modeMissing, reconfiguring: false, now: 3600),
                       .reapplySettings(attempt: 1))
    }

    // MARK: - The release path

    private func freshRegistry() -> VirtualDisplayRegistry { VirtualDisplayRegistry() }

    func testAReleasedDisplayIsDroppedExactlyOnce() {
        let registry = freshRegistry()
        var drops = 0
        let token = registry.register("display 185") { drops += 1 }
        XCTAssertEqual(registry.liveCount, 1)
        XCTAssertTrue(registry.release(token))
        XCTAssertEqual(drops, 1)
        XCTAssertEqual(registry.liveCount, 0)
        // Idempotent: `MacSender.stop()`, `reconfigure`'s catch and `deinit` can
        // all reach the same display, and two of them commonly do.
        XCTAssertFalse(registry.release(token))
        XCTAssertEqual(drops, 1)
    }

    /// The orphan the operator had to kill BetterDisplay to get rid of. Whatever
    /// else failed, the process must not still be holding a display.
    func testReleaseAllDropsEveryDisplayTheProcessHolds() {
        let registry = freshRegistry()
        var dropped: [String] = []
        registry.register("session A") { dropped.append("A") }
        registry.register("session B") { dropped.append("B") }
        XCTAssertEqual(registry.liveCount, 2)
        XCTAssertEqual(registry.releaseAll(), 2)
        XCTAssertEqual(dropped.sorted(), ["A", "B"])
        XCTAssertEqual(registry.liveCount, 0)
        XCTAssertEqual(registry.releaseAll(), 0, "a second exit handler finds nothing left")
    }

    /// `releaseAll` after an individual release must not run the same drop
    /// twice — the exit handler and `stop()` race on every ordinary quit.
    func testAnIndividualReleaseAndAReleaseAllDoNotBothFire() {
        let registry = freshRegistry()
        var drops = 0
        let a = registry.register("A") { drops += 1 }
        registry.register("B") { drops += 1 }
        registry.release(a)
        XCTAssertEqual(registry.releaseAll(), 1)
        XCTAssertEqual(drops, 2, "two displays, two drops, however the two paths interleave")
    }

    func testTheRegistryNamesWhatItIsStillHolding() {
        let registry = freshRegistry()
        registry.register("OpenDisplay — iPad Pro (display 185)") {}
        XCTAssertEqual(registry.liveLabels, ["OpenDisplay — iPad Pro (display 185)"])
        registry.releaseAll()
        XCTAssertTrue(registry.liveLabels.isEmpty)
    }

    /// The release path is reached from `queue`, from the main actor, from a
    /// `deinit` on whatever thread ARC chose, and from a dispatch signal source.
    /// Exactly one drop per display, whoever gets there first.
    func testConcurrentReleasesStillDropEachDisplayOnce() {
        let registry = freshRegistry()
        let counter = DropCounter()
        var tokens: [VirtualDisplayRegistry.Token] = []
        for i in 0..<200 { tokens.append(registry.register("d\(i)") { counter.bump() }) }
        let group = DispatchGroup()
        for token in tokens {
            DispatchQueue.global().async(group: group) { registry.release(token) }
            DispatchQueue.global().async(group: group) { registry.release(token) }
        }
        DispatchQueue.global().async(group: group) { _ = registry.releaseAll() }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(counter.value, 200)
        XCTAssertEqual(registry.liveCount, 0)
    }

    /// Installing the exit handlers twice must not install them twice: a second
    /// `atexit` registration would try to release an already-released display,
    /// and `VirtualDisplay.init` calls this on every display it creates.
    func testInstallingTheExitHandlersIsIdempotent() {
        let registry = freshRegistry()
        var installs = 0
        XCTAssertTrue(registry.installProcessExitHandlers(using: { installs += 1 }))
        XCTAssertFalse(registry.installProcessExitHandlers(using: { installs += 1 }))
        XCTAssertFalse(registry.installProcessExitHandlers(using: { installs += 1 }))
        XCTAssertEqual(installs, 1)
        // And the registry still works afterwards, which is the point.
        var drops = 0
        let token = registry.register("after") { drops += 1 }
        XCTAssertTrue(registry.release(token))
        XCTAssertEqual(drops, 1)
    }

    private final class DropCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - The lever cap

    func testTheLeverCapDefaultsToFrameRateUntilTheScaleLeverIsProven() {
        XCTAssertEqual(AdaptiveLeverCap.standard, .frameRate)
        XCTAssertEqual(AdaptiveLeverCap.resolve(nil), .frameRate)
        XCTAssertEqual(AdaptiveLeverCap.resolve("frameRate"), .frameRate)
        XCTAssertEqual(AdaptiveLeverCap.resolve("scale"), .scale)
        XCTAssertEqual(AdaptiveLeverCap.resolve(" scale "), .scale, "a defaults write with a stray space")
    }

    func testAnUnparseableLeverCapIsTheSafeOne() {
        for junk: Any in ["", "SCALE", "bitrate", 3, true, ["scale"]] {
            XCTAssertEqual(AdaptiveLeverCap.resolve(junk), .frameRate,
                           "a typo must not hand the ladder a lever it cannot use")
        }
    }

    /// The guard rail itself: capping at `frameRate` removes the scale rungs and
    /// nothing else.
    func testCappingAtFrameRateRemovesTheScaleRungsAndKeepsTheRest() {
        let full = AdaptivePlan.rungs(configuredFps: 120, configuredScale: .best, maxLever: .scale)
        let capped = AdaptivePlan.rungs(configuredFps: 120, configuredScale: .best, maxLever: .frameRate)
        XCTAssertEqual(full.map(\.label),
                       ["full rate, best", "60 fps, best", "30 fps, best",
                        "30 fps, balanced", "30 fps, fast"])
        XCTAssertEqual(capped.map(\.label), ["full rate, best", "60 fps, best", "30 fps, best"])
        XCTAssertTrue(capped.allSatisfy { $0.scale == .best })
        XCTAssertEqual(capped, Array(full.prefix(3)), "the rungs that remain are unchanged")
    }

    /// A capped ladder is still a congestion controller: the rate control, the
    /// floor and the ceiling are untouched, which is the whole reason this is a
    /// cap and not an off switch.
    func testACappedPlanKeepsItsRateControl() {
        let capped = AdaptivePlan(configuredBitrateBps: 28_800_000, configuredFps: 120,
                                  configuredScale: .best, baseWide: 2388, baseHigh: 1668,
                                  floorBps: 800_000, maxLever: .frameRate)
        XCTAssertEqual(capped.maxLever, .frameRate)
        XCTAssertEqual(capped.levels.count, 3)
        XCTAssertEqual(capped.floorBps, 800_000)
        XCTAssertEqual(capped.configuredBitrateBps, 28_800_000)
        // Every rung is full size, so the encoded size never moves.
        for level in capped.levels {
            XCTAssertEqual(capped.encodedSize(level).wide, 2388)
            XCTAssertEqual(capped.encodedSize(level).high, 1668)
        }
        // And the descent still bottoms out at the lowest rung rather than
        // running off the end of the ladder.
        XCTAssertEqual(capped.viableIndex(targetBps: 100_000), 2)
    }

    /// A plan built without an opinion is the full ladder; the *app's* default
    /// is the cap. The two are deliberately different and this pins both.
    func testThePlanTypeDefaultsToTheFullLadderAndTheAppDefaultsToTheCap() {
        let unspecified = AdaptivePlan(configuredBitrateBps: 28_800_000, configuredFps: 120,
                                       configuredScale: .best, baseWide: 2388, baseHigh: 1668,
                                       floorBps: 800_000)
        XCTAssertEqual(unspecified.maxLever, .scale)
        XCTAssertEqual(unspecified.levels.count, 5)
        XCTAssertEqual(AdaptiveLeverCap.standard, .frameRate)
    }

    func testCappingASessionThatHasNoScaleRungsAnywayChangesNothing() {
        // Already configured at Fast: there were never any scale rungs below it.
        let full = AdaptivePlan.rungs(configuredFps: 30, configuredScale: .fast, maxLever: .scale)
        let capped = AdaptivePlan.rungs(configuredFps: 30, configuredScale: .fast, maxLever: .frameRate)
        XCTAssertEqual(full, capped)
        XCTAssertEqual(capped.count, 1)
    }

    func testBothCapsAreSpelledTheWayTheDefaultsKeyExpects() {
        XCTAssertEqual(AdaptiveLeverCap.defaultsKey, "adaptiveMaxLever")
        XCTAssertEqual(Set(AdaptiveLeverCap.allCases.map(\.rawValue)), ["frameRate", "scale"])
    }
}
