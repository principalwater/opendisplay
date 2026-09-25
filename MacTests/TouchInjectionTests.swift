import CoreGraphics
import XCTest

/// What `InputInjector.handleTouch` actually posts, per button. Recorded, never
/// injected (see RecordingEventSink).
final class TouchInjectionTests: XCTestCase {

    private var sink: RecordingEventSink!

    private func makeInjector() -> InputInjector {
        sink = RecordingEventSink()
        return InputInjector(displayID: CGMainDisplayID(), sink: sink)
    }

    func testLeftTouchPostsTheLeftButtonSequence() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        injector.handleTouch(phase: "moved", x: 0.6, y: 0.5)
        injector.handleTouch(phase: "ended", x: 0.6, y: 0.5)

        XCTAssertEqual(sink.events.map(\.type), [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertTrue(sink.events.allSatisfy { $0.mouseButton == 0 })
    }

    func testRightTouchPostsTheRightButtonSequence() {
        // The trackpad secondary click and the two-finger tap both arrive as
        // `button: "right"`; a right-button down/up pair is what opens a
        // context menu on macOS.
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.3, y: 0.3, button: "right")
        injector.handleTouch(phase: "ended", x: 0.3, y: 0.3, button: "right")

        XCTAssertEqual(sink.events.map(\.type), [.rightMouseDown, .rightMouseUp])
        XCTAssertTrue(sink.events.allSatisfy { $0.mouseButton == 1 })
        XCTAssertEqual(sink.events.first?.clickState, 1,
                       "a zero-click down breaks menu tracking")
    }

    func testADragKeepsTheButtonItStartedWith() {
        // Regression for the merged #216 behaviour: `moved` and `ended` carry no
        // `button` field on the wire unless the sender bothers to repeat it, so
        // a right-button drag used to be posted as a *left* drag and a left
        // mouse-up, leaving the right button stuck down.
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.2, y: 0.2, button: "right")
        injector.handleTouch(phase: "moved", x: 0.4, y: 0.4)          // no button field
        injector.handleTouch(phase: "ended", x: 0.4, y: 0.4)          // no button field

        XCTAssertEqual(sink.events.map(\.type), [.rightMouseDown, .rightMouseDragged, .rightMouseUp])
        XCTAssertTrue(sink.events.allSatisfy { $0.mouseButton == 1 })
        XCTAssertFalse(injector.isDown)
    }

    func testAMoveWithNoButtonHeldIsAPlainCursorMove() {
        let injector = makeInjector()
        injector.handleTouch(phase: "moved", x: 0.5, y: 0.5)
        XCTAssertEqual(sink.events.map(\.type), [.mouseMoved])
        XCTAssertFalse(injector.isDown)
    }

    func testTouchesLandOnTheTargetDisplayAndWarpTheCursorThere() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.25, y: 0.75)

        let bounds = CGDisplayBounds(CGMainDisplayID())
        let expected = CGPoint(x: bounds.minX + 0.25 * bounds.width,
                               y: bounds.minY + 0.75 * bounds.height)
        XCTAssertEqual(sink.events.first?.location.x ?? -1, expected.x, accuracy: 0.5)
        XCTAssertEqual(sink.events.first?.location.y ?? -1, expected.y, accuracy: 0.5)
        // Upstream PR #218: the cursor is warped onto the display first.
        XCTAssertEqual(sink.warps.count, 1)
    }

    func testCancelReleasesWithClickStateZero() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        sink.reset()
        injector.handleTouch(phase: "cancelled", x: 0.5, y: 0.5)
        XCTAssertEqual(sink.events.map(\.type), [.leftMouseUp])
        XCTAssertEqual(sink.events.first?.clickState, 0,
                       "a cancel must not be synthesised into a click")
    }

    func testResetReleasesAHeldRightButton() {
        let injector = makeInjector()
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5, button: "right")
        sink.reset()
        injector.reset()
        XCTAssertEqual(sink.events.first?.type, .rightMouseUp)
        XCTAssertEqual(sink.events.first?.mouseButton, 1)
        XCTAssertFalse(injector.isDown)
    }

    func testScrollCarriesBothAxes() {
        let injector = makeInjector()
        injector.handleScroll(dx: 10, dy: -20)
        XCTAssertEqual(sink.events.map(\.type), [.scrollWheel])
        XCTAssertNotEqual(sink.events.first?.scrollAxis1, 0, "vertical")
        XCTAssertNotEqual(sink.events.first?.scrollAxis2, 0, "horizontal")
    }

    func testScrollDistanceFollowsTheEncodedSizeNotTheNativeOne() {
        // The receiver measures deltas in encoded-video pixels. At half
        // quality the stream is half the native width, so the same number of
        // video pixels must travel twice as far on the desktop — otherwise
        // scrolling speed silently depends on the quality setting.
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let native = Int(Double(CGDisplayPixelsWide(CGMainDisplayID())))
        XCTAssertGreaterThan(bounds.width, 0)

        let full = makeInjector()
        full.setEncodedSize(pixelsWide: native, pixelsHigh: 1)
        full.handleScroll(dx: 0, dy: 120)
        let atFullQuality = sink.events.first?.scrollAxis1 ?? 0

        let half = makeInjector()
        half.setEncodedSize(pixelsWide: native / 2, pixelsHigh: 1)
        half.handleScroll(dx: 0, dy: 120)
        let atHalfQuality = sink.events.first?.scrollAxis1 ?? 0

        XCTAssertEqual(Double(atHalfQuality), Double(atFullQuality) * 2, accuracy: 2)
    }

    func testScrollFallsBackToTheNativeScaleBeforeCaptureAnnouncesASize() {
        let injector = makeInjector()
        injector.handleScroll(dx: 0, dy: 120)
        XCTAssertEqual(sink.events.count, 1)
        XCTAssertNotEqual(sink.events.first?.scrollAxis1, 0)
    }
}
