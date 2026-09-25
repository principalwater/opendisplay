import CoreGraphics
import XCTest

/// Touch-and-hold, and what it becomes.
///
/// The operator's report was "hold+move DRAG does not work". Two things could
/// produce that and only one of them is in this file: the hold never
/// committing (arbitration — `MomentumBrakeTests` below and
/// `gestureRecognizerShouldBegin` on the view), or the committed hold never
/// turning into a drag. These pin the second.
final class HoldDragMachineTests: XCTestCase {

    private func machine() -> HoldDragMachine { HoldDragMachine(commitSlop: 8) }

    func testCommittingAHoldSendsNothing() {
        var m = machine()
        XCTAssertEqual(m.begin(at: CGPoint(x: 100, y: 100)), .nothing)
        XCTAssertTrue(m.isActive)
        XCTAssertFalse(m.isDragging)
    }

    func testMovementInsideTheSlopIsStillDeciding() {
        var m = machine()
        _ = m.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(m.move(to: CGPoint(x: 104, y: 103)), .nothing)
        XCTAssertEqual(m.move(to: CGPoint(x: 100, y: 108)), .nothing, "exactly the slop is not past it")
        XCTAssertFalse(m.isDragging)
    }

    func testPastTheSlopThePressLandsWhereTheFingerWasHeld() {
        // On iPadOS the thing you pick up is the thing you were pressing.
        // Starting the drag where the slop was crossed grabs its neighbour.
        var m = machine()
        _ = m.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(m.move(to: CGPoint(x: 120, y: 100)),
                       .dragBegan(at: CGPoint(x: 100, y: 100), movedTo: CGPoint(x: 120, y: 100)))
        XCTAssertTrue(m.isDragging)
    }

    func testMovementAfterTheCommitIsNotClampedByAnySlop() {
        // UIKit stops applying `allowableMovement` once a long press has
        // begun: every later sample arrives as `.changed`, unclamped, however
        // far the finger has travelled. This is our half of that contract —
        // a drag must keep tracking to the far side of the screen.
        var m = machine()
        _ = m.begin(at: .zero)
        _ = m.move(to: CGPoint(x: 20, y: 0))
        XCTAssertEqual(m.move(to: CGPoint(x: 900, y: 700)), .dragMoved(to: CGPoint(x: 900, y: 700)))
        XCTAssertEqual(m.move(to: CGPoint(x: -400, y: -300)), .dragMoved(to: CGPoint(x: -400, y: -300)))
        XCTAssertTrue(m.isDragging)
    }

    func testTheDragIsReleasedWhereTheFingerLifted() {
        var m = machine()
        _ = m.begin(at: CGPoint(x: 10, y: 10))
        _ = m.move(to: CGPoint(x: 200, y: 10))
        XCTAssertEqual(m.end(at: CGPoint(x: 210, y: 12), cancelled: false),
                       .dragEnded(at: CGPoint(x: 210, y: 12), cancelled: false))
        XCTAssertFalse(m.isActive)
    }

    func testACancelledDragIsStillReleased() {
        // A mouse button left down on the Mac is the one failure this code can
        // cause that the user cannot undo from the iPad.
        var m = machine()
        _ = m.begin(at: CGPoint(x: 10, y: 10))
        _ = m.move(to: CGPoint(x: 200, y: 10))
        XCTAssertEqual(m.end(cancelled: true),
                       .dragEnded(at: CGPoint(x: 200, y: 10), cancelled: true),
                       "no release point given: the last one the finger was seen at")
    }

    func testAHoldReleasedInPlaceIsTheContextMenu() {
        var m = machine()
        _ = m.begin(at: CGPoint(x: 42, y: 99))
        _ = m.move(to: CGPoint(x: 45, y: 99))
        XCTAssertEqual(m.end(at: CGPoint(x: 45, y: 99), cancelled: false),
                       .rightClick(at: CGPoint(x: 42, y: 99)),
                       "the menu opens where the finger was held, not where it drifted to")
    }

