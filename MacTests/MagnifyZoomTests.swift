import CoreGraphics
import XCTest

/// Pinch-to-zoom as a real macOS magnify gesture.
///
/// The operator's third complaint: "pinch zoom is jerky/laggy from touch and
/// from the trackpad". It was, by construction — round 3 delivered a pinch as
/// ⌘= / ⌘- keystrokes, one per ~15% of accumulated magnification, so the
/// smoothest possible pinch was a staircase and every step was whatever
/// discrete zoom level the app happened to have next.
///
/// There is no public CGEvent constructor for a magnify gesture. What there is
/// — and what Mac Mouse Fix has shipped for years — is a CGEvent whose type is
/// `kCGEventGesture` (29) carrying three undocumented fields. These pin the
/// packing, because it is the kind of thing that fails silently: an event with
/// the wrong field number is simply ignored by the window server, and the
/// symptom is "pinch does nothing" with no error anywhere.
final class MagnifyZoomTests: XCTestCase {

    private var sink: RecordingEventSink!

    private func makeInjector() -> InputInjector {
        sink = RecordingEventSink()
        sink.cursorLocation = CGPoint(x: 512, y: 384)
        return InputInjector(displayID: CGMainDisplayID(), sink: sink, zoomMode: .magnify)
    }

    private func gestures() -> [RecordingEventSink.Recorded] {
        sink.events.filter { $0.gestureType == ODGestureTypeZoom }
    }

    // MARK: - The field packing

