import XCTest

@MainActor
final class DisplayPanelWakeTests: XCTestCase {
  func testAnAwakeDesktopKeepsItsDisplaySleepTimer() async {
    var declarations = 0
    await DisplaySessionController.wakeSleepingPanel(
      isAsleep: { false },
      declareActivity: {
        declarations += 1
        return true
      },
      pause: { XCTFail("nothing to wait for") })
    XCTAssertEqual(declarations, 0)
  }

  func testASleepingPanelIsDeclaredOnceAndAwaitedUntilItWakes() async {
    var answers = [true, true, true, false]
    var declarations = 0
    var pauses = 0
    await DisplaySessionController.wakeSleepingPanel(
      isAsleep: { answers.removeFirst() },
      declareActivity: {
        declarations += 1
        return true
      },
      pause: { pauses += 1 })
    XCTAssertEqual(declarations, 1)
    XCTAssertEqual(pauses, 2)
  }

  func testAPanelThatNeverWakesCannotHoldTheSessionForever() async {
    var declarations = 0
    var pauses = 0
    await DisplaySessionController.wakeSleepingPanel(
      isAsleep: { true },
      declareActivity: {
        declarations += 1
        return true
      },
      pause: { pauses += 1 })
    XCTAssertEqual(declarations, 1)
    XCTAssertEqual(pauses, 50)
  }

  func testARefusedDeclarationDoesNotWait() async {
    await DisplaySessionController.wakeSleepingPanel(
      isAsleep: { true },
      declareActivity: { false },
      pause: { XCTFail("no wake was requested, so there is nothing to wait for") })
  }
}