    func testAHoldCancelledInPlaceSendsNothingAtAll() {
        // No button was ever pressed, so there is nothing to release — and a
        // context menu nobody asked for is worse than no menu.
        var m = machine()
        _ = m.begin(at: CGPoint(x: 42, y: 99))
        XCTAssertEqual(m.end(cancelled: true), .nothing)
        XCTAssertFalse(m.isActive)
    }

    func testEndingTwiceReleasesOnlyOnce() {
        var m = machine()
        _ = m.begin(at: .zero)
        _ = m.move(to: CGPoint(x: 100, y: 0))
        XCTAssertEqual(m.end(cancelled: false), .dragEnded(at: CGPoint(x: 100, y: 0), cancelled: false))
        XCTAssertEqual(m.end(cancelled: false), .nothing, "a second release would be a phantom click")
        XCTAssertEqual(m.end(cancelled: true), .nothing)
    }

    func testMovingWithoutAHoldDoesNothing() {
        var m = machine()
        XCTAssertEqual(m.move(to: CGPoint(x: 500, y: 500)), .nothing)
        XCTAssertEqual(m.end(cancelled: false), .nothing)
    }

    func testEveryDragBeganIsFollowedByExactlyOneRelease() {
        // The invariant, walked over a realistic sequence.
        var m = machine()
        var opened = 0
        var closed = 0
        for round in 0..<20 {
            for emission in [m.begin(at: CGPoint(x: 10, y: 10)),
                             m.move(to: CGPoint(x: 12, y: 10)),
                             m.move(to: CGPoint(x: 60, y: 10)),
                             m.move(to: CGPoint(x: 90, y: 40)),
                             m.end(cancelled: round.isMultiple(of: 2))] {
                if case .dragBegan = emission { opened += 1 }
                if case .dragEnded = emission { closed += 1 }
            }
        }
        XCTAssertEqual(opened, 20)
        XCTAssertEqual(closed, opened)
    }

    func testTheCommitSlopIsItsOwnConstant() {
        // Separate from the long press's `allowableMovement` even where the
        // numbers agree: one decides "is this a hold", the other "has the hold
        // become a drag", and UIKit stops applying the first at `.began`.
        XCTAssertEqual(HoldDragMachine.defaultCommitSlop, 8)
        var tight = HoldDragMachine(commitSlop: 2)
        _ = tight.begin(at: .zero)
        XCTAssertEqual(tight.move(to: CGPoint(x: 4, y: 0)),
                       .dragBegan(at: .zero, movedTo: CGPoint(x: 4, y: 0)))
    }
}

/// The touch that stops a coast is a brake.
///
/// This is the rule that took drag and double tap away. A flick leaves the
/// momentum display link running for up to ~2 s; every touch in that window
/// was marked spent, and *both* the tap and the long press were refused for
/// it. So after any flick: no click, no context menu, and — because the drag
/// only exists downstream of the hold — no drag either. Scrolling and pinching
/// kept working, which is exactly the shape of the report.
final class MomentumBrakeTests: XCTestCase {

    func testABrakingTouchMayNotClick() {
        XCTAssertFalse(MomentumBrake.allows(.tap, braking: true))
    }

    func testABrakingTouchMayStillScroll() {
        // Brake, then keep the finger down and drag to scroll, in one motion —
        // exactly what `UIScrollView` does with its own deceleration.
        XCTAssertTrue(MomentumBrake.allows(.pan, braking: true))
    }

    func testABrakingTouchMayStillBeHeld() {
        // The regression. Press-and-hold on a decelerating list in Photos does
        // pick the photo up: the deliberate 0.4 s press is itself the proof
        // that the user is not just braking.
        XCTAssertTrue(MomentumBrake.allows(.longPress, braking: true))
    }

    func testABrakingTouchMayStillPinch() {
        XCTAssertTrue(MomentumBrake.allows(.pinch, braking: true))
    }

    func testWithNoCoastRunningEverythingIsAllowed() {
        for recognizer in NativeRecognizer.allCases {
            XCTAssertTrue(MomentumBrake.allows(recognizer, braking: false))
        }
    }

