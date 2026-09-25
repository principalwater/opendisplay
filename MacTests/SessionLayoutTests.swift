import CoreGraphics
import XCTest

/// `sessionLayout` and the legacy `mode` key it supersedes.
///
/// The precedence matters more than it looks: `mode` is also a launch
/// argument (`-mode mirror`), several machines have it written into their
/// defaults, and the fork changes what "nothing is set" means — from
/// upstream's `extend` to `remote`. Getting that wrong either ignores a key
/// somebody deliberately wrote, or silently moves their display to (0,0).
final class SessionLayoutTests: XCTestCase {

    // MARK: - Precedence

    private func layout(_ sessionLayout: String?, _ legacyMode: String?) -> SessionLayout {
        SessionLayout.resolve(sessionLayout: sessionLayout, legacyMode: legacyMode).layout
    }

    private func source(_ sessionLayout: String?, _ legacyMode: String?) -> SessionLayout.Source {
        SessionLayout.resolve(sessionLayout: sessionLayout, legacyMode: legacyMode).source
    }

    func testNothingSetMeansRemote() {
        XCTAssertEqual(layout(nil, nil), .remote)
        XCTAssertEqual(source(nil, nil), .forkDefault)
        XCTAssertEqual(SessionLayout.forkDefault, .remote)
    }

    func testSessionLayoutWinsOverMode() {
        XCTAssertEqual(layout("extend", "mirror"), .extend)
        XCTAssertEqual(layout("mirror", "extend"), .mirror)
        XCTAssertEqual(layout("remote", "mirror"), .remote)
        XCTAssertEqual(source("remote", "mirror"), .sessionLayoutKey)
    }

    func testTheLegacyModeKeyStillSelectsMirror() {
        // Mirror is a different pipeline — no virtual display at all — and
        // nothing else can ask for it, so a stale `mode mirror` still means
        // what it said.
        XCTAssertEqual(layout(nil, "mirror"), .mirror)
        XCTAssertEqual(source(nil, "mirror"), .legacyModeKey)
    }

    func testAStaleModeExtendCanNoLongerDemoteTheFork() {
        // THE round-5 regression, in one assertion. `mode` is upstream's key
        // and the `-mode` launch argument; it was left on the operator's
        // machine from before `sessionLayout` existed, and with `sessionLayout`
        // absent it silently turned the fork back into upstream's extend —
        // arrangement memory on, nothing pinned to (0,0) — while the external
        // watchdog went on making the iPad's display main. The two fought over
        // the desktop origin and taps landed on the neighbouring tab.
        XCTAssertEqual(layout(nil, "extend"), .remote)
        XCTAssertEqual(source(nil, "extend"), .forkDefault,
                       "the resolved layout must say it came from the default, not from `mode`")
    }

    func testExtendIsStillReachableByAskingForItByName() {
        // Nothing is taken away: the layout is one documented defaults write.
        XCTAssertEqual(layout("extend", nil), .extend)
        XCTAssertEqual(source("extend", nil), .sessionLayoutKey)
        XCTAssertEqual(layout("extend", "extend"), .extend)
    }

    func testAnUnrecognisedValueIsTreatedAsAbsentRatherThanAsAnError() {
        XCTAssertEqual(layout("Remote", nil), .remote,
                       "a typo falls through to the next rule, not to a dead app")
        XCTAssertEqual(layout("nonsense", "mirror"), .mirror)
        XCTAssertEqual(layout("nonsense", "nonsense"), .remote)
        XCTAssertEqual(source("nonsense", "nonsense"), .forkDefault)
    }

    func testTheSourceIsAlwaysReportedAndAlwaysReadable() {
        for source in [SessionLayout.Source.sessionLayoutKey, .legacyModeKey, .forkDefault] {
            XCTAssertFalse(source.rawValue.isEmpty)
            XCTAssertFalse(source.explanation.isEmpty)
        }
    }

    // MARK: - The origin pin

    func testADisplayAlreadyAtTheOriginIsNotReconfigured() {
        // The enforcement tick runs five times a second for the whole session.
        // Every reconfiguration is a window in which CGDisplayBounds changes
        // under a touch that was normalized a millisecond earlier, so the
        // steady state must be a read and nothing else.
        XCTAssertFalse(OriginPin.needsRepin(currentOrigin: .zero))
        XCTAssertFalse(OriginPin.needsRepin(currentOrigin: OriginPin.mainOrigin))
    }

    func testAnyDriftAtAllIsRepinned() {
        XCTAssertTrue(OriginPin.needsRepin(currentOrigin: CGPoint(x: -1194, y: 0)))
        XCTAssertTrue(OriginPin.needsRepin(currentOrigin: CGPoint(x: 2048, y: 0)))
        XCTAssertTrue(OriginPin.needsRepin(currentOrigin: CGPoint(x: 0, y: 1)),
                      "a display one point down is not the main display")
        XCTAssertTrue(OriginPin.needsRepin(currentOrigin: CGPoint(x: 1, y: 0)))
    }

