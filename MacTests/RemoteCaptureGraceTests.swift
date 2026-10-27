import XCTest

final class RemoteCaptureGraceTests: XCTestCase {
  func testPreparationAloneNeverDisconnectsAPanel() {
    var grace = RemoteCaptureGrace()
    XCTAssertFalse(grace.retainRemote(sessionRequested: true, captureActive: false, now: 0))
    XCTAssertNil(grace.deadline)
  }

  func testRebuildGapRetainsOwnershipButCannotExtendItsOwnDeadline() {
    var grace = RemoteCaptureGrace()
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: true, now: 0))
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: false, now: 1))
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: false, now: 5.9))
    XCTAssertFalse(grace.retainRemote(sessionRequested: true, captureActive: false, now: 6))
    XCTAssertFalse(grace.retainRemote(sessionRequested: true, captureActive: false, now: 60))
  }

  func testReplacementResetsGraceAndExplicitEndRestoresImmediately() {
    var grace = RemoteCaptureGrace()
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: true, now: 0))
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: false, now: 1))
    XCTAssertTrue(grace.retainRemote(sessionRequested: true, captureActive: true, now: 2))
    XCTAssertNil(grace.deadline)
    XCTAssertFalse(grace.retainRemote(sessionRequested: false, captureActive: false, now: 2.1))
    XCTAssertNil(grace.deadline)
    XCTAssertFalse(grace.retainRemote(sessionRequested: true, captureActive: false, now: 3))
  }
}