    func testTheTapIsTheOnlyThingEverRefused() {
        let refused = NativeRecognizer.allCases.filter { !MomentumBrake.allows($0, braking: true) }
        XCTAssertEqual(refused, [.tap])
    }
}

// MARK: - Round 5: how long the coast runs, and what it costs

/// The momentum brake, re-derived from the iPad's own log.
///
/// Round 4's rule was "a coast is running, so this touch is a brake". The
/// round-4 test log says what that cost: 16 taps in the session, 8 sequences
/// that braked a coast, 2 taps refused outright. Roughly a third of the
/// operator's taps were swallowed — which reads as "the iPad ignores me", not
/// as "the list stopped".
final class MomentumBrakeSpeedTests: XCTestCase {

    func testAFastCoastStillSwallowsTheTap() {
        // The case the rule exists for: content moving under the finger, and a
        // tap that would land on whatever slid into place.
        XCTAssertTrue(MomentumBrake.swallowsTap(coastSpeed: 900))
        XCTAssertTrue(MomentumBrake.swallowsTap(coastSpeed: 81))
    }

    func testACoastThatHasDecayedToACrawlDoesNot() {
        // Below ~80 pt/s the content is effectively parked: the finger lands on
        // what the eye picked, and swallowing the click is pure loss.
        XCTAssertFalse(MomentumBrake.swallowsTap(coastSpeed: 79))
        XCTAssertFalse(MomentumBrake.swallowsTap(coastSpeed: 45))
        XCTAssertFalse(MomentumBrake.swallowsTap(coastSpeed: 0))
    }

    func testTheThresholdIsWellAboveTheStopSpeed() {
        // Otherwise the window in which a tap is refused would be the whole
        // coast again, which is the bug.
        XCTAssertGreaterThan(MomentumBrake.visibleCoastSpeed, ScrollMomentum.stopSpeed)
    }

    func testABrakedSequenceStillPansHoldsAndPinches() {
        // Unchanged from round 4, and the fix that made drag work at all.
        XCTAssertTrue(MomentumBrake.allows(.pan, braking: true))
        XCTAssertTrue(MomentumBrake.allows(.longPress, braking: true))
        XCTAssertTrue(MomentumBrake.allows(.pinch, braking: true))
        XCTAssertFalse(MomentumBrake.allows(.tap, braking: true))
    }
}

/// How long a flick keeps moving, which is how long the brake can be armed.
final class ScrollMomentumTests: XCTestCase {

    func testAHardFlickCoastsForAboutASecondAndAHalf() {
        // Round 4 stopped at 16 pt/s, which left this at ~2.1 s.
        let duration = ScrollMomentum.coastDuration(initialSpeed: 1000)
        XCTAssertEqual(duration, 1.6, accuracy: 0.1)
    }

    func testTheOldFloorWouldHaveRunMuchLonger() {
        // The measurement behind the change: the last 24 pt/s of decay is the
        // slowest stretch there is, and it is invisible.
        let toOldFloor = log(16.0 / 1000.0) / log(ScrollMomentum.decelerationPerMs) / 1000
        XCTAssertGreaterThan(toOldFloor - ScrollMomentum.coastDuration(initialSpeed: 1000), 0.4)
    }

    func testASlowFlickDoesNotCoastAtAll() {
        XCTAssertEqual(ScrollMomentum.coastDuration(initialSpeed: 30), 0)
        XCTAssertLessThan(ScrollMomentum.startSpeed, 1000)
        XCTAssertGreaterThan(ScrollMomentum.startSpeed, ScrollMomentum.stopSpeed,
                             "a flick too slow to coast must not be one that stops immediately")
    }

    func testTheDecelerationRateIsStillUIScrollViewsOwn() {
        XCTAssertEqual(ScrollMomentum.decelerationPerMs, 0.998, accuracy: 1e-9)
    }
}

/// The pan-versus-hold ordering, which is the whole of "moved first = scroll,
/// held first = menu or drag".
final class HoldPriorityTests: XCTestCase {

