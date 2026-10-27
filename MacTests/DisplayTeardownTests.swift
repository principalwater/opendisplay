import AppKit
import XCTest

final class DisplayTeardownTests: XCTestCase {
  func testWindowCoordinatesFollowDisplayRestorationWithoutOverwritingAUserMove() {
    let offset = CGPoint(x: 100, y: 80)
    let restored = CGRect(x: -2048, y: 120, width: 2048, height: 1152)
    XCTAssertEqual(WindowGatherPolicy.origin(offset: offset, on: restored),
      CGPoint(x: -1948, y: 200))
    let movedCapture = CGRect(x: 2048, y: 0, width: 1194, height: 834)
    let expected = WindowGatherPolicy.origin(offset: offset, on: movedCapture)
    XCTAssertTrue(WindowGatherPolicy.shouldRestore(current: expected, weLeftItAt: expected))
    XCTAssertFalse(WindowGatherPolicy.shouldRestore(current: CGPoint(x: 2300, y: 200),
      weLeftItAt: expected))
  }

  @MainActor
  func testReplacementPreparationWaitsUntilThePreviousDisplayHasBeenReleased() async throws {
    guard Bundle.main.url(forAuxiliaryExecutable: "OpenDisplayDisplayAgent") == nil else {
      throw XCTSkip("This boundary test must not launch a real display agent")
    }
    let controller = DisplaySessionController()
    let oldOwner = NSObject()
    let replacement = NSObject()
    var release: CheckedContinuation<Void, Never>?
    let teardown = Task { @MainActor in
      await withCheckedContinuation { release = $0 }
    }
    controller.trackTeardown(teardown, session: ObjectIdentifier(oldOwner))
    let entered = expectation(description: "replacement entered preparation")
    var finished = false
    let preparing = Task { @MainActor in
      entered.fulfill()
      await controller.prepare(session: ObjectIdentifier(replacement), remote: false)
      finished = true
    }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertFalse(finished, "Reusing a display identity must wait for the old capture release")
    XCTAssertNotNil(release)
    release?.resume()
    await preparing.value
    XCTAssertTrue(finished)
    controller.end(session: ObjectIdentifier(replacement))
    controller.shutdown()
  }
}
