import CoreGraphics
import XCTest

/// Trackpad pointer hover: the `pointer` control message must move the Mac
/// cursor and press nothing.
final class PointerInjectionTests: XCTestCase {

    private var sink: RecordingEventSink!

    private func makeInjector() -> InputInjector {
        sink = RecordingEventSink()
        return InputInjector(displayID: CGMainDisplayID(), sink: sink)
    }

    private func expectedPoint(_ nx: Double, _ ny: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return CGPoint(x: bounds.minX + nx * bounds.width,
                       y: bounds.minY + ny * bounds.height)
    }

    func testHoverPostsAMouseMovedAtTheNormalizedPosition() {
        let injector = makeInjector()
        injector.handlePointerMove(x: 0.25, y: 0.75)

        XCTAssertEqual(sink.events.map(\.type), [.mouseMoved])
        let expected = expectedPoint(0.25, 0.75)
        XCTAssertEqual(sink.events.first?.location.x ?? -1, expected.x, accuracy: 0.5)
        XCTAssertEqual(sink.events.first?.location.y ?? -1, expected.y, accuracy: 0.5)
    }

    func testHoverPressesNothing() {
        let injector = makeInjector()
        injector.handlePointerMove(x: 0.5, y: 0.5)
        XCTAssertFalse(injector.isDown)
        XCTAssertEqual(sink.events.first?.clickState, 0,
                       "a non-zero click state on a move invites a synthesised click")
    }

    func testHoverDoesNotWarpTheCursor() {
        // Unlike the touch path (#218): a hover is a 120 Hz stream and
        // .mouseMoved already re-homes the cursor.
        let injector = makeInjector()
        injector.handlePointerMove(x: 0.5, y: 0.5)
        XCTAssertTrue(sink.warps.isEmpty)
    }

    func testHoverIsIgnoredWhileAButtonIsHeld() {
        // A click-drag owns the cursor. A hover sample landing between two drag
        // samples would tear the drag.
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.1, y: 0.1)
        sink.reset()
        injector.handlePointerMove(x: 0.9, y: 0.9)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testHoverIsIgnoredWhileThePenIsDown() {
        let injector = makeInjector()
        injector.handlePencil(phase: "down", x: 0.2, y: 0.2, pressure: 0.5,
                              azimuth: 0, altitude: 0.5, rotation: 0)
        sink.reset()
        injector.handlePointerMove(x: 0.9, y: 0.9)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testHoverResumesAfterTheButtonIsReleased() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.1, y: 0.1)
        injector.handleTouch(phase: "ended", x: 0.1, y: 0.1)
        sink.reset()
        injector.handlePointerMove(x: 0.6, y: 0.4)
        XCTAssertEqual(sink.events.map(\.type), [.mouseMoved])
    }

    func testHoverEntryStartsAFreshDeltaEpoch() {
        // The pointer leaving and re-entering elsewhere must not be reported as
        // one flick-sized relative move to a game or 3D viewport.
        let injector = makeInjector()
        injector.handlePointer(phase: "began", x: 0.1, y: 0.1)
        injector.handlePointer(phase: "move", x: 0.2, y: 0.1)
        injector.handlePointer(phase: "ended", x: 0.2, y: 0.1)
        sink.reset()

        injector.handlePointer(phase: "began", x: 0.9, y: 0.9)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.type, .mouseMoved)
    }

    func testPointerExitPostsNothing() {
        let injector = makeInjector()
        injector.handlePointer(phase: "began", x: 0.5, y: 0.5)
        sink.reset()
        injector.handlePointer(phase: "ended", x: 0.5, y: 0.5)
        XCTAssertTrue(sink.events.isEmpty, "the Mac cursor stays where it was")
    }

    func testUnknownPointerPhasesAreIgnored() {
        let injector = makeInjector()
        injector.handlePointer(phase: "teleported", x: 0.5, y: 0.5)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testATouchInvalidatesTheHoverDeltaHistory() {
        // A finger drag moves the cursor without any hover sample; the next
        // hover must not measure against the pre-drag position.
        let injector = makeInjector()
        injector.handlePointer(phase: "move", x: 0.1, y: 0.1)
        injector.handleTouch(phase: "began", x: 0.8, y: 0.8)
        injector.handleTouch(phase: "ended", x: 0.8, y: 0.8)
        sink.reset()
        injector.handlePointer(phase: "move", x: 0.15, y: 0.1)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.type, .mouseMoved)
    }

    func testConsecutiveHoversTrackTheLatestPosition() {
        let injector = makeInjector()
        injector.handlePointerMove(x: 0.2, y: 0.2)
        sink.reset()
        injector.handlePointerMove(x: 0.4, y: 0.2)

        let to = expectedPoint(0.4, 0.2)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertEqual(sink.events.first?.location.x ?? -1, to.x, accuracy: 0.5)
    }
}

// MARK: - Round 5: the coordinate mapping, and saying so in the log

