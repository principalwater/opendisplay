import CoreGraphics
import XCTest

/// Bringing the desktop onto the session display (§46).
///
/// The geometry is in the global *display* space that `CGDisplayBounds` and the
/// Accessibility API share: origin at the top-left of the main display, **y
/// increasing downwards**. AppKit's `NSScreen` frames are the other way up,
/// which is exactly the sort of detail that earns a pure function.
final class WindowGatherPolicyTests: XCTestCase {

    /// The round-6 arrangement, after the origin pin: the iPad at (0,0) and a
    /// BetterDisplay placeholder to its right.
    private let iPad = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let other = CGRect(x: 1194, y: 0, width: 1920, height: 1080)

    private func window(_ frame: CGRect, subrole: String? = "AXStandardWindow",
                        minimized: Bool = false, fullScreen: Bool = false,
                        settable: Bool = true) -> WindowGatherPolicy.WindowFacts {
        .init(frame: frame, subrole: subrole, minimized: minimized,
              fullScreen: fullScreen, positionSettable: settable)
    }

    // MARK: - Eligibility

    func testAnOrdinaryWindowOnAnotherDisplayIsMoved() {
        XCTAssertNil(WindowGatherPolicy.skipReason(
            window(CGRect(x: 1400, y: 200, width: 900, height: 600)), target: iPad))
    }

    func testAWindowAlreadyOnTheSessionDisplayIsLeftAlone() {
        XCTAssertEqual(WindowGatherPolicy.skipReason(
            window(CGRect(x: 40, y: 60, width: 500, height: 400)), target: iPad),
                       .alreadyThere)
    }

    func testAWindowWiderThanTheSessionDisplayStillCountsAsOnIt() {
        // The test is the origin, not the whole frame: a 1600 pt window on a
        // 1194 pt display is where we want it even though it spills.
        XCTAssertEqual(WindowGatherPolicy.skipReason(
            window(CGRect(x: 10, y: 40, width: 1600, height: 900)), target: iPad),
                       .alreadyThere)
    }

    func testPanelsSheetsAndSystemWindowsAreNeverTouched() {
        for subrole in ["AXFloatingWindow", "AXSystemFloatingWindow", "AXDialog",
                        "AXSystemDialog", "AXUnknown"] {
            XCTAssertEqual(WindowGatherPolicy.skipReason(
                window(CGRect(x: 1400, y: 200, width: 300, height: 200), subrole: subrole),
                target: iPad), .notStandard, subrole)
        }
        XCTAssertEqual(WindowGatherPolicy.skipReason(
            window(CGRect(x: 1400, y: 200, width: 300, height: 200), subrole: nil),
            target: iPad), .notStandard)
    }

    func testMinimisedAndFullscreenWindowsAreSkipped() {
        let frame = CGRect(x: 1400, y: 200, width: 900, height: 600)
        XCTAssertEqual(WindowGatherPolicy.skipReason(window(frame, minimized: true),
                                                     target: iPad), .minimised)
        XCTAssertEqual(WindowGatherPolicy.skipReason(window(frame, fullScreen: true),
                                                     target: iPad), .fullScreen)
    }

    func testAWindowTheAppWillNotLetUsMoveIsSkippedRatherThanRetried() {
        XCTAssertEqual(WindowGatherPolicy.skipReason(
            window(CGRect(x: 1400, y: 200, width: 900, height: 600), settable: false),
            target: iPad), .notSettable)
    }

    func testAZeroSizedWindowIsNotAWindow() {
        XCTAssertEqual(WindowGatherPolicy.skipReason(
            window(CGRect(x: 1400, y: 200, width: 0, height: 0)), target: iPad),
                       .degenerate)
    }

    // MARK: - Where it lands

    func testRelativePositionIsPreserved() {
        // A window a quarter across and a fifth down a 1920×1080 monitor lands
        // a quarter across and a fifth down the iPad.
        let frame = CGRect(x: other.minX + 480, y: 216, width: 400, height: 300)
        let p = WindowGatherPolicy.destination(for: frame, from: other, to: iPad,
                                               menuBarInset: 25)
        XCTAssertEqual(p.x, 1194 * 0.25, accuracy: 0.5)
        XCTAssertEqual(p.y, 834 * 0.2, accuracy: 0.5)
    }

