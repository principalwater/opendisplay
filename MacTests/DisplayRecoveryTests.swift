import Foundation
import XCTest

final class DisplayRecoveryTests: XCTestCase {
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