/// Normalized-to-desktop mapping.
///
/// The operator's first complaint — "touch taps in Safari opened the
/// NEIGHBOURING tab" — is this arithmetic disagreeing with itself across two
/// moments: a coordinate normalized against one set of display bounds and
/// resolved against another. There is exactly one function now, and this is it.
final class InputGeometryTests: XCTestCase {

    /// A virtual display pinned at the desktop origin: the `remote` layout.
    private let atOrigin = CGRect(x: 0, y: 0, width: 1194, height: 834)
    /// The same display sitting to the right of a 2048-wide panel, which is
    /// where `extend` (and a stale `mode extend`) would put it.
    private let besideTheMac = CGRect(x: 2048, y: 0, width: 1194, height: 834)

    func testTheCornersAreTheCorners() {
        XCTAssertEqual(InputGeometry.point(nx: 0, ny: 0, in: atOrigin), CGPoint(x: 0, y: 0))
        XCTAssertEqual(InputGeometry.point(nx: 1, ny: 1, in: atOrigin), CGPoint(x: 1194, y: 834))
        XCTAssertEqual(InputGeometry.point(nx: 0.5, ny: 0.5, in: atOrigin),
                       CGPoint(x: 597, y: 417))
    }

    func testTheDisplaysOriginIsAddedNotIgnored() {
        // The failure mode this exists to prevent, stated as arithmetic: the
        // same normalized tap is 2048 points apart depending on where the
        // display sits, which on a Safari tab bar is several tabs.
        XCTAssertEqual(InputGeometry.point(nx: 0.5, ny: 0.5, in: besideTheMac),
                       CGPoint(x: 2048 + 597, y: 417))
        let drift = InputGeometry.point(nx: 0.5, ny: 0.5, in: besideTheMac).x
            - InputGeometry.point(nx: 0.5, ny: 0.5, in: atOrigin).x
        XCTAssertEqual(drift, 2048)
    }

    func testCoreGraphicsIsYDownLikeTheWire() {
        // Both the wire (video space, origin top-left) and global CG desktop
        // coordinates count downwards, so there is no flip anywhere — and a
        // flip introduced "to be safe" would put every tap in the mirror image
        // of where it belongs.
        XCTAssertEqual(InputGeometry.point(nx: 0, ny: 0.25, in: atOrigin).y, 208.5)
    }

    func testTheDescriptionCarriesEverythingNeededToDiagnoseAnOffset() {
        // What came in, which display it was resolved against, where that
        // display currently is, what came out, and whether it is main. All five,
        // on one line, because four of them are useless on their own.
        let point = InputGeometry.point(nx: 0.5, ny: 0.5, in: besideTheMac)
        let line = InputGeometry.describe("touch began", nx: 0.5, ny: 0.5,
                                          displayID: 139, bounds: besideTheMac,
                                          point: point, mainDisplayID: 1)
        XCTAssertTrue(line.contains("n=(0.5000,0.5000)"), line)
        XCTAssertTrue(line.contains("display 139"), line)
        XCTAssertTrue(line.contains("bounds=(2048,0 1194x834)"), line)
        XCTAssertTrue(line.contains("→ (2645,417)"), line)
        XCTAssertTrue(line.contains("main=1"), line)
        XCTAssertTrue(line.contains("NOT main"), line)
    }

    func testTheLineIsQuietAboutTheHealthyCase() {
        let line = InputGeometry.describe("pointer move", nx: 0, ny: 0,
                                          displayID: 139, bounds: atOrigin,
                                          point: .zero, mainDisplayID: 139)
        XCTAssertFalse(line.contains("NOT main"))
        XCTAssertFalse(line.contains("\n"), "one line per sample, or it is not rate-limited enough")
    }
}

/// The diagnostics throttle. A touch stream runs at up to 120 Hz and a hover
/// faster; an unthrottled line would be the only thing in the log.
final class InputDiagnosticsRateTests: XCTestCase {

    func testTheFirstSampleAlwaysGetsThrough() {
        var rate = InputDiagnosticsRate(interval: 2)
        XCTAssertTrue(rate.allows(at: 1000))
    }

    func testTheRestOfTheWindowIsSilent() {
        var rate = InputDiagnosticsRate(interval: 2)
        XCTAssertTrue(rate.allows(at: 1000))
        for t in stride(from: 1000.0, to: 1002.0, by: 0.008) {
            XCTAssertFalse(rate.allows(at: t))
        }
    }

    func testTheNextWindowOpensAgain() {
        var rate = InputDiagnosticsRate(interval: 2)
        XCTAssertTrue(rate.allows(at: 1000))
        XCTAssertFalse(rate.allows(at: 1001.9))
        XCTAssertTrue(rate.allows(at: 1002))
    }

    func testTheWindowIsMeasuredFromTheLastLineNotTheLastSample() {
        // Otherwise a continuous gesture would never log at all.
        var rate = InputDiagnosticsRate(interval: 2)
        _ = rate.allows(at: 0)
        for t in stride(from: 0.0, to: 1.9, by: 0.01) { _ = rate.allows(at: t) }
        XCTAssertTrue(rate.allows(at: 2.0))
    }
}
