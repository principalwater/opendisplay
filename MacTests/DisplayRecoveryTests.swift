import Foundation
import XCTest

final class DisplayRecoveryTests: XCTestCase {
  func testRestoreGeometryUsesSavedPositionsAndPreservesUnrestoredPanels() {
    let original = PhysicalDisplay(id: 1, uuid: UUID(), x: 0, y: 0, mode: 1)
    let unrelated = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
    let current: [UInt32: CGRect] = [
      1: CGRect(x: 1194, y: 0, width: 2048, height: 1152),
      2: unrelated
    ]
    let planned = NativeDisplayBackend.restorationBounds(current: current, restoring: [original])
    XCTAssertTrue(planned.contains(CGRect(x: 0, y: 0, width: 2048, height: 1152)))
    XCTAssertTrue(planned.contains(unrelated))
    let capture = CGRect(x: 0, y: 0, width: 1194, height: 834)
    XCTAssertTrue(planned.contains(where: { $0.intersects(capture) }),
      "The retained capture must be moved out of the restored main panel's way")
    XCTAssertEqual(planned.map(\.maxX).max(), 2048)
    XCTAssertFalse(planned.contains(where: {
      $0.intersects(CGRect(x: 6000, y: 0, width: 1000, height: 800))
    }), "An unrelated distant virtual display needs no movement")
  }

  func testJournalSurvivesOwnerExitAndRejectsRecycledBootIDs() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "display-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = PhysicalDisplay(id: 42, uuid: UUID(), x: -1920, y: 120, mode: 17)
    do {
      let store = DisplayRecoveryStore(directory: directory)
      try store.acquire()
      try store.write([original])
    }
    let replacement = DisplayRecoveryStore(directory: directory)
    try replacement.acquire()
    XCTAssertEqual(try replacement.read(), [original])
    let stale = DisplayRecovery(boot: "a-different-boot", displays: [original])
    try JSONEncoder().encode(stale).write(
      to: directory.appendingPathComponent("physical-displays.json"), options: .atomic)
    XCTAssertEqual(try replacement.read(), [])
  }

  func testSecondOwnerCannotOverwriteRecoveryAndSymlinkIsRejected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "display-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = DisplayRecoveryStore(directory: directory)
    try owner.acquire()
    let contender = DisplayRecoveryStore(directory: directory)
    XCTAssertThrowsError(try contender.acquire())
    let target = directory.appendingPathComponent("unrelated.json")
    let bytes = Data("unrelated user file".utf8)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("physical-displays.json"),
      withDestinationURL: target)
    XCTAssertThrowsError(try owner.read())
    XCTAssertEqual(try Data(contentsOf: target), bytes)
  }

  func testMalformedJournalCannotAuthorizeDisplayChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "display-recovery-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let owner = DisplayRecoveryStore(directory: directory)
    try owner.acquire()
    let panel = PhysicalDisplay(id: 42, uuid: UUID(), x: 0, y: 0, mode: 17)
    try owner.write([panel])
    XCTAssertThrowsError(try owner.write([panel, panel]))
    XCTAssertEqual(try owner.read(), [panel])
    let duplicate = DisplayRecovery(boot: try DisplayRecoveryStore.bootSession(),
      displays: [panel, panel])
    try JSONEncoder().encode(duplicate).write(
      to: directory.appendingPathComponent("physical-displays.json"), options: .atomic)
    XCTAssertThrowsError(try owner.read())
  }

  func testRemoteIntentMustReferenceUniqueLiveCaptureCandidates() throws {
    let accepted = DisplayIntent(preparing: true, captures: [41, 42], remotes: [42])
    XCTAssertNoThrow(try accepted.validate())
    for rejected in [
      DisplayIntent(captures: [0]),
      DisplayIntent(captures: [41, 41]),
      DisplayIntent(captures: [41], remotes: [42]),
      DisplayIntent(captures: [41], remotes: [41, 41]),
      DisplayIntent(captures: Array(1...33))
    ] {
      XCTAssertThrowsError(try rejected.validate())
    }
  }
}
