import XCTest

final class ReceiverStartupGateTests: XCTestCase {
  func testManualStartupWaitsUntilConnectEvenAfterAWholeDay() {
    var gate = ReceiverStartupGate()
    gate.configure(automatically: false, delaySeconds: 3, now: 10)
    XCTAssertFalse(gate.advance(now: 86_410))
    XCTAssertFalse(gate.listeningArmed)
    XCTAssertNil(gate.deadline)
    XCTAssertTrue(gate.connect())
    XCTAssertTrue(gate.listeningArmed)
    XCTAssertFalse(gate.connect(), "A repeated tap must not bind a second listener")
  }

  func testAutomaticStartupAndForegroundResumeShareTheSameDeadline() {
    var gate = ReceiverStartupGate()
    gate.configure(automatically: true, delaySeconds: 3, now: 10)
    XCTAssertFalse(gate.advance(now: 12.9))
    XCTAssertTrue(gate.advance(now: 13))
    XCTAssertFalse(gate.advance(now: 30))
    gate.configure(automatically: false, delaySeconds: 3, now: 31)
    XCTAssertTrue(gate.listeningArmed, "Startup settings must not tear down an existing session")
  }

  func testDisablingAutomaticStartInvalidatesAnAlreadyQueuedTimer() {
    var gate = ReceiverStartupGate()
    gate.configure(automatically: true, delaySeconds: 3, now: 10)
    gate.configure(automatically: false, delaySeconds: 3, now: 11)
    XCTAssertFalse(gate.advance(now: 100))
    XCTAssertFalse(gate.listeningArmed)
    XCTAssertTrue(gate.connect())
  }

  func testDelayBoundsAndManualConnectCancelTheCountdown() {
    var immediate = ReceiverStartupGate()
    immediate.configure(automatically: true, delaySeconds: -1, now: 10)
    XCTAssertTrue(immediate.advance(now: 10))
    var delayed = ReceiverStartupGate()
    delayed.configure(automatically: true, delaySeconds: Int.max, now: 10)
    XCTAssertEqual(delayed.deadline, 15)
    XCTAssertTrue(delayed.connect())
    XCTAssertFalse(delayed.advance(now: 15))
  }
}
