import CoreGraphics
import XCTest

/// Multi-click chains, against an injected clock and injected thresholds.
///
/// The merged suites claimed to cover "multi-click timing" and asserted
/// nothing about it, because the real thresholds come from the tester's System
/// Settings and the real clock is wall-clock time. With `ClickMetricsProviding`
/// swapped out, the interval, the slop distance and "now" are all ours.
final class ClickTimingTests: XCTestCase {

    /// Controllable double-click thresholds and clock.
    final class FakeClickMetrics: ClickMetricsProviding {
        var doubleClickInterval: TimeInterval = 0.5
        var doubleClickDistance: CGFloat = 4
        /// Stored rather than defaulted, so a test can put the *mouse*
        /// threshold back and pin what it used to do to a double tap.
        var touchDoubleClickDistance: CGFloat = TouchClick.doubleClickDistance
        var now: CFAbsoluteTime = 1_000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    /// A normalized x offset worth `points` global desktop points.
    private func offset(points: Double) -> Double {
        points / Double(CGDisplayBounds(CGMainDisplayID()).width)
    }

    private var sink: RecordingEventSink!
    private var metrics: FakeClickMetrics!

    private func makeInjector() -> InputInjector {
        sink = RecordingEventSink()
        metrics = FakeClickMetrics()
        return InputInjector(displayID: CGMainDisplayID(), sink: sink, metrics: metrics)
    }

    /// Click states of the down events, in order.
    private var downClickStates: [Int64] {
        sink.events
            .filter { $0.type == .leftMouseDown || $0.type == .rightMouseDown }
            .map(\.clickState)
    }

    private func click(_ injector: InputInjector, x: Double, y: Double,
                       button: String = "left") {
        injector.handleTouch(phase: "began", x: x, y: y, button: button)
        injector.handleTouch(phase: "ended", x: x, y: y, button: button)
    }

