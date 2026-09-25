import CoreGraphics
import XCTest

/// The hold-versus-pan arbitration, made structural (§36).
///
/// Round 5 shipped an arbitration that rested on two numbers being in the
/// right order — the long press's 8 pt `allowableMovement` against
/// `UIPanGestureRecognizer`'s undocumented ~10 pt start threshold — and a log
/// line to prove it. The log line then reported the pan beginning after 0.0,
/// 0.2, 0.5, 2.5, 4.0 and 4.5 pt, all inside the slop. Both the mechanism and
/// the measurement were wrong, and these tests pin the replacement for each.
final class PanSlopGateTests: XCTestCase {

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: - The gate

    func testTheGateUsesTheSameSlopAsTheHold() {
        // If these ever diverge there is a band of movement in which neither
        // the hold nor the pan owns the finger, or both do.
        XCTAssertEqual(PanSlopGate.defaultSlop, HoldPriority.holdSlop)
    }

    func testAFingerThatHasNotMovedIsNotAPan() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(100, 100))
        XCTAssertFalse(gate.shouldForward(centroid: point(100, 100)))
        XCTAssertFalse(gate.isOpen)
    }

    func testEveryDistanceTheRoundFiveLogReportedIsWithheld() {
        // 0.0, 0.2, 0.5, 2.5, 4.0 and 4.5 pt — the eight `nativePan begins`
        // lines from the evening of the round-5 session. Not one of them may
        // start a pan now.
        for distance in [0.0, 0.2, 0.5, 2.5, 4.0, 4.5] as [CGFloat] {
            var gate = PanSlopGate()
            gate.touchCountChanged(centroid: point(0, 0))
            XCTAssertFalse(gate.shouldForward(centroid: point(distance, 0)),
                           "\(distance) pt is inside the hold's slop")
        }
    }

    func testTheGateOpensAtExactlyTheSlop() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        XCTAssertFalse(gate.shouldForward(centroid: point(7.9, 0)))
        XCTAssertTrue(gate.shouldForward(centroid: point(8, 0)))
        XCTAssertTrue(gate.isOpen)
        XCTAssertEqual(gate.openedAfter, 8, accuracy: 0.001)
    }

    func testDistanceIsMeasuredInBothAxes() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        // 6,6 is 8.49 pt away — past the slop, though neither axis is.
        XCTAssertTrue(gate.shouldForward(centroid: point(6, 6)))
    }

    func testOnceOpenEveryMoveGoesThrough() {
        // A drag in progress must never be re-arbitrated: a finger that comes
        // back to where it started is still panning.
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        XCTAssertTrue(gate.shouldForward(centroid: point(20, 0)))
        XCTAssertTrue(gate.shouldForward(centroid: point(0, 0)))
        XCTAssertTrue(gate.shouldForward(centroid: point(1, 1)))
    }

    func testTheGateCountsWhatItWithheld() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        for step in stride(from: CGFloat(1), through: 7, by: 1) {
            _ = gate.shouldForward(centroid: point(step, 0))
        }
        XCTAssertEqual(gate.withheld, 7)
        XCTAssertTrue(gate.shouldForward(centroid: point(9, 0)))
        XCTAssertEqual(gate.withheld, 7, "the opening move is not withheld")
    }

    func testASecondFingerRebasesTheCentroidInsteadOfReadingAsAJump() {
        // The round-5 log's `nativePan .began touches=2` after 0.2 pt: adding
        // a finger moves the centroid by half the distance between the two,
        // which is not movement of the gesture.
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        _ = gate.shouldForward(centroid: point(2, 0))
        gate.touchCountChanged(centroid: point(200, 0))   // the second finger landed
        XCTAssertFalse(gate.shouldForward(centroid: point(203, 0)),
                       "3 pt from the new centroid is still inside the slop")
        XCTAssertTrue(gate.shouldForward(centroid: point(212, 0)))
    }

    func testAnOpenGateIsNotRebasedByATouchLeaving() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        XCTAssertTrue(gate.shouldForward(centroid: point(30, 0)))
        gate.touchCountChanged(centroid: point(500, 500))
        XCTAssertTrue(gate.shouldForward(centroid: point(500, 500)),
                      "a pan that has begun keeps the finger")
    }

    func testResetStartsOver() {
        var gate = PanSlopGate()
        gate.touchCountChanged(centroid: point(0, 0))
        XCTAssertTrue(gate.shouldForward(centroid: point(50, 0)))
        gate.reset()
        XCTAssertFalse(gate.isOpen)
        XCTAssertEqual(gate.withheld, 0)
        XCTAssertEqual(gate.openedAfter, 0)
        gate.touchCountChanged(centroid: point(0, 0))
        XCTAssertFalse(gate.shouldForward(centroid: point(3, 0)))
    }

    func testTheFirstMoveWithNoOriginEstablishesOneRatherThanOpening() {
        var gate = PanSlopGate()
        XCTAssertFalse(gate.shouldForward(centroid: point(900, 900)))
        XCTAssertFalse(gate.shouldForward(centroid: point(903, 900)))
        XCTAssertTrue(gate.shouldForward(centroid: point(915, 900)))
    }

    // MARK: - Centroids

    func testTheCentroidOfNoPointsIsNilNotTheOrigin() {
        // `.zero` is a real corner of the view and would read as an enormous
        // jump the moment the last finger lifted.
        XCTAssertNil(PanSlopGate.centroid(of: []))
    }

    func testTheCentroidOfTwoFingers() {
        XCTAssertEqual(PanSlopGate.centroid(of: [point(0, 0), point(100, 50)]),
                       point(50, 25))
    }

    // MARK: - Pinch versus pan

    func testFingersHoldingTheirSpacingAreAScroll() {
        XCTAssertFalse(PinchArbiter.panYieldsToPinch(initialSpread: 120, currentSpread: 124))
        XCTAssertFalse(PinchArbiter.panYieldsToPinch(initialSpread: 120, currentSpread: 108))
    }

    func testFingersChangingTheirSpacingAreAPinch() {
        XCTAssertTrue(PinchArbiter.panYieldsToPinch(initialSpread: 120, currentSpread: 200))
        XCTAssertTrue(PinchArbiter.panYieldsToPinch(initialSpread: 200, currentSpread: 120))
    }

    func testTheSpreadThresholdIsAboveThePanSlop() {
        // The two tests race on the same samples; a pinch that also drifts
        // must not be able to satisfy both at once.
        XCTAssertGreaterThan(PinchArbiter.spreadSlop, PanSlopGate.defaultSlop)
    }

    func testSpreadIsTheDistanceBetweenTwoFingers() {
        XCTAssertEqual(PinchArbiter.spread(point(0, 0), point(3, 4)), 5, accuracy: 0.001)
    }

    func testOnlyThePanAndThePinchMayRunTogether() {
        XCTAssertTrue(PinchArbiter.mayRunTogether(.pan, .pinch))
        XCTAssertTrue(PinchArbiter.mayRunTogether(.pinch, .pan))
        for a in NativeRecognizer.allCases {
            for b in NativeRecognizer.allCases where Set([a, b]) != Set([.pan, .pinch]) {
                XCTAssertFalse(PinchArbiter.mayRunTogether(a, b),
                               "\(a) and \(b) must stay exclusive")
            }
        }
    }

    func testAHoldThatCommittedAndThenMovesIsADragNotAScroll() {
        // The round-5 log did produce two complete drags, and the machine that
        // produced them is unchanged — but the gate now guarantees the pan
        // cannot take the finger first, which is what made them rare.
        // The exact sequence from the round-5 log at 01:52:08.
        let held = CGPoint(x: 343, y: 469)
        var machine = HoldDragMachine()
        XCTAssertEqual(machine.begin(at: held), .nothing, "a hold presses nothing")
        XCTAssertTrue(machine.isActive)
        // Inside the commit slop: still a hold.
        XCTAssertEqual(machine.move(to: CGPoint(x: 345, y: 471)), .nothing)
        // Past it: the drag begins at the point that was HELD, not here.
        XCTAssertEqual(machine.move(to: CGPoint(x: 375, y: 469)),
                       .dragBegan(at: held, movedTo: CGPoint(x: 375, y: 469)))
        XCTAssertTrue(machine.isDragging)
        XCTAssertEqual(machine.move(to: CGPoint(x: 400, y: 500)),
                       .dragMoved(to: CGPoint(x: 400, y: 500)))
        XCTAssertEqual(machine.end(cancelled: false),
                       .dragEnded(at: CGPoint(x: 400, y: 500), cancelled: false))
        XCTAssertFalse(machine.isActive)
    }
}