    func testTheHoldFailsBeforeThePanCanBegin() {
        // If these two ever cross, the pan starts from a finger the hold was
        // still entitled to and hold-drag silently stops working — which is
        // exactly what the round-4 log shows: 10 pan sessions, one long press.
        XCTAssertTrue(HoldPriority.holdFailsBeforeThePanCanBegin)
        XCTAssertLessThan(HoldPriority.holdSlop, HoldPriority.panStartThreshold)
    }

    func testAFingerPastTheSlopIsScrolling() {
        XCTAssertTrue(HoldPriority.panMayBegin(movedBy: 10))
        XCTAssertTrue(HoldPriority.panMayBegin(movedBy: 8.5))
    }

    func testAFingerInsideTheSlopBelongsToTheHold() {
        XCTAssertFalse(HoldPriority.panMayBegin(movedBy: 8))
        XCTAssertFalse(HoldPriority.panMayBegin(movedBy: 0))
    }

    func testTheHoldDurationIsIPadOSsOwnContextMenuDelay() {
        XCTAssertEqual(HoldPriority.holdDuration, 0.4, accuracy: 1e-9)
    }
}

/// A6: the exact sequence the operator could not perform — hold still for
/// 0.4 s, then move 30 pt — driven through the pure machine.
final class HoldThenDragTests: XCTestCase {

    func testHoldingStillThenMovingThirtyPointsIsADrag() {
        var machine = HoldDragMachine()
        let held = CGPoint(x: 400, y: 300)

        // 0.4 s of stillness: UIKit commits the long press and the machine is
        // told. Nothing goes on the wire — a hold is not a click.
        XCTAssertEqual(machine.begin(at: held), .nothing)

        // The finger starts to move. Inside the commit slop it is still
        // deciding between a context menu and a drag.
        XCTAssertEqual(machine.move(to: CGPoint(x: 404, y: 303)), .nothing)

        // Past it: the button goes down where the finger was HELD, and the
        // first move follows in the same emission.
        XCTAssertEqual(machine.move(to: CGPoint(x: 430, y: 300)),
                       .dragBegan(at: held, movedTo: CGPoint(x: 430, y: 300)))

        // Every later sample is an unclamped move.
        XCTAssertEqual(machine.move(to: CGPoint(x: 460, y: 320)),
                       .dragMoved(to: CGPoint(x: 460, y: 320)))
        XCTAssertEqual(machine.move(to: CGPoint(x: 900, y: 700)),
                       .dragMoved(to: CGPoint(x: 900, y: 700)))

        // And the lift releases where the finger actually is.
        XCTAssertEqual(machine.end(at: CGPoint(x: 900, y: 700), cancelled: false),
                       .dragEnded(at: CGPoint(x: 900, y: 700), cancelled: false))
        XCTAssertFalse(machine.isActive)
    }

    func testThirtyPointsIsComfortablyPastTheCommitSlop() {
        // The addendum's number, checked against the constant rather than
        // assumed: 30 pt has to be a drag on any plausible retune.
        XCTAssertGreaterThan(30, HoldDragMachine.defaultCommitSlop)
    }

    func testTheSameSequenceAfterAFlickStillDrags() {
        // The round-4 bug in one test: a coast was running, so the hold was
        // refused, so this whole sequence produced nothing for ~2 s after
        // every flick — which is most of the time somebody is using it.
        XCTAssertTrue(MomentumBrake.allows(.longPress, braking: true))
        var machine = HoldDragMachine()
        _ = machine.begin(at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(machine.move(to: CGPoint(x: 130, y: 100)),
                       .dragBegan(at: CGPoint(x: 100, y: 100), movedTo: CGPoint(x: 130, y: 100)))
    }
}

// MARK: - Where the video actually is on the glass

/// The letterbox. A touch normalized against the view instead of against the
/// displayed video rect lands a whole letterbox-height away from where the user
/// aimed — and looks perfectly plausible while doing it.
final class VideoGeometryTests: XCTestCase {

    /// iPad Pro 11" in landscape (points) showing a 16:10-ish Mac desktop:
    /// pillarboxed, black bars left and right.
    private let glass = CGSize(width: 1194, height: 834)
    private let video = CGSize(width: 1920, height: 1080)