    func testTheOriginIsTheDesktopOrigin() {
        // macOS has no "make this main" call: the main display IS the one at
        // (0,0), and that is the entire mechanism this layout rests on.
        XCTAssertEqual(OriginPin.mainOrigin, CGPoint.zero)
    }


    // MARK: - The origin pin as a whole-desktop layout (round 6)
    //
    // Round 5's headless session logged the same pin 1105 times, 200 ms apart,
    // every one of them `result 0` and every one of them leaving the display
    // exactly where it was: a transaction that moves one display onto an
    // origin another display already owns describes an overlapping
    // arrangement, and WindowServer resolves it by snapping the display back.
    // These tests pin the arithmetic of the transaction that actually works.

    private func screen(_ id: UInt32, _ w: CGFloat, _ h: CGFloat,
                        at origin: CGPoint = .zero) -> OriginPin.Screen {
        OriginPin.Screen(id: id, size: CGSize(width: w, height: h), origin: origin)
    }

    func testTheRoundFiveSessionLaidOutCorrectly() {
        // The exact arrangement from the log: a BetterDisplay placeholder
        // ("iPad Pro 11 M1", id 158) main at (0,0) and our display 159 at
        // (1194,0). Pinning 159 alone was a no-op 1105 times.
        let placements = OriginPin.layout(target: 159, screens: [
            screen(158, 1194, 834, at: .zero),
            screen(159, 1194, 834, at: CGPoint(x: 1194, y: 0)),
        ])
        XCTAssertEqual(placements, [
            OriginPin.Placement(id: 159, origin: .zero),
            OriginPin.Placement(id: 158, origin: CGPoint(x: 1194, y: 0)),
        ], "the target takes the origin and the incumbent takes the target's old spot")
    }

    func testTheTargetIsAlwaysFirstAndAlwaysAtTheOrigin() {
        for target in [UInt32(1), 2, 3] {
            let placements = OriginPin.layout(target: target, screens: [
                screen(1, 1440, 900), screen(2, 1194, 834), screen(3, 2560, 1440),
            ])
            XCTAssertEqual(placements.first?.id, target)
            XCTAssertEqual(placements.first?.origin, OriginPin.mainOrigin)
        }
    }

    func testOthersAreLaidOutToTheRightInIDOrderAccumulatingWidths() {
        let placements = OriginPin.layout(target: 3, screens: [
            screen(9, 2560, 1440), screen(3, 1194, 834), screen(1, 1440, 900),
        ])
        XCTAssertEqual(placements, [
            OriginPin.Placement(id: 3, origin: .zero),
            OriginPin.Placement(id: 1, origin: CGPoint(x: 1194, y: 0)),
            OriginPin.Placement(id: 9, origin: CGPoint(x: 1194 + 1440, y: 0)),
        ])
    }

    func testEveryDisplaySitsOnTheTopEdge() {
        // A display at negative y would put the menu bar's screen below
        // something, and macOS snaps that back.
        let placements = OriginPin.layout(target: 1, screens: [
            screen(1, 1194, 834), screen(2, 2560, 1440), screen(3, 1440, 900),
        ])
        XCTAssertTrue(placements.allSatisfy { $0.origin.y == 0 })
    }

