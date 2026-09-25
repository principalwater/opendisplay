import XCTest

/// Switching the Mac's keyboard layout from the iPad's Globe key crashed the
/// sender three times on alfheim-home before anyone connected the two events:
/// `TISCreateInputSourceList` asserts it is on the main queue, the key arrives
/// on the sender's control queue, and the trap took the whole process down —
/// after which the watchdog's restart put the session on a new virtual display
/// and the iPad had to reconnect. These tests pin the hop, not the switch: the
/// real Text Input Source call must never run here, or the suite would change
/// the layout of the Mac running it.
final class InputSourceHopTests: XCTestCase {

    func testAKeyThatArrivesOffTheMainQueueIsHandedToItInsteadOfSwitchingInline() {
        var switched = 0
        var handedOff: (() -> Void)?

        InputSourceSwitcher.selectNextOnMain(onMainThread: false,
                                             hopToMain: { handedOff = $0 },
                                             switchNow: { switched += 1 })

        XCTAssertEqual(switched, 0,
                       "the switch ran on the calling queue — this is the crash")
        XCTAssertNotNil(handedOff, "nothing was scheduled, so the layout never changes")

        handedOff?()
        XCTAssertEqual(switched, 1, "the scheduled work is the switch itself")
    }

    func testTheHopHappensOnceSoOneGlobePressIsOneSwitch() {
        var hops = 0

        InputSourceSwitcher.selectNextOnMain(onMainThread: false,
                                             hopToMain: { _ in hops += 1 },
                                             switchNow: { })

        XCTAssertEqual(hops, 1)
    }

    func testACallAlreadyOnTheMainQueueSwitchesInlineWithoutASecondHop() {
        // The menu-bar panel can reach the same code path. Bouncing through
        // `async` from there would delay the switch by a runloop turn for no
        // reason, and would reorder it against whatever the caller does next.
        var switched = 0
        var hops = 0

        InputSourceSwitcher.selectNextOnMain(onMainThread: true,
                                             hopToMain: { _ in hops += 1 },
                                             switchNow: { switched += 1 })

        XCTAssertEqual(switched, 1)
        XCTAssertEqual(hops, 0)
    }
}
