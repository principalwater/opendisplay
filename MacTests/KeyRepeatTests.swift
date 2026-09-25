import XCTest

/// Fake scheduler: records what the controller asked for and lets a test fire
/// repeats by hand, so none of this waits on wall-clock time.
private final class FakeRepeatScheduler: KeyRepeatScheduling {
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var lastDelay: TimeInterval?
    private(set) var lastInterval: TimeInterval?
    private var fire: (() -> Void)?
    private var cancelledFire: (() -> Void)?

    var isRunning: Bool { fire != nil }

    func start(delay: TimeInterval, interval: TimeInterval, fire: @escaping () -> Void) {
        startCount += 1
        lastDelay = delay
        lastInterval = interval
        self.fire = fire
    }

    /// Only counts cancels that actually stopped a running timer — the
    /// controller cancels defensively before every start, and a cancel of
    /// nothing is not an observable event.
    ///
    /// The handler is *retained* after cancelling, in `cancelledFire`. A real
    /// `DispatchSourceTimer.cancel()` does not wait for a handler that has
    /// already begun, so a tick can still be in flight — blocked on the
    /// injector's lock — after the key it belongs to has been released. That
    /// is the race finding #1 is about, and a fake that drops the callback
    /// synchronously cannot reproduce it.
    func cancel() {
        if fire != nil { cancelCount += 1; cancelledFire = fire }
        fire = nil
    }

    /// Simulate `times` repeat ticks.
    func tick(_ times: Int = 1) {
        for _ in 0..<times { fire?() }
    }

    /// Fire a tick that was already in flight when the timer was cancelled.
    func tickAfterCancel() { cancelledFire?() }
}

final class KeyRepeatTests: XCTestCase {

    private func makeController(_ scheduler: FakeRepeatScheduler,
                                delay: TimeInterval = 0.4,
                                interval: TimeInterval = 0.05) -> KeyRepeatController {
        KeyRepeatController(scheduler: scheduler, delay: { delay }, interval: { interval })
    }

    // MARK: - Policy

    func testOrdinaryKeysRepeatAndModifiersNeverDo() {
        XCTAssertTrue(KeyRepeatPolicy.repeats(hidUsage: 0x04))   // A
        XCTAssertTrue(KeyRepeatPolicy.repeats(hidUsage: 0x2A))   // Backspace
        XCTAssertTrue(KeyRepeatPolicy.repeats(hidUsage: 0x4F))   // Right arrow
        XCTAssertTrue(KeyRepeatPolicy.repeats(hidUsage: 0x2C))   // Space

        for modifier in UInt16(0xE0)...UInt16(0xE7) {
            XCTAssertFalse(KeyRepeatPolicy.repeats(hidUsage: modifier),
                           "holding a modifier must not machine-gun flagsChanged")
        }
        XCTAssertFalse(KeyRepeatPolicy.repeats(hidUsage: KeyboardMap.HID.capsLock))
        XCTAssertFalse(KeyRepeatPolicy.repeats(hidUsage: 0x01))  // ErrorRollOver
        XCTAssertFalse(KeyRepeatPolicy.repeats(hidUsage: 0x80),  // Volume Up: no keycode
                       "nothing to re-post without a virtual keycode")
    }

    func testSystemTimingsAreThePlausibleMacOnes() {
        // Sanity, not exactness: the values come from System Settings.
        XCTAssertGreaterThan(SystemKeyRepeat.delay, 0)
        XCTAssertGreaterThan(SystemKeyRepeat.interval, 0)
        XCTAssertGreaterThan(SystemKeyRepeat.delay, SystemKeyRepeat.interval)
    }

    // MARK: - Scheduling

    func testKeyDownSchedulesWithTheSystemDelayAndInterval() {
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler, delay: 0.4, interval: 0.05)

        var fired = 0
        controller.keyDown(hidUsage: 0x04) { fired += 1 }

        XCTAssertEqual(scheduler.startCount, 1)
        XCTAssertEqual(scheduler.lastDelay, 0.4)
        XCTAssertEqual(scheduler.lastInterval, 0.05)
        XCTAssertEqual(controller.repeatingUsage, 0x04)
        XCTAssertEqual(fired, 0, "nothing repeats before the delay elapses")

        scheduler.tick(3)
        XCTAssertEqual(fired, 3)
    }

    func testModifierKeyDownNeverSchedules() {
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler)
        controller.keyDown(hidUsage: 0xE1) { XCTFail("shift must not repeat") }
        XCTAssertEqual(scheduler.startCount, 0)
        XCTAssertNil(controller.repeatingUsage)
    }

    func testKeyUpStopsTheRepeat() {
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler)
        controller.keyDown(hidUsage: 0x04) {}
        controller.keyUp(hidUsage: 0x04)
        XCTAssertEqual(scheduler.cancelCount, 1)
        XCTAssertNil(controller.repeatingUsage)
        XCTAssertFalse(scheduler.isRunning)
    }

    func testReleasingADifferentKeyDoesNotStopTheRepeat() {
        // Hold A, press B (B takes over), release A — B must keep repeating,
        // which is what a real keyboard does.
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler)
        var aFired = 0, bFired = 0
        controller.keyDown(hidUsage: 0x04) { aFired += 1 }
        controller.keyDown(hidUsage: 0x05) { bFired += 1 }
        XCTAssertEqual(controller.repeatingUsage, 0x05)

        controller.keyUp(hidUsage: 0x04)
        XCTAssertEqual(controller.repeatingUsage, 0x05)
        scheduler.tick(2)
        XCTAssertEqual(aFired, 0, "the superseded key stopped repeating")
        XCTAssertEqual(bFired, 2)
    }

    func testLastKeyDownWinsAndCancelsThePrevious() {
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler)
        controller.keyDown(hidUsage: 0x04) {}
        controller.keyDown(hidUsage: 0x05) {}
        XCTAssertEqual(scheduler.startCount, 2)
        XCTAssertEqual(scheduler.cancelCount, 1, "start() cancels the outgoing timer")
    }

    func testResetStopsTheRepeatAndReportsTheHeldKey() {
        let scheduler = FakeRepeatScheduler()
        let controller = makeController(scheduler)
        controller.keyDown(hidUsage: 0x2A) {}
        XCTAssertEqual(controller.reset(), 0x2A, "caller has to post the key-up")
        XCTAssertNil(controller.repeatingUsage)
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertNil(controller.reset(), "idempotent")
    }

    func testDegenerateTimingsRefuseToScheduleRatherThanSpin() {
        let scheduler = FakeRepeatScheduler()
        let controller = KeyRepeatController(scheduler: scheduler, delay: { 0 }, interval: { 0 })
        controller.keyDown(hidUsage: 0x04) { XCTFail("a zero interval must not schedule") }
        XCTAssertEqual(scheduler.startCount, 0)
    }
}