    func testTheTitleBarIsNeverPutUnderTheMenuBar() {
        // A window at the very top of a monitor would land at y = 0 on a
        // display that now has the menu bar.
        let frame = CGRect(x: other.minX + 10, y: 0, width: 400, height: 300)
        let p = WindowGatherPolicy.destination(for: frame, from: other, to: iPad,
                                               menuBarInset: 25)
        XCTAssertGreaterThanOrEqual(p.y, 25)
    }

    func testATallWindowKeepsItsTitleBarOnTheDisplay() {
        // The failure this clamp exists for: a 1440 pt-tall window placed by
        // relative position on an 834 pt display would have its title bar below
        // the bottom edge, and a window whose title bar is off-screen cannot be
        // dragged back.
        let frame = CGRect(x: other.minX + 100, y: 900, width: 1200, height: 1440)
        let p = WindowGatherPolicy.destination(for: frame, from: other, to: iPad,
                                               menuBarInset: 25)
        XCTAssertLessThanOrEqual(p.y, iPad.maxY - 25)
        XCTAssertGreaterThanOrEqual(p.y, 25)
    }

    func testSomethingAlwaysStaysGrabbableHorizontally() {
        let frame = CGRect(x: other.maxX - 20, y: 300, width: 900, height: 600)
        let p = WindowGatherPolicy.destination(for: frame, from: other, to: iPad,
                                               menuBarInset: 25, minVisible: 80)
        XCTAssertLessThanOrEqual(p.x, iPad.maxX - 80)
        XCTAssertGreaterThanOrEqual(p.x + 900, iPad.minX + 80)
    }

    func testAWindowOnNoDisplayAtAllDegradesToAClamp() {
        // An origin that falls on no display (an app restoring a stale frame)
        // has no source rectangle. It must still land somewhere reachable.
        let frame = CGRect(x: -5000, y: -5000, width: 600, height: 400)
        let p = WindowGatherPolicy.destination(for: frame, from: .zero, to: iPad)
        XCTAssertTrue(iPad.insetBy(dx: -600, dy: 0).contains(p), "\(p)")
        XCTAssertGreaterThanOrEqual(p.y, 25)
    }

    // MARK: - Putting them back

    func testAWindowTheUserMovedThemselvesIsNotPutBack() {
        XCTAssertFalse(WindowGatherPolicy.shouldRestore(current: CGPoint(x: 400, y: 400),
                                                        weLeftItAt: CGPoint(x: 10, y: 30)))
    }

    func testRoundingDoesNotCountAsTheUserMovingIt() {
        XCTAssertTrue(WindowGatherPolicy.shouldRestore(current: CGPoint(x: 11, y: 32),
                                                       weLeftItAt: CGPoint(x: 10, y: 30)))
    }

    // MARK: - The setting and the line

    func testGatheringIsOnByDefaultAndCanBeTurnedOff() {
        let defaults = UserDefaults(suiteName: "WindowGatherPolicyTests")!
        defaults.removePersistentDomain(forName: "WindowGatherPolicyTests")
        XCTAssertTrue(WindowGatherPolicy.enabled(defaults))
        defaults.set(false, forKey: WindowGatherPolicy.defaultsKey)
        XCTAssertFalse(WindowGatherPolicy.enabled(defaults))
        defaults.set(true, forKey: WindowGatherPolicy.defaultsKey)
        XCTAssertTrue(WindowGatherPolicy.enabled(defaults))
        defaults.removePersistentDomain(forName: "WindowGatherPolicyTests")
    }

    func testTheSummaryIsCountsRatherThanALinePerWindow() {
        let line = WindowGatherPolicy.summary(
            moved: 17, skipped: [.fullScreen: 3, .minimised: 1], failed: 2, apps: 6)
        XCTAssertTrue(line.contains("moved 17 windows"), line)
        XCTAssertTrue(line.contains("6 applications"), line)
        XCTAssertTrue(line.contains("3 fullscreen"), line)
        XCTAssertTrue(line.contains("1 minimised"), line)
        XCTAssertTrue(line.contains("2 would not move"), line)
    }

    func testASilentSummaryWhenNothingWasSkipped() {
        let line = WindowGatherPolicy.summary(moved: 1, skipped: [:], failed: 0, apps: 1)
        XCTAssertEqual(line, "gather windows: moved 1 window from 1 application "
                       + "onto the session display")
    }
}