    func testTwoQuickClicksAtTheSamePointAreADoubleClick() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.1)
        click(injector, x: 0.5, y: 0.5)
        XCTAssertEqual(downClickStates, [1, 2])
    }

    func testAThirdClickContinuesTheChain() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.1)
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.1)
        click(injector, x: 0.5, y: 0.5)
        XCTAssertEqual(downClickStates, [1, 2, 3])
    }

    func testAClickAfterTheIntervalStartsOver() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(metrics.doubleClickInterval + 0.01)
        click(injector, x: 0.5, y: 0.5)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testAClickTooFarAwayStartsOver() {
        let injector = makeInjector()
        metrics.doubleClickDistance = 4
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.1)
        click(injector, x: 0.9, y: 0.9)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testTheChainIsPerButton() {
        // A right click followed quickly by a left click at the same place is
        // two single clicks. Sharing one history gave the left down a click
        // state of 2, i.e. a phantom double click.
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5, button: "right")
        metrics.advance(0.1)
        click(injector, x: 0.5, y: 0.5, button: "left")
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testEachButtonKeepsItsOwnChain() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5, button: "right")
        metrics.advance(0.05)
        click(injector, x: 0.5, y: 0.5, button: "left")
        metrics.advance(0.05)
        click(injector, x: 0.5, y: 0.5, button: "right")
        XCTAssertEqual(downClickStates, [1, 1, 2], "the right chain survived the left click")
    }

    func testACancelDropsTheChain() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.05)
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        injector.handleTouch(phase: "cancelled", x: 0.5, y: 0.5)
        metrics.advance(0.05)
        click(injector, x: 0.5, y: 0.5)
        XCTAssertEqual(downClickStates, [1, 2, 1],
                       "a cancelled press must not seed the next click")
    }

    func testAResetDropsTheChain() {
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        injector.reset()
        metrics.advance(0.05)
        click(injector, x: 0.5, y: 0.5)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testADragBeyondTheSlopDoesNotSeedADoubleClick() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        injector.handleTouch(phase: "moved", x: 0.9, y: 0.9)
        injector.handleTouch(phase: "ended", x: 0.9, y: 0.9)
        metrics.advance(0.05)
        click(injector, x: 0.9, y: 0.9)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testAnOverlappingPressIsCancelledNotCompleted() {
        // A finger press and a trackpad secondary press overlap. The finger's
        // button must be released — with click state 0, so nothing synthesises
        // a click out of it — before the new press is accepted.
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.2, y: 0.2)             // finger, left
        sink.reset()
        injector.handleTouch(phase: "began", x: 0.6, y: 0.6, button: "right")

        XCTAssertEqual(sink.events.map(\.type), [.leftMouseUp, .rightMouseDown])
        XCTAssertEqual(sink.events.first?.clickState, 0)
        XCTAssertTrue(injector.isDown)

        // …and the release belongs to the button that is actually held.
        sink.reset()
        injector.handleTouch(phase: "ended", x: 0.6, y: 0.6)
        XCTAssertEqual(sink.events.map(\.type), [.rightMouseUp])
        XCTAssertFalse(injector.isDown)
    }

    // MARK: - A fingertip is not a mouse (double tap on the glass)

    func testASecondTapAFingertipAwayStillDoubleClicks() {
        // The reported failure: a deliberate double tap on the iPad arrived as
        // two single clicks. Two taps 250 ms apart and 8 points apart is an
        // ordinary double tap from a fingertip — a fingertip is ~40 points
        // wide and is lifted clear of the glass between the two.
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.25)
        click(injector, x: 0.5 + offset(points: 8), y: 0.5)
        XCTAssertEqual(downClickStates, [1, 2])
    }

    func testTheMouseThresholdIsWhatMissedIt() {
        // The regression, pinned: with the system (mouse) slop the same pair
        // of taps is two separate clicks. `NSDoubleClickDistance` does not
        // resolve through dlsym on macOS 26, so that slop was the 4 pt
        // fallback on the machine this fork runs on.
        let injector = makeInjector()
        metrics.touchDoubleClickDistance = metrics.doubleClickDistance   // 4
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.25)
        click(injector, x: 0.5 + offset(points: 8), y: 0.5)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testTapsAPalmApartAreStillTwoClicks() {
        // The slop is a fingertip's worth, not "anywhere on the screen".
        let injector = makeInjector()
        click(injector, x: 0.5, y: 0.5)
        metrics.advance(0.25)
        click(injector, x: 0.5 + offset(points: 60), y: 0.5)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testTheFingerSlopIsNeverTighterThanTheSystemSays() {
        // A user who widened the mouse threshold has said something; a finger
        // must not be held to a stricter rule than a mouse.
        XCTAssertEqual(SystemClickMetrics().touchDoubleClickDistance,
                       max(SystemClickMetrics().doubleClickDistance,
                           TouchClick.doubleClickDistance))
        struct Wide: ClickMetricsProviding {
            var doubleClickInterval: TimeInterval = 0.5
            var doubleClickDistance: CGFloat = 40
            var now: CFAbsoluteTime = 0
        }
        XCTAssertEqual(Wide().touchDoubleClickDistance, 40)
    }

    func testThePencilKeepsThePreciseThreshold() {
        // A pen has a tip. A spurious double click from a 12 pt slop is worse
        // than a missed one, so the pen chain still reads the system value.
        let injector = makeInjector()
        let drift = offset(points: 8)
        injector.handlePencil(phase: "down", x: 0.5, y: 0.5, pressure: 0.6,
                              azimuth: 0, altitude: 0.5, rotation: 0)
        injector.handlePencil(phase: "up", x: 0.5, y: 0.5, pressure: 0,
                              azimuth: 0, altitude: 0.5, rotation: 0)
        metrics.advance(0.25)
        injector.handlePencil(phase: "down", x: 0.5 + drift, y: 0.5, pressure: 0.6,
                              azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertEqual(downClickStates, [1, 1])
    }

    func testPencilResetCancelsTheContactInsteadOfCompletingTheClick() {
        let injector = makeInjector()
        injector.handlePencil(phase: "down", x: 0.3, y: 0.3, pressure: 0.6,
                              azimuth: 0, altitude: 0.5, rotation: 0)
        sink.reset()

        injector.reset()

        let up = sink.events.first { $0.type == .leftMouseUp }
        XCTAssertNotNil(up, "the contact is released")
        XCTAssertEqual(up?.clickState, 0,
                       "an interrupted stroke must not be completed as a click")
        XCTAssertFalse(injector.penDown)
        XCTAssertFalse(injector.inRange)
    }
}

/// Range checks on the peer-supplied numbers that reach the injector.
final class WireInputTests: XCTestCase {

    func testHidUsageAcceptsTheWholeUnsignedRange() {
        XCTAssertEqual(WireInput.hidUsage(0), 0)
        XCTAssertEqual(WireInput.hidUsage(0x04), 0x04)
        XCTAssertEqual(WireInput.hidUsage(65535), 65535)
    }

    func testHidUsageRejectsOutOfRangeInsteadOfTrapping() {
        // `UInt16(-1)` and `UInt16(65536)` both trap. The wire is
        // unauthenticated, so a trap here is a remote crash of the sender.
        XCTAssertNil(WireInput.hidUsage(-1))
        XCTAssertNil(WireInput.hidUsage(65536))
        XCTAssertNil(WireInput.hidUsage(Int.min))
        XCTAssertNil(WireInput.hidUsage(Int.max))
    }

    func testModifierMaskDegradesToNoModifiers() {
        XCTAssertEqual(WireInput.modifierMask(nil), 0)
        XCTAssertEqual(WireInput.modifierMask(-5), 0)
        XCTAssertEqual(WireInput.modifierMask(Int(KeyboardMap.uiShift)), KeyboardMap.uiShift)
    }

    func testModifierMaskKeepsOnlyDefinedBits() {
        let smuggled = Int(KeyboardMap.uiCommand) | (1 << 40)
        XCTAssertEqual(WireInput.modifierMask(smuggled), KeyboardMap.uiCommand)
    }

    func testStickyFlagsIgnoreNonsenseRatherThanGuess() {
        XCTAssertNil(WireInput.stickyFlags(-1))
        XCTAssertEqual(WireInput.stickyFlags(Int(KeyboardMap.uiCommand)), KeyboardMap.uiCommand)
        XCTAssertEqual(WireInput.stickyFlags(1 << 40), 0, "unknown bits are dropped, not latched")
    }
}