    func testTheEventTypeIsTheGestureTypeSwiftCannotName() {
        // `CGEventType(rawValue: 29)` is nil in Swift — the enum has no such
        // case — which is why the cast lives in the bridging header. If this
        // ever comes back as something else, nothing downstream would complain;
        // the gesture would just stop working.
        XCTAssertEqual(ODEventTypeGesture, 29)
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events[0].rawType, ODEventTypeGesture)
    }

    func testTheThreePrivateFieldsAreTheOnesMacMouseFixUses() {
        XCTAssertEqual(ODEventFieldGestureType, 110)
        XCTAssertEqual(ODEventFieldGestureZoomDelta, 113)
        XCTAssertEqual(ODEventFieldGesturePhase, 132)
        XCTAssertEqual(ODGestureTypeZoom, 28)   // kIOHIDEventTypeZoom
    }

    func testThePhaseBitsAreIOHIDEventPhaseBits() {
        XCTAssertEqual(MagnifyGesture.Phase.began.rawValue, 1)
        XCTAssertEqual(MagnifyGesture.Phase.changed.rawValue, 2)
        XCTAssertEqual(MagnifyGesture.Phase.ended.rawValue, 4)
        XCTAssertEqual(MagnifyGesture.Phase.cancelled.rawValue, 8)
    }

    func testTheWirePhasesMapOntoThem() {
        XCTAssertEqual(MagnifyGesture.phase(for: "began"), .began)
        XCTAssertEqual(MagnifyGesture.phase(for: "changed"), .changed)
        XCTAssertEqual(MagnifyGesture.phase(for: "ended"), .ended)
        XCTAssertEqual(MagnifyGesture.phase(for: "cancelled"), .cancelled)
        XCTAssertEqual(MagnifyGesture.phase(for: "who knows"), .changed,
                       "an unknown value inside a known message is not an error")
    }

    // MARK: - Scale to magnification

    func testTheWiresScaleBecomesAppKitsMagnification() {
        // The wire carries an incremental *scale* (1.02 = 2% bigger); AppKit's
        // `NSEvent.magnification` is an incremental *delta* around zero. Off by
        // one and every pinch would zoom to infinity on the first message.
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1.02)!, 0.02, accuracy: 1e-9)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 0.98)!, -0.02, accuracy: 1e-9)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1.0)!, 0, accuracy: 1e-9)
    }

    func testAHostileScaleIsClampedRatherThanPassedOn() {
        // The wire is unauthenticated and AppKit hands this straight to the
        // frontmost app.
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1e300)!,
                       MagnifyGesture.maxMagnificationPerMessage)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1e-300)!,
                       -MagnifyGesture.maxMagnificationPerMessage)
    }

    func testAScaleWithNoMeaningGetsNothing() {
        XCTAssertNil(MagnifyGesture.magnification(fromIncrementalScale: 0))
        XCTAssertNil(MagnifyGesture.magnification(fromIncrementalScale: -1))
        XCTAssertNil(MagnifyGesture.magnification(fromIncrementalScale: .nan))
        XCTAssertNil(MagnifyGesture.magnification(fromIncrementalScale: .infinity))
    }

    func testTheClampIsWellAboveAnyRealPinchStep() {
        // An iPad pinch at 120 Hz reports steps in the 0.001–0.05 range, so the
        // bound must never bite on a real gesture.
        XCTAssertGreaterThan(MagnifyGesture.maxMagnificationPerMessage, 0.1)
    }

    // MARK: - What the injector emits

    func testEveryReceivedMessageBecomesExactlyOneEvent() {
        // This is what "smooth" means mechanically: 120 messages a second in,
        // 120 magnify events out, each carrying a sliver. The keystroke path
        // turned the same 120 messages into two ⌘= presses.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        for _ in 0..<20 { injector.handleZoom(scale: 1.01, phase: "changed") }
        injector.handleZoom(scale: 1, phase: "ended")
        XCTAssertEqual(gestures().count, 22)
        XCTAssertTrue(sink.events.allSatisfy { $0.type != .keyDown && $0.type != .keyUp },
                      "no keystrokes at all on this path")
    }

    func testThePhasesAreBeganThenChangedThenEnded() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.05, phase: "changed")
        injector.handleZoom(scale: 1.05, phase: "changed")
        injector.handleZoom(scale: 1, phase: "ended")
        XCTAssertEqual(gestures().map(\.gesturePhase), [1, 2, 2, 4])
    }

    func testTheBoundariesCarryNoMagnification() {
        // A `began` that also zoomed would put a step into the gesture before
        // the app has had a chance to note where it started.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1, phase: "ended")
        XCTAssertEqual(gestures().map(\.gestureZoom), [0, 0])
    }

    func testThePinchDirectionSurvivesToTheEvent() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.2, phase: "changed")
        injector.handleZoom(scale: 0.9, phase: "changed")
        // The accuracy is 1e-6, not 1e-9: CGEvent stores a "double" field as a
        // 32-bit float internally, so 0.2 comes back as 0.20000000298. Worth
        // knowing about rather than papering over — it is ~1e-8 of relative
        // error on a quantity the eye reads at 1e-2.
        let deltas = gestures().dropFirst().map(\.gestureZoom)
        XCTAssertEqual(deltas.first!, 0.2, accuracy: 1e-6)
        XCTAssertEqual(deltas.last!, -0.1, accuracy: 1e-6)
    }

    func testAZeroDeltaIsStillPosted() {
        // PROTOCOL.md's rule for phased messages, and what keeps the app's own
        // gesture tracking alive through a frame where the fingers did not
        // move. Round 5 also stopped the iPad thresholding these away.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.0, phase: "changed")
        XCTAssertEqual(gestures().count, 2)
    }

    func testTheGestureIsPostedAtTheCursorWhenTheWireCarriesNoCentroid() {
        // AppKit routes a magnify to the window under the event's location; an
        // event carrying wherever `CGEventCreate` happened to put it would zoom
        // whatever is under that. With no centroid on the wire — a receiver
        // older than round 8 — the cursor is the only answer available.
        let injector = makeInjector()
        sink.cursorLocation = CGPoint(x: 900, y: 120)
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")
        XCTAssertTrue(gestures().allSatisfy { $0.location == CGPoint(x: 900, y: 120) })
        XCTAssertTrue(sink.warps.isEmpty, "nothing to warp to")
    }

    // MARK: - Where the pinch lands (round 8)

    /// The round-7 defect, in one test.
    ///
    /// The log said `53 NSEventTypeMagnify events posted at the cursor, net
    /// ×5.647` — correct increments, correctly posted, and nothing zoomed,
    /// because "the cursor" is wherever the Mac's pointer was left and the
    /// user's fingers are somewhere else. Safari only zooms a gesture that
    /// lands over the page.
    func testTheGestureLandsOnThePinchCentroidNotOnTheCursor() {
        let injector = makeInjector()
        sink.cursorLocation = CGPoint(x: 5, y: 5)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let expected = CGPoint(x: bounds.minX + 0.25 * bounds.width,
                               y: bounds.minY + 0.75 * bounds.height)
        injector.handleZoom(scale: 1, phase: "began", x: 0.25, y: 0.75)
        injector.handleZoom(scale: 1.02, phase: "changed", x: 0.25, y: 0.75)
        XCTAssertTrue(gestures().allSatisfy { $0.location == expected },
                      "every event of the gesture goes to the centroid")
    }

    func testTheCursorIsWarpedToTheCentroidExactlyOncePerGesture() {
        // The same rule the two-finger scroll follows: a real trackpad does not
        // drag the cursor while a gesture runs, and re-warping per sample would
        // retarget the gesture halfway through — as well as being 120 warps a
        // second.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began", x: 0.5, y: 0.5)
        for _ in 0..<20 { injector.handleZoom(scale: 1.01, phase: "changed", x: 0.6, y: 0.4) }
        injector.handleZoom(scale: 1, phase: "ended", x: 0.6, y: 0.4)
        XCTAssertEqual(sink.warps.count, 1)
    }

    func testTheWholeGestureStaysAtTheAnchorEvenAsTheFingersDrift() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began", x: 0.5, y: 0.5)
        injector.handleZoom(scale: 1.01, phase: "changed", x: 0.9, y: 0.1)
        let points = Set(gestures().map(\.location))
        XCTAssertEqual(points.count, 1, "one gesture, one target")
    }

    func testANewGestureTakesANewAnchor() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began", x: 0.2, y: 0.2)
        injector.handleZoom(scale: 1, phase: "ended", x: 0.2, y: 0.2)
        injector.handleZoom(scale: 1, phase: "began", x: 0.8, y: 0.8)
        XCTAssertEqual(sink.warps.count, 2)
        XCTAssertNotEqual(sink.warps[0], sink.warps[1])
    }

    func testAnOrphanChangedStillAnchorsOnItsCentroid() {
        // A `began` lost on the wire, or a session adopted mid-pinch.
        let injector = makeInjector()
        sink.cursorLocation = CGPoint(x: 5, y: 5)
        injector.handleZoom(scale: 1.05, phase: "changed", x: 0.5, y: 0.5)
        XCTAssertEqual(sink.warps.count, 1)
        XCTAssertTrue(gestures().allSatisfy { $0.location == sink.warps[0] })
    }

    func testHalfACoordinateIsNotAPoint() {
        // The dispatch in MacSender refuses `x` without `y`; assert the
        // injector's own contract as well, because an anchor built from one
        // real coordinate and one guess is worse than the cursor.
        XCTAssertNil(WireInput.normalizedCoordinate(nil))
        XCTAssertNil(WireInput.normalizedCoordinate("0.5"))
        XCTAssertNil(WireInput.normalizedCoordinate(Double.nan))
        XCTAssertEqual(WireInput.normalizedCoordinate(0.5), 0.5)
        XCTAssertEqual(WireInput.normalizedCoordinate(-0.02), 0)
        XCTAssertEqual(WireInput.normalizedCoordinate(1.04), 1)
    }

    // MARK: - A cancelled pinch ends cleanly (round 8)

    func testACancelledPinchIsPostedAsEnded() {
        // The iPad cancels a pinch when another recognizer takes the fingers,
        // and round 7 forwarded that as `kIOHIDEventPhaseCancelled` — the phase
        // an application is least likely to have a branch for, and the cost of
        // it not having one is a gesture series left open for the session.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began", x: 0.5, y: 0.5)
        injector.handleZoom(scale: 1.01, phase: "changed", x: 0.5, y: 0.5)
        injector.handleZoom(scale: 1, phase: "cancelled", x: 0.5, y: 0.5)
        XCTAssertEqual(gestures().map(\.gesturePhase), [1, 2, 4])
    }

    func testNoGestureThisInjectorPostsEverCarriesTheCancelledPhase() {
        let injector = makeInjector()
        for phase in ["began", "changed", "cancelled", "began", "changed", "began", "ended"] {
            injector.handleZoom(scale: 1.01, phase: phase, x: 0.4, y: 0.4)
        }
        injector.reset()
        XCTAssertFalse(gestures().contains { $0.gesturePhase == MagnifyGesture.Phase.cancelled.rawValue })
        XCTAssertEqual(gestures().filter { $0.gesturePhase == 1 }.count,
                       gestures().filter { $0.gesturePhase == 4 }.count,
                       "still exactly one end per begin")
    }

    func testAChangedWithoutABeganOpensTheGestureFirst() {
        // A message lost, or a session adopted mid-pinch: the app under the
        // cursor still has to see a well-formed gesture.
        let injector = makeInjector()
        injector.handleZoom(scale: 1.05, phase: "changed")
        XCTAssertEqual(gestures().map(\.gesturePhase), [1, 2])
    }

    func testASecondBeganClosesTheFirstGesture() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1, phase: "began")
        XCTAssertEqual(gestures().map(\.gesturePhase), [1, 4, 1],
                       "the orphan is ended, not left open")
    }

    func testAStrayEndWithoutABeganSendsNothing() {
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "ended")
        XCTAssertTrue(gestures().isEmpty)
    }

    func testResetClosesAnOpenGesture() {
        // The zoom equivalent of a mouse button left down: a magnify left open
        // has the frontmost app believing two fingers are still on a trackpad,
        // and nothing on the iPad can undo it.
        let injector = makeInjector()
        injector.handleZoom(scale: 1, phase: "began")
        injector.handleZoom(scale: 1.1, phase: "changed")
        sink.reset()
        injector.reset()
        XCTAssertEqual(gestures().map(\.gesturePhase), [4],
                       "a reset ends the gesture — see lockedEndMagnify")
    }

    func testResetWithNoGestureRunningSendsNothing() {
        let injector = makeInjector()
        injector.reset()
        XCTAssertTrue(gestures().isEmpty)
    }

    func testEveryGestureIsBalanced() {
        // The invariant, over a hostile sequence: as many opens as closes.
        let injector = makeInjector()
        let phases = ["began", "changed", "changed", "ended", "changed", "began",
                      "cancelled", "ended", "began", "changed"]
        for phase in phases { injector.handleZoom(scale: 1.01, phase: phase) }
        injector.reset()
        let opens = gestures().filter { $0.gesturePhase == 1 }.count
        let closes = gestures().filter { $0.gesturePhase == 4 || $0.gesturePhase == 8 }.count
        XCTAssertEqual(opens, closes, "a magnify left open is a stuck gesture")
    }

    // MARK: - The setting

    func testTheKeystrokePathIsTheDefaultBecauseMagnifyCannotBeProvenToWork() {
        // Changed in round 8, and the argument is in `MagnifySelfTest`: a
        // synthesised gesture is delivered to AppKit as `NSEventTypeGesture`,
        // never as `NSEventTypeMagnify`, and no CGEvent field can carry the
        // magnification a magnify would need. A steppy ⌘=/⌘- that works beats
        // a smooth gesture that does nothing.
        XCTAssertEqual(ZoomMode.forkDefault, .keys)
        XCTAssertEqual(ZoomMode.resolve(nil), .keys)
    }

    func testTheMagnifyPathIsOneDefaultsWriteAway() {
        XCTAssertEqual(ZoomMode.resolve("magnify"), .magnify)
        XCTAssertEqual(ZoomMode.defaultsKey, "zoomMode")
    }

    func testAnUnrecognisedValueFallsBackRatherThanDisablingZoom() {
        XCTAssertEqual(ZoomMode.resolve("Magnify"), .keys)
        XCTAssertEqual(ZoomMode.resolve(42), .keys)
    }

    func testTheTwoModesShareNothing() {
        // A keys-mode injector must produce keystrokes and no gestures; a
        // magnify-mode injector the reverse. Mixing them would double-zoom.
        let keys = RecordingEventSink()
        let keyInjector = InputInjector(displayID: CGMainDisplayID(), sink: keys, zoomMode: .keys)
        keyInjector.handleZoom(scale: 1, phase: "began")
        keyInjector.handleZoom(scale: 1.5, phase: "changed")
        XCTAssertTrue(keys.events.allSatisfy { $0.rawType != ODEventTypeGesture })
        XCTAssertFalse(keys.events.isEmpty)
    }
}
