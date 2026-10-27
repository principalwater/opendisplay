import XCTest

final class BonjourDialRecoveryTests: XCTestCase {
  func testNewServiceCannotSpendFiveSecondsOnAnUnresolvedFirstAttempt() {
    var recovery = BonjourDialRecovery()
    let first = recovery.nextAttempt(isService: true)
    XCTAssertLessThanOrEqual(first.timeout + first.retry, 1)
    let later = recovery.nextAttempt(isService: true)
    XCTAssertEqual(later.timeout, 5)
    XCTAssertGreaterThanOrEqual(later.retry, 1)
  }

  func testPersistentAbsenceNeverBecomesAFastPollingLoop() {
    var recovery = BonjourDialRecovery()
    let attempts = (0..<100).map { _ in recovery.nextAttempt(isService: true) }
    XCTAssertEqual(attempts.filter { $0.timeout < 5 }.count, 1)
    XCTAssertEqual(attempts.filter { $0.retry == 0 }.count, 1)
  }

  func testDirectHostsKeepTheirExistingDeadlineAndServiceAppearanceGetsANewBudget() {
    var recovery = BonjourDialRecovery()
    XCTAssertEqual(recovery.nextAttempt(isService: false).timeout, 5)
    XCTAssertLessThanOrEqual(recovery.nextAttempt(isService: true).timeout, 1)
    recovery = BonjourDialRecovery()
    XCTAssertLessThanOrEqual(recovery.nextAttempt(isService: true).timeout, 1)
  }
}
