import CoreGraphics
import XCTest

final class DisplayArrangementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1_512, height: 982)

    func testRotationKeepsDisplayFlushLeftOfItsNeighbour() {
        let saved = CGRect(x: -588, y: 0, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: -1_278, y: 0))
    }

    func testRotationKeepsDisplayFlushRightOfItsNeighbour() {
        // The saved portrait hangs above the main display, overlapping it by
        // only its bottom 345pt. Carrying y over verbatim would put the
        // shorter landscape entirely above the main display — a disconnected
        // arrangement WindowServer would snap. Slide it down just far enough
        // to keep the 345pt of shared edge it had.
        let saved = CGRect(x: 1_512, y: -933, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -243))
        XCTAssertEqual(CGRect(origin: target, size: CGSize(width: 1_278, height: 588)).maxY - main.minY, 345)
    }

    func testRotationKeepsDisplayFlushAboveAndBelowItsNeighbour() {
        let above = CGRect(x: 200, y: -1_278, width: 588, height: 1_278)
        let below = CGRect(x: 200, y: 982, width: 588, height: 1_278)
        let landscape = CGSize(width: 1_278, height: 588)

        XCTAssertEqual(DisplayArrangement.remappedOrigin(from: above, to: landscape, against: [main]),
                       CGPoint(x: 200, y: -588))
        XCTAssertEqual(DisplayArrangement.remappedOrigin(from: below, to: landscape, against: [main]),
                       CGPoint(x: 200, y: 982))
    }

    func testRepeatedRotationDoesNotDriftTheSavedPlacement() {
        let portraitSize = CGSize(width: 588, height: 1_278)
        let landscapeSize = CGSize(width: 1_278, height: 588)
        let portrait = CGRect(origin: CGPoint(x: -588, y: 0), size: portraitSize)

        let landscapeOrigin = DisplayArrangement.remappedOrigin(from: portrait,
                                                                 to: landscapeSize,
                                                                 against: [main])
        let landscape = CGRect(origin: landscapeOrigin, size: landscapeSize)
        let restoredPortrait = DisplayArrangement.remappedOrigin(from: landscape,
                                                                  to: portraitSize,
                                                                  against: [main])

        XCTAssertEqual(landscapeOrigin, CGPoint(x: -1_278, y: 0))
        XCTAssertEqual(restoredPortrait, portrait.origin)
    }

    func testRotationKeepsTheSideWhenTheSavedDisplayTouchesAtOnlyACorner() {
        // WindowServer allows this top-right corner attachment. It has no
        // shared vertical edge, so a remap must not fall back to the old
        // center calculation and request an illegal gap.
        let saved = CGRect(x: 1_512, y: -588, width: 1_278, height: 588)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 588, height: 1_278),
                                                        against: [main])

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -588))
    }

    func testSavedMainDisplaySideWinsOverOtherVirtualDisplayGeometry() {
        let saved = CGRect(x: -588, y: 120, width: 588, height: 1_278)

        let target = DisplayArrangement.origin(for: CGSize(width: 1_278, height: 588),
                                               from: saved, side: .left, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: -1_278, y: 120))
    }

    func testSavedSideStillYieldsAConnectedArrangementWhenTheDisplayShrinks() {
        // Same shape as the remap case above, on the path that actually runs
        // once a record carries its side: the rotated display must still share
        // an edge with the main display rather than float off its top.
        let saved = CGRect(x: 1_512, y: -933, width: 588, height: 1_278)
        let size = CGSize(width: 1_278, height: 588)

        let target = DisplayArrangement.origin(for: size, from: saved, side: .right, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -243))
        XCTAssertTrue(CGRect(origin: target, size: size).intersects(main.insetBy(dx: -1, dy: 0)))
    }

    func testSavedSideRoundTripsWithoutDrift() {
        let portrait = CGSize(width: 588, height: 1_278)
        let landscape = CGSize(width: 1_278, height: 588)
        let saved = CGRect(origin: CGPoint(x: -588, y: 120), size: portrait)

        let rotated = DisplayArrangement.origin(for: landscape, from: saved, side: .left, relativeTo: main)
        let back = DisplayArrangement.origin(for: portrait,
                                             from: CGRect(origin: rotated, size: landscape),
                                             side: .left, relativeTo: main)

        XCTAssertEqual(rotated, CGPoint(x: -1_278, y: 120))
        XCTAssertEqual(back, saved.origin)
    }

    func testSavedSideKeepsACornerAttachmentACorner() {
        let saved = CGRect(x: 1_512, y: -588, width: 1_278, height: 588)

        let target = DisplayArrangement.origin(for: CGSize(width: 588, height: 1_278),
                                               from: saved, side: .right, relativeTo: main)

        XCTAssertEqual(target, CGPoint(x: 1_512, y: -588))
    }

    func testLegacyRecordTouchingMainDisplayCanAlsoKeepItsSide() {
        let legacy = CGRect(x: 392, y: 982, width: 1_180, height: 820)

        XCTAssertEqual(DisplayArrangement.inferredMainDisplaySide(of: legacy, relativeTo: main), .below)
    }

    func testRotationFallsBackToCenterWhenTheSavedNeighbourIsGone() {
        let saved = CGRect(x: -588, y: 0, width: 588, height: 1_278)

        let target = DisplayArrangement.remappedOrigin(from: saved,
                                                        to: CGSize(width: 1_278, height: 588),
                                                        against: [])

        XCTAssertEqual(target, CGPoint(x: -933, y: 345))
    }

    // MARK: - Extend never makes the session display main
    //
    // Hardware test C, 2026-10-28, macOS 27.2: a 1.22.7 record (0,0,1194,834)
    // put the Extend display at the desktop origin, which is what makes a
    // display main, and the panel moved aside. WindowServer also restored its
    // own Remote arrangement for the pair, with the panel at 2560 × 1440.

    private let panel = CGRect(x: 0, y: 0, width: 2_048, height: 1_152)
    private let iPad = CGSize(width: 1_194, height: 834)

    private func restoredRemoteArrangement() -> [OriginPin.Screen] {
        [OriginPin.Screen(id: 8, size: iPad, origin: .zero),
         OriginPin.Screen(id: 2, size: CGSize(width: 2_560, height: 1_440),
                          origin: CGPoint(x: 1_194, y: 0))]
    }

    func testStaleRecordAtTheDesktopOriginIsNeitherRestoredNorSaved() {
        let stale = [0, 0, 1_194, 834]

        XCTAssertNil(DisplayArrangement.origin(for: iPad, record: stale,
                                               relativeTo: panel, against: [panel]))
        XCTAssertNil(DisplayArrangement.origin(for: CGSize(width: 834, height: 1_194),
                                               record: stale, relativeTo: panel, against: [panel]),
                     "a rotation must not remap it beside the panel either")
        XCTAssertNil(DisplayArrangement.record(for: CGRect(origin: .zero, size: iPad),
                                               relativeTo: panel, preferring: nil))
    }

    func testPlacementOverTheDesktopOriginIsInvalidButTouchingItIsNot() {
        let over = CGRect(x: -600, y: -400, width: 1_194, height: 834)

        XCTAssertNil(DisplayArrangement.record(for: over, relativeTo: panel, preferring: .left))
        XCTAssertNil(DisplayArrangement.origin(for: iPad, record: [-600, -400, 1_194, 834],
                                               relativeTo: panel, against: [panel]))
        // A corner or an edge at the origin is a neighbour, not an overlap.
        XCTAssertTrue(DisplayArrangement.isValid(CGRect(x: -1_194, y: -834,
                                                        width: 1_194, height: 834)))
        XCTAssertTrue(DisplayArrangement.isValid(CGRect(x: 0, y: -834, width: 1_194, height: 834)))
    }

    func testMissingRecordGoesRightOfTheMainDisplay() {
        XCTAssertNil(DisplayArrangement.origin(for: iPad, record: nil,
                                               relativeTo: panel, against: [panel]))
        XCTAssertEqual(DisplayArrangement.defaultOrigin(rightOf: panel), CGPoint(x: 2_048, y: 0))
    }

    func testValidLeftRecordIsSavedAndRestoredOnTheLeft() {
        // The record the sender wrote once the user had dragged the iPad left.
        let left = CGRect(x: -1_194, y: 0, width: 1_194, height: 834)
        let record = DisplayArrangement.record(for: left, relativeTo: panel, preferring: nil)

        XCTAssertEqual(record, [-1_194, 0, 1_194, 834, DisplayArrangement.Side.left.rawValue])
        XCTAssertEqual(DisplayArrangement.origin(for: iPad, record: record,
                                                 relativeTo: panel, against: [panel]),
                       left.origin)
    }

    func testValidRightRecordIsSavedAndRestoredOnTheRight() {
        let right = CGRect(x: 2_048, y: 0, width: 1_194, height: 834)
        let record = DisplayArrangement.record(for: right, relativeTo: panel, preferring: nil)

        XCTAssertEqual(record, [2_048, 0, 1_194, 834, DisplayArrangement.Side.right.rawValue])
        XCTAssertEqual(DisplayArrangement.origin(for: iPad, record: record,
                                                 relativeTo: panel, against: [panel]),
                       right.origin)
    }

    func testGuardPutsThePanelBackAndAMissingRecordRightOfIt() {
        let target = CGRect(origin: DisplayArrangement.defaultOrigin(rightOf: panel), size: iPad)

        let placements = DisplayArrangement.mainRestoringLayout(
            main: 2, mainBefore: panel, session: 8, target: target,
            screens: restoredRemoteArrangement())

        XCTAssertEqual(placements, [
            OriginPin.Placement(id: 8, origin: CGPoint(x: 2_560, y: 0)),
            OriginPin.Placement(id: 2, origin: .zero),
        ], "right of the panel at its size now, not at the 2048 it had before the restore")
    }

    func testGuardKeepsASavedLeftSpot() {
        let target = CGRect(x: -1_194, y: 0, width: 1_194, height: 834)

        let placements = DisplayArrangement.mainRestoringLayout(
            main: 2, mainBefore: panel, session: 8, target: target,
            screens: restoredRemoteArrangement())

        XCTAssertEqual(placements, [
            OriginPin.Placement(id: 8, origin: CGPoint(x: -1_194, y: 0)),
            OriginPin.Placement(id: 2, origin: .zero),
        ])
    }

    func testGuardKeepsOtherDisplaysAtTheirOffsetFromTheMainDisplay() {
        let third = OriginPin.Screen(id: 4, size: CGSize(width: 1_280, height: 800),
                                     origin: CGPoint(x: 1_194 + 2_560, y: 0))

        let placements = DisplayArrangement.mainRestoringLayout(
            main: 2, mainBefore: panel, session: 8,
            target: CGRect(x: -1_194, y: 0, width: 1_194, height: 834),
            screens: restoredRemoteArrangement() + [third])

        XCTAssertEqual(placements.last, OriginPin.Placement(id: 4, origin: CGPoint(x: 2_560, y: 0)))
    }

    func testGuardDoesNothingWithoutTheOldMainDisplay() {
        let placements = DisplayArrangement.mainRestoringLayout(
            main: 3, mainBefore: panel, session: 8,
            target: CGRect(x: 2_048, y: 0, width: 1_194, height: 834),
            screens: restoredRemoteArrangement())

        XCTAssertEqual(placements, [])
    }
}