    func testTheRowIsContiguousWithNoGapsAndNoOverlaps() {
        let screens = [screen(1, 1194, 834), screen(4, 2560, 1440),
                       screen(7, 1440, 900), screen(2, 1920, 1080)]
        let placements = OriginPin.layout(target: 4, screens: screens)
        let widths = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.size.width) })
        var edge: CGFloat = 0
        for placement in placements {
            XCTAssertEqual(placement.origin.x, edge, "gap or overlap at display \(placement.id)")
            edge += widths[placement.id] ?? 0
        }
    }

    func testEveryDisplayIsPlacedExactlyOnce() {
        let screens = (1...6).map { screen(UInt32($0), 1000, 800) }
        let placements = OriginPin.layout(target: 4, screens: screens)
        XCTAssertEqual(placements.count, screens.count)
        XCTAssertEqual(Set(placements.map(\.id)), Set(screens.map(\.id)))
    }

    func testASingleDisplayIsJustTheOrigin() {
        XCTAssertEqual(OriginPin.layout(target: 7, screens: [screen(7, 1194, 834)]),
                       [OriginPin.Placement(id: 7, origin: .zero)])
    }

    func testADisplayThatIsNotInTheArrangementProducesNoTransaction() {
        // Mid-rebuild, or asleep. Reshuffling the desktop around a display
        // that has gone is worse than waiting 200 ms for the next tick.
        XCTAssertTrue(OriginPin.layout(target: 42, screens: [
            screen(1, 1440, 900), screen(2, 1194, 834),
        ]).isEmpty)
        XCTAssertTrue(OriginPin.layout(target: 42, screens: []).isEmpty)
    }

    func testTheLayoutDoesNotDependOnWhereTheDisplaysCurrentlyAre() {
        // Sorting by current origin would make the layout a function of the
        // state it exists to overwrite: one drifted display would drag the
        // whole row after it, and the arrangement would never settle.
        let a = OriginPin.layout(target: 2, screens: [
            screen(1, 1440, 900, at: CGPoint(x: -1440, y: 0)),
            screen(2, 1194, 834, at: .zero),
            screen(3, 2560, 1440, at: CGPoint(x: 1194, y: 0)),
        ])
        let b = OriginPin.layout(target: 2, screens: [
            screen(1, 1440, 900, at: CGPoint(x: 3754, y: 200)),
            screen(2, 1194, 834, at: CGPoint(x: 2560, y: -600)),
            screen(3, 2560, 1440, at: .zero),
        ])
        XCTAssertEqual(a, b)
    }

    func testAnArrangementThatIsAlreadyRightHasNoDrift() {
        // The steady state: the tick costs a read and no transaction at all.
        let screens = [screen(2, 1194, 834, at: .zero),
                       screen(1, 1440, 900, at: CGPoint(x: 1194, y: 0))]
        XCTAssertTrue(OriginPin.drift(target: 2, screens: screens).isEmpty)
    }

    func testDriftNamesOnlyTheDisplaysThatHaveToMove() {
        // The target is right; a sibling was dragged. Only the sibling moves.
        let screens = [screen(2, 1194, 834, at: .zero),
                       screen(1, 1440, 900, at: CGPoint(x: 5000, y: 300))]
        XCTAssertEqual(OriginPin.drift(target: 2, screens: screens),
                       [OriginPin.Placement(id: 1, origin: CGPoint(x: 1194, y: 0))])
    }

    func testTheRoundFiveSessionHadDrift() {
        let screens = [screen(158, 1194, 834, at: .zero),
                       screen(159, 1194, 834, at: CGPoint(x: 1194, y: 0))]
        XCTAssertEqual(OriginPin.drift(target: 159, screens: screens).count, 2,
                       "both displays had to move; asking for one of them was the bug")
    }

    func testDriftIsEmptyForADisplayThatIsNotThere() {
        XCTAssertTrue(OriginPin.drift(target: 42, screens: [screen(1, 1440, 900)]).isEmpty)
    }

    // MARK: - What each layout means

    func testRemoteAndExtendShareTheCapturePipeline() {
        XCTAssertEqual(SessionLayout.remote.captureMode, .extend)
        XCTAssertEqual(SessionLayout.extend.captureMode, .extend)
        XCTAssertEqual(SessionLayout.mirror.captureMode, .mirror)
    }

    func testOnlyRemotePinsTheDisplayToTheOrigin() {
        XCTAssertTrue(SessionLayout.remote.pinsDisplayToMain)
        XCTAssertFalse(SessionLayout.extend.pinsDisplayToMain)
        XCTAssertFalse(SessionLayout.mirror.pinsDisplayToMain)
    }

    func testArrangementMemoryAndThePinAreMutuallyExclusive() {
        // The field failure in one assertion: the remembered origin is what
        // moved the display back off (0,0) two seconds after the watchdog put
        // it there. A layout may own the origin or remember one, never both.
        for layout in SessionLayout.allCases {
            XCTAssertFalse(layout.pinsDisplayToMain && layout.remembersArrangement,
                           "\(layout.rawValue) both pins and remembers")
        }
        XCTAssertTrue(SessionLayout.extend.remembersArrangement)
        XCTAssertFalse(SessionLayout.remote.remembersArrangement)
        // Mirror builds no virtual display at all, so it has nothing to
        // remember and nothing to pin.
        XCTAssertFalse(SessionLayout.mirror.remembersArrangement)
    }

    func testEveryLayoutIsSelectableAndRoundTripsThroughItsRawValue() {
        XCTAssertEqual(SessionLayout.allCases.count, 3)
        for layout in SessionLayout.allCases {
            XCTAssertEqual(SessionLayout(rawValue: layout.rawValue), layout)
            XCTAssertEqual(layout.id, layout.rawValue)
            XCTAssertFalse(layout.label.isEmpty)
            XCTAssertFalse(layout.hint.isEmpty)
        }
    }

    func testTheDefaultsKeysAreTheOnesDocumentedInTheReport() {
        XCTAssertEqual(SessionLayout.defaultsKey, "sessionLayout")
        XCTAssertEqual(SessionLayout.legacyModeKey, "mode")
    }
}