    func testTheVideoRectIsCentredAndAspectFit() {
        let rect = VideoGeometry.videoRect(bounds: glass, videoSize: video)
        XCTAssertNotNil(rect)
        XCTAssertEqual(rect!.width, 1194, accuracy: 0.01)
        XCTAssertEqual(rect!.height, 1194 * 1080 / 1920, accuracy: 0.01)
        XCTAssertEqual(rect!.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect!.minY, (834 - rect!.height) / 2, accuracy: 0.01)
    }

    func testTheCentreOfTheGlassIsTheCentreOfTheDesktop() {
        let n = VideoGeometry.normalize(CGPoint(x: 597, y: 417), bounds: glass, videoSize: video)
        XCTAssertEqual(n!.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(n!.y, 0.5, accuracy: 0.001)
    }

    func testTheTopOfTheVIDEOIsTheTopOfTheDesktopNotTheTopOfTheGLASS() {
        // The offset bug, stated directly. The video starts ~81 pt down; a
        // touch there is y = 0, and a touch at the very top of the glass is
        // clamped to 0 rather than reported as a negative coordinate.
        let rect = VideoGeometry.videoRect(bounds: glass, videoSize: video)!
        let atVideoTop = VideoGeometry.normalize(CGPoint(x: 597, y: rect.minY),
                                                 bounds: glass, videoSize: video)!
        XCTAssertEqual(atVideoTop.y, 0, accuracy: 0.001)
        let atGlassTop = VideoGeometry.normalize(CGPoint(x: 597, y: 0),
                                                 bounds: glass, videoSize: video)!
        XCTAssertEqual(atGlassTop.y, 0, accuracy: 0.001)
    }

    func testACoordinateDraggedIntoTheLetterboxIsClamped() {
        // A drag that leaves the video must keep driving the Mac's cursor along
        // the edge, not report a point off the desktop.
        let below = VideoGeometry.normalize(CGPoint(x: 2000, y: 5000),
                                            bounds: glass, videoSize: video)!
        XCTAssertEqual(below.x, 1, accuracy: 0.0001)
        XCTAssertEqual(below.y, 1, accuracy: 0.0001)
        let above = VideoGeometry.normalize(CGPoint(x: -400, y: -400),
                                            bounds: glass, videoSize: video)!
        XCTAssertEqual(above.x, 0, accuracy: 0.0001)
        XCTAssertEqual(above.y, 0, accuracy: 0.0001)
    }

    func testNormalizeAndPointAreExactInverses() {
        // The cursor sprite is drawn with `point` and the touches are sent with
        // `normalize`; if they ever disagree, the cursor is not where the
        // finger goes.
        for p in [CGPoint(x: 10, y: 100), CGPoint(x: 597, y: 417), CGPoint(x: 1100, y: 700)] {
            let n = VideoGeometry.normalize(p, bounds: glass, videoSize: video)!
            let back = VideoGeometry.point(x: n.x, y: n.y, bounds: glass, videoSize: video)!
            XCTAssertEqual(back.x, p.x, accuracy: 0.01)
            XCTAssertEqual(back.y, p.y, accuracy: 0.01)
        }
    }

    func testALetterboxedPortraitSessionIsHandledToo() {
        // The iPad rotated: bars top and bottom become bars left and right.
        let portrait = CGSize(width: 834, height: 1194)
        let rect = VideoGeometry.videoRect(bounds: portrait, videoSize: CGSize(width: 1668, height: 2388))!
        XCTAssertEqual(rect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.01)
        XCTAssertEqual(rect.size.width, 834, accuracy: 0.01)
    }

    func testNothingIsMappedBeforeTheFirstFrame() {
        // `videoSize` is zero until the format description arrives; a touch
        // then must be dropped, not divided by zero.
        XCTAssertNil(VideoGeometry.videoRect(bounds: glass, videoSize: .zero))
        XCTAssertNil(VideoGeometry.normalize(.zero, bounds: glass, videoSize: .zero))
        XCTAssertNil(VideoGeometry.normalize(.zero, bounds: .zero, videoSize: video))
    }
}
