import CoreGraphics
import XCTest

/// The pinch, end to end as arithmetic (§43).
///
/// Round 6 shipped a zoom path that was wired correctly and carried nonsense.
/// Both logs agreed exactly — 24 messages on the iPad, 24 events on the Mac,
/// `net ×225395.704` on both — which ruled out the wire and the Mac and left
/// the number the iPad computed. These tests are that number, and the Mac's
/// conversion of it, pinned so the next round cannot reintroduce either.
final class PinchScaleTests: XCTestCase {

    // MARK: - The iPad's half: cumulative → incremental

    func testAnIncrementIsTheRatioOfTwoCumulativeReadings() {
        // 1.10 then 1.21 is two 10% steps, not a 10% step and a 21% one.
        XCTAssertEqual(PinchScale.step(cumulative: 1.10, previous: 1.00)!, 1.10, accuracy: 1e-9)
        XCTAssertEqual(PinchScale.step(cumulative: 1.21, previous: 1.10)!, 1.10, accuracy: 1e-9)
    }

    func testTheRoundSixTrackpadSessionNoLongerExplodes() {
        // The shape of the round-6 defect: `UIPinchGestureRecognizer.scale` is
        // the running total, `recognizer.scale = 1` does nothing for an
        // indirect (trackpad) pinch, and every reading was multiplied in as if
        // it were a step. 24 readings of a gesture growing 4% per frame.
        var cumulative = 1.0
        var previous = 1.0
        var netWrong = 1.0
        var netRight = 1.0
        for _ in 0..<24 {
            cumulative *= 1.04
            netWrong *= cumulative                       // round 6
            netRight *= PinchScale.step(cumulative: cumulative, previous: previous)!
            previous = cumulative
        }
        XCTAssertGreaterThan(netWrong, 100_000, "the old arithmetic really did do this")
        XCTAssertEqual(netRight, cumulative, accuracy: 1e-6,
                       "the product of the increments is the gesture's actual scale")
        XCTAssertEqual(netRight, 2.563, accuracy: 0.001)
    }

    func testAZoomOutDoesNotUnderflowToZero() {
        // The `net ×0.000` lines in the round-6 log are the same bug with the
        // fingers moving the other way.
        var cumulative = 1.0
        var previous = 1.0
        var net = 1.0
        for _ in 0..<15 {
            cumulative *= 0.97
            net *= PinchScale.step(cumulative: cumulative, previous: previous)!
            previous = cumulative
        }
        XCTAssertEqual(net, cumulative, accuracy: 1e-9)
        XCTAssertGreaterThan(net, 0.5)
    }

    func testTheProductOfTheIncrementsIsAlwaysTheGesturesOwnScale() {
        // The invariant the whole design rests on, over a hostile walk.
        // Every consecutive ratio here is inside the clamp, which is what an
        // actual pinch looks like: fingers reverse direction, they do not
        // teleport.
        let readings = [1.05, 1.10, 1.02, 0.95, 0.90, 0.95, 1.05, 1.15, 1.20]
        var previous = 1.0
        var net = 1.0
        for reading in readings {
            net *= PinchScale.step(cumulative: reading, previous: previous)!
            previous = reading
        }
        XCTAssertEqual(net, readings.last!, accuracy: 1e-9)
    }

    func testAReadingWithNoMeaningIsSkippedRatherThanSent() {
        XCTAssertNil(PinchScale.step(cumulative: 0, previous: 1))
        XCTAssertNil(PinchScale.step(cumulative: -1, previous: 1))
        XCTAssertNil(PinchScale.step(cumulative: .nan, previous: 1))
        XCTAssertNil(PinchScale.step(cumulative: .infinity, previous: 1))
        XCTAssertNil(PinchScale.step(cumulative: 1, previous: 0))
        XCTAssertNil(PinchScale.step(cumulative: 1, previous: .nan))
    }

    func testARebaseIsClampedRatherThanSent() {
        // A second finger landing re-bases `scale`, exactly as it re-bases a
        // pan's translation (§37). That shows up as one enormous ratio, and it
        // is an artefact rather than a gesture.
        XCTAssertEqual(PinchScale.step(cumulative: 100, previous: 1)!, PinchScale.maxStep)
        XCTAssertEqual(PinchScale.step(cumulative: 1, previous: 100)!, PinchScale.minStep,
                       accuracy: 1e-12)
        XCTAssertTrue(PinchScale.wasClamped(cumulative: 100, previous: 1))
        XCTAssertFalse(PinchScale.wasClamped(cumulative: 1.05, previous: 1))
    }

    func testTheClampIsWellAboveAnythingRealFingersProduce() {
        // A 120 Hz pinch reports steps in the 1.001–1.05 range.
        for step in [1.001, 1.01, 1.05, 0.99, 0.95] {
            XCTAssertFalse(PinchScale.wasClamped(cumulative: step, previous: 1),
                           "\(step) is an ordinary pinch frame")
        }
    }

    // MARK: - The Mac's half: incremental scale → additive magnification

    func testTheWireScaleBecomesAnAdditiveDelta() {
        // `NSEvent.magnification` is a delta around zero, not a factor.
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1.02)!,
                       0.02, accuracy: 1e-9)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 1.0)!, 0)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 0.98)!,
                       -0.02, accuracy: 1e-9)
    }

    func testTheClampIsQuarterAndIsFlaggedWhenItBites() {
        XCTAssertEqual(MagnifyGesture.maxMagnificationPerMessage, 0.25)
        XCTAssertEqual(MagnifyGesture.magnification(fromIncrementalScale: 50)!, 0.25)
        XCTAssertTrue(MagnifyGesture.clamps(50))
        XCTAssertFalse(MagnifyGesture.clamps(1.05))
        XCTAssertFalse(MagnifyGesture.clamps(.nan), "a meaningless scale is refused, not clamped")
    }

    func testEveryStepTheIPadCanNowSendSurvivesTheMacsClampUntouched() {
        // The two halves have to agree: whatever the iPad is allowed to put on
        // the wire must pass the Mac's bound without being altered, or every
        // fast pinch would be silently flattened.
        for step in [PinchScale.maxStep, PinchScale.minStep, 1.0, 1.1, 0.9] {
            XCTAssertFalse(MagnifyGesture.clamps(step),
                           "the iPad's ceiling of \(PinchScale.maxStep) must fit inside "
                           + "the Mac's ±\(MagnifyGesture.maxMagnificationPerMessage)")
        }
    }

    func testAWholeGestureSumsToWhatTheApplicationWillAccumulate() {
        // What `Σmagnification` in the log means: PDFKit multiplies its scale
        // by (1 + magnification) per event, so twenty 1% steps are a ~22% zoom.
        var product = 1.0
        var sum = 0.0
        for _ in 0..<20 {
            let delta = MagnifyGesture.magnification(fromIncrementalScale: 1.01)!
            sum += delta
            product *= 1 + delta
        }
        XCTAssertEqual(sum, 0.20, accuracy: 1e-9)
        XCTAssertEqual(product, 1.2202, accuracy: 0.0001)
    }
}
