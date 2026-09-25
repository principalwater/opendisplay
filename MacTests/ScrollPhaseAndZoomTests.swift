import CoreGraphics
import XCTest

/// Native touch mode's two additions to the wire: `scroll.phase` and `zoom`.
///
/// Both are additive, which is the property most worth pinning — a sender that
/// knows nothing about either must keep producing exactly the events it always
/// produced, and this suite is what says so.
final class ScrollPhaseAndZoomTests: XCTestCase {

    private var sink: RecordingEventSink!

    private func makeInjector() -> InputInjector {
        sink = RecordingEventSink()
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: sink)
        // Pin the pixel scale so scroll deltas are predictable regardless of
        // the machine running the suite.
        injector.setEncodedSize(pixelsWide: Int(CGDisplayBounds(CGMainDisplayID()).width) * 2,
                                pixelsHigh: Int(CGDisplayBounds(CGMainDisplayID()).height) * 2)
        return injector
    }

    // MARK: - The phase mapping

    func testTheWirePhasesMapOntoTheTwoCGEventFields() {
        // The split is the substance: `scrollPhase` means a finger is on the
        // glass, `momentumPhase` means the content is coasting, and they are
        // never both non-zero. Getting them confused gives macOS a scroll that
        // never ends, which leaves scroll bars up and rubber-banding stuck.
        let expected: [(ScrollPhase, Int64, Int64)] = [
            (.began, 1, 0),
            (.changed, 2, 0),
            (.ended, 4, 0),
            (.momentumBegan, 0, 1),
            (.momentumChanged, 0, 2),
            (.momentumEnded, 0, 3),
        ]
        for (phase, scroll, momentum) in expected {
            XCTAssertEqual(phase.scrollPhaseValue, scroll, "\(phase) scroll phase")
            XCTAssertEqual(phase.momentumPhaseValue, momentum, "\(phase) momentum phase")
            XCTAssertFalse(phase.scrollPhaseValue != 0 && phase.momentumPhaseValue != 0,
                           "\(phase) must not claim both")
        }
    }

    func testEveryPhaseIsCovered() {
        // A new case added without a mapping would otherwise silently answer 0.
        XCTAssertEqual(ScrollPhase.allCases.count, 6)
        XCTAssertEqual(ScrollPhase.allCases.filter(\.isFingerDown), [.began, .changed])
    }

    func testAScrollWithAPhaseCarriesItOntoTheEvent() {
        let injector = makeInjector()
        injector.handleScroll(dx: 0, dy: 0, phase: .began)
        injector.handleScroll(dx: 0, dy: 40, phase: .changed)
        injector.handleScroll(dx: 0, dy: 0, phase: .ended)

        XCTAssertEqual(sink.events.count, 3)
        XCTAssertEqual(sink.events.map(\.scrollPhase), [1, 2, 4])
        XCTAssertEqual(sink.events.map(\.momentumPhase), [0, 0, 0])
        XCTAssertTrue(sink.events.allSatisfy { $0.type == .scrollWheel })
    }

    func testAMomentumRunCarriesTheMomentumFieldInstead() {
        let injector = makeInjector()
        injector.handleScroll(dx: 0, dy: 0, phase: .momentumBegan)
        injector.handleScroll(dx: 0, dy: 12, phase: .momentumChanged)
        injector.handleScroll(dx: 0, dy: 0, phase: .momentumEnded)

        XCTAssertEqual(sink.events.map(\.scrollPhase), [0, 0, 0])
        XCTAssertEqual(sink.events.map(\.momentumPhase), [1, 2, 3])
    }

    func testAPhaselessScrollIsUnchangedFromBeforeTheFieldExisted() {
        // Trackpad-style mode and every sender in the field send no phase. Both
        // fields must stay 0, which is macOS's own "this was not a gesture".
        let injector = makeInjector()
        injector.handleScroll(dx: 10, dy: 20)

        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.scrollPhase, 0)
        XCTAssertEqual(sink.events.first?.momentumPhase, 0)
        XCTAssertNotEqual(sink.events.first?.scrollAxis1, 0, "the deltas still go through")
    }

    func testAZeroDeltaPhaseMessageIsStillPosted() {
        // `began`, `ended` and `momentumEnded` carry no movement; dropping them
        // as "nothing to scroll" would lose the phase they exist to deliver.
        let injector = makeInjector()
        injector.handleScroll(dx: 0, dy: 0, phase: .ended)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.scrollPhase, 4)
    }

    // MARK: - Parsing what arrives on the wire

    func testKnownPhaseNamesParse() {
        for phase in ScrollPhase.allCases {
            XCTAssertEqual(WireInput.scrollPhase(phase.rawValue), phase)
        }
    }

    func testUnknownOrAbsentPhaseDegradesToNoPhase() {
        // Additive in both directions: a phase name from a future receiver must
        // leave the scroll working, not drop it.
        XCTAssertNil(WireInput.scrollPhase(nil))
        XCTAssertNil(WireInput.scrollPhase("hovering"))
        XCTAssertNil(WireInput.scrollPhase(4))
        XCTAssertNil(WireInput.scrollPhase(["began"]))
    }

    func testZoomScaleRejectsWhatHasNoLogarithm() {
        XCTAssertEqual(WireInput.zoomScale(1.5), 1.5)
        XCTAssertNil(WireInput.zoomScale(0))
        XCTAssertNil(WireInput.zoomScale(-1))
        XCTAssertNil(WireInput.zoomScale(Double.nan))
        XCTAssertNil(WireInput.zoomScale(Double.infinity))
        XCTAssertNil(WireInput.zoomScale("2"))
        XCTAssertNil(WireInput.zoomScale(nil))
    }

    // MARK: - Zoom, the keystroke fallback (`zoomMode keys`)
    //
    // Round 5 made a real magnify gesture the default (see
    // `MagnifyZoomTests`), but the keystroke path stays as the public-API
    // fallback and everything it promised still has to hold. These build their
    // injector with `zoomMode: .keys` explicitly rather than inheriting the
    // machine's defaults, which is also what stops the suite depending on what
    // the tester happens to have written to `zoomMode`.

    private func makeKeyZoomInjector() -> InputInjector {
        sink = RecordingEventSink()
        return InputInjector(displayID: CGMainDisplayID(), sink: sink, zoomMode: .keys)
    }

    /// ⌘= is keycode 0x18, ⌘- is 0x1B.
    private func zoomKeys(_ events: [RecordingEventSink.Recorded]) -> [(CGKeyCode, Bool)] {
        events.filter { $0.type == .keyDown || $0.type == .keyUp }
            .map { ($0.keyCode, $0.type == .keyDown) }
    }

    func testASmallPinchPostsNothingUntilItCrossesAStep() {
        // A two-finger twitch must not resize the user's document.
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.01, phase: "changed")
        injector.handleZoom(scale: 1.01, phase: "changed")
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testPinchingOutPostsCommandEquals() {
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.2, phase: "changed")   // log2 1.2 = 0.263 > 0.2

        XCTAssertEqual(zoomKeys(sink.events).map(\.0), [0x18, 0x18])
        XCTAssertEqual(zoomKeys(sink.events).map(\.1), [true, false])
        XCTAssertTrue(sink.events.allSatisfy { $0.flags.contains(.maskCommand) })
    }

    func testPinchingInPostsCommandMinus() {
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 0.8, phase: "changed")   // log2 0.8 = -0.32

        XCTAssertEqual(zoomKeys(sink.events).map(\.0), [0x1B, 0x1B])
    }

    func testAccumulationIsMultiplicativeSoAPinchBackIsANoOp() {
        // Summing raw scale factors would make 2x then 0.5x add up to 1.5 and
        // leave a phantom step owing; log2 makes them cancel.
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")
        injector.handleZoom(scale: 1 / 1.1, phase: "changed")
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testSmallStepsAccumulateIntoOneKeystroke() {
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        for _ in 0..<10 { injector.handleZoom(scale: 1.03, phase: "changed") }
        // log2(1.03) = 0.0426; ten of them is 0.426, i.e. two steps of 0.2.
        XCTAssertEqual(zoomKeys(sink.events).count, 4)
        XCTAssertTrue(zoomKeys(sink.events).allSatisfy { $0.0 == 0x18 })
    }

    func testAnAbsurdScaleCannotAskForUnboundedKeystrokes() {
        // The wire is unauthenticated: one message must not be able to fire a
        // thousand keystrokes at the user's desktop.
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1e300, phase: "changed")
        XCTAssertEqual(zoomKeys(sink.events).count, 16, "8 steps, down+up each")
    }

    func testTheAccumulatorDoesNotLeakBetweenGestures() {
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")   // 0.137, below a step
        injector.handleZoom(scale: 1, phase: "ended")
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")   // 0.137 again
        XCTAssertTrue(sink.events.isEmpty, "the two gestures must not add up")
    }

    func testResetDropsAPartialZoom() {
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")
        injector.reset()
        sink.reset()
        injector.handleZoom(scale: 1.1, phase: "changed")
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testAZoomPostsNoMouseEventAndHoldsNoKey() {
        // The zoom keystrokes must not join `heldKeys`: a reset after a pinch
        // would otherwise "release" a key that was never held.
        let injector = makeKeyZoomInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.5, phase: "changed")
        sink.reset()
        injector.reset()
        XCTAssertTrue(sink.events.isEmpty, "reset released something a pinch left behind")
    }
}
