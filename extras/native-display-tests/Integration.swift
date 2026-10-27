import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Explicit opt-in hardware test: run only with a local physical panel available.
@main
enum NativeDisplayIntegration {
  final class AgentConnection {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var sequence: UInt64 = 0
    var buffered = Data()

    init(executable: String, directory: URL) throws {
      signal(SIGPIPE, SIG_IGN)
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["--state-directory", directory.path]
      process.standardInput = input
      process.standardOutput = output
      process.standardError = FileHandle.standardError
      try process.run()
      try input.fileHandleForReading.close()
      try output.fileHandleForWriting.close()
    }

    func request(_ value: DisplayIntent) throws -> DisplayAgentStatus {
      var value = value
      sequence += 1
      value.sequence = sequence
      try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(value) + Data([10]))
      let deadline = Date().addingTimeInterval(8)
      while Date() < deadline {
        if let end = buffered.firstIndex(of: 10) {
          let status = try JSONDecoder().decode(DisplayAgentStatus.self,
            from: buffered.prefix(upTo: end))
          buffered.removeSubrange(...end)
          if status.sequence >= sequence { return status }
          continue
        }
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
          events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 20) > 0 {
          let data = output.fileHandleForReading.availableData
          guard !data.isEmpty else { throw DisplayControlError.invalidIntent }
          buffered.append(data)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      }
      throw DisplayControlError.configuration(-2)
    }

    func closeLease() throws { try input.fileHandleForWriting.close() }
  }

  static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw NSError(domain: message, code: 1) }
  }

  static func wait(_ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(8)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return false
  }

  static func virtualDisplay() throws -> CGVirtualDisplay {
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(.main)
    descriptor.name = "OpenDisplay Integration Capture"
    descriptor.maxPixelsWide = 1600
    descriptor.maxPixelsHigh = 1000
    descriptor.sizeInMillimeters = CGSize(width: 320, height: 200)
    descriptor.vendorID = 0x5043
    descriptor.productID = 0x4F56
    descriptor.serialNum = UInt32.random(in: 1...UInt32.max)
    descriptor.terminationHandler = { _, _ in }
    let display = CGVirtualDisplay(descriptor: descriptor)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1600, height: 1000, refreshRate: 60)]
    try require(display.apply(settings), "Virtual settings rejected")
    try require(wait { CGDisplayIsActive(display.displayID) != 0 }, "Capture not active")
    return display
  }

  static func owner(agent: String, directory: URL, crash: Bool) throws {
    let backend = try NativeDisplayBackend()
    let physical = try backend.online().compactMap { backend.physical($0) }
    try require(!physical.isEmpty, "A physical display is required")
    let connection = try AgentConnection(executable: agent, directory: directory)
    defer {
      try? connection.closeLease()
      _ = wait { !connection.process.isRunning }
    }
    let preparation = try connection.request(DisplayIntent(preparing: true))
    try require(preparation.error == nil, "Preparation failed")
    let physicalID = physical[0].id
    let invalidCapture = try connection.request(DisplayIntent(preparing: true,
      captures: [physicalID], remotes: [physicalID]))
    try require(invalidCapture.disabled.isEmpty && CGDisplayIsOnline(physicalID) != 0,
      "A physical panel was accepted as the protected virtual capture")
    var display: CGVirtualDisplay? = try virtualDisplay()
    guard let displayID = display?.displayID else { throw DisplayControlError.configuration(-1) }
    try pinCaptureIndependently(displayID)
    let remote = try connection.request(DisplayIntent(preparing: true,
      captures: [displayID], remotes: [displayID]))
    try require(remote.error == nil && remote.fallback != nil, "No independent fallback")
    try require(wait {
      guard let observed = try? snapshotOnline() else { return false }
      return physical.allSatisfy { !observed.contains($0.id) }
    },
      "Physical display was not disconnected")
    let journal = DisplayRecoveryStore(directory: directory)
    let saved = try journal.read()
    try require(Set(saved.map(\.uuid)) == Set(physical.map(\.uuid)), "Missing recovery record")
    print("PASS native disconnect, retained fallback, write-before-off journal")
    try independentSnapshot()
    fflush(stdout)
    let reactivation = Process()
    reactivation.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    reactivation.arguments = ["--reactivate", directory.path]
    try reactivation.run()
    reactivation.waitUntilExit()
    try require(reactivation.terminationStatus == 0, "Independent reactivation failed")
    let disconnectedAgain = wait {
      guard let observed = try? snapshotOnline() else { return false }
      return physical.allSatisfy { !observed.contains($0.id) }
    }
    if !disconnectedAgain {
      print("Observed after reactivation:", try backend.online().map {
        "\($0): active=\(CGDisplayIsActive($0)) virtual=\(backend.isVirtual($0))"
      })
      try independentSnapshot()
      let diagnostic = try connection.request(DisplayIntent(preparing: true,
        captures: [displayID], remotes: [displayID]))
      print("Agent after explicit reconciliation:", diagnostic)
    }
    try require(disconnectedAgain,
      "A reappearing owned physical panel stayed active during the remote session")
    print("PASS reappearing physical panel is disconnected again without losing its recovery record")
    if crash {
      print("Crashing the actual capture owner; agent must restore on EOF")
      fflush(stdout)
      _ = withExtendedLifetime(display) { kill(getpid(), SIGKILL) }
    }
    withExtendedLifetime(display) {}
    display = nil
    let ended = try connection.request(DisplayIntent())
    try require(ended.disabled.isEmpty && ended.fallback == nil,
      "Session end retained physical ownership or the fallback")
    try require(connection.process.isRunning, "Agent exited instead of waiting for another session")
    let returned = try snapshotOnline()
    try require(physical.allSatisfy { returned.contains($0.id) },
      "Session end did not restore panels")
    print("PASS session end restores panels while native agent stays idle")
    _ = try connection.request(DisplayIntent(preparing: true))
    display = try virtualDisplay()
    guard let resumedID = display?.displayID else { throw DisplayControlError.configuration(-1) }
    try pinCaptureIndependently(resumedID)
    let resumed = try connection.request(DisplayIntent(preparing: true,
      captures: [resumedID], remotes: [resumedID]))
    try require(resumed.error == nil && !resumed.disabled.isEmpty,
      "A second session could not acquire physical ownership")
    withExtendedLifetime(display) {}
    display = nil
    try connection.closeLease()
    try require(wait {
      guard let observed = try? snapshotOnline() else { return false }
      return physical.allSatisfy { observed.contains($0.id) }
    },
      "Lease EOF did not restore physical display")
    try require(wait { !connection.process.isRunning }, "Agent did not exit after restoration")
    try require(connection.process.terminationStatus == 0, "Recovery agent failed")
    let restored = try snapshotPhysical()
    for panel in physical {
      let observed = restored.first(where: { $0.uuid == panel.uuid })
      try require(observed?.mode == panel.mode,
        "Physical mode changed")
      try require(observed?.x == panel.x && observed?.y == panel.y,
        "Physical arrangement changed")
    }
    let cleared = try journal.read()
    try require(cleared.isEmpty, "Recovery ownership was not cleared")
    print("PASS ordinary EOF restoration, original physical modes and arrangement")
  }

  static func main() {
    do { try run() } catch {
      fputs("FAIL: \(error)\n", stderr)
      exit(1)
    }
  }

  static func run() throws {
    let arguments = CommandLine.arguments
    if arguments.count == 2, arguments[1] == "--snapshot" {
      let backend = try NativeDisplayBackend()
      let data = try JSONEncoder().encode(backend.online())
      try FileHandle.standardOutput.write(contentsOf: data)
      return
    }
    if arguments.count == 2, arguments[1] == "--physical-state" {
      let backend = try NativeDisplayBackend()
      let data = try JSONEncoder().encode(backend.online().compactMap { backend.physical($0) })
      try FileHandle.standardOutput.write(contentsOf: data)
      return
    }
    if arguments.count == 3, arguments[1] == "--reactivate" {
      let store = DisplayRecoveryStore(directory: URL(fileURLWithPath: arguments[2]))
      let records = try store.read()
      try require(!records.isEmpty, "No actual owned panels to reactivate")
      try NativeDisplayBackend().change(records, enabled: true)
      return
    }
    if arguments.count == 3, arguments[1] == "--pin", let target = UInt32(arguments[2]) {
      try pinCapture(target, backend: NativeDisplayBackend())
      return
    }
    guard arguments.count >= 3 else {
      throw NSError(domain: "Usage: native-display-integration --exercise-hardware AGENT", code: 1)
    }
    if arguments[1] == "--owner", arguments.count == 5 {
      try owner(agent: arguments[2], directory: URL(fileURLWithPath: arguments[3]),
        crash: arguments[4] == "crash")
      return
    }
    try require(arguments[1] == "--exercise-hardware", "Hardware opt-in required")
    let backend = try NativeDisplayBackend()
    let physical = try backend.online().compactMap { backend.physical($0) }
    try require(!physical.isEmpty, "A physical display is required")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "native-display-integration-\(UUID().uuidString)", isDirectory: true)
    print("Evidence: \(directory.path)")
    try owner(agent: arguments[2], directory: directory.appendingPathComponent("normal"),
      crash: false)
    let crashedDirectory = directory.appendingPathComponent("crash")
    let child = Process()
    child.executableURL = URL(fileURLWithPath: arguments[0])
    child.arguments = ["--owner", arguments[2], crashedDirectory.path, "crash"]
    try child.run()
    while child.isRunning { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
      "Owner did not exercise a real SIGKILL")
    try require(wait {
      guard let online = try? snapshotOnline() else { return false }
      return physical.allSatisfy { online.contains($0.id) }
    },
      "Native agent did not restore after parent SIGKILL")
    let recovery = DisplayRecoveryStore(directory: crashedDirectory)
    try require(wait { (try? recovery.read().isEmpty) == true }, "Crash journal remains owned")
    print("PASS real parent SIGKILL recovery without shell, BetterDisplay or polling watchdog")
  }

  static func independentSnapshot() throws {
    print("Fresh process online:", try snapshotOnline())
  }

  static func snapshotOnline() throws -> [UInt32] {
    let snapshot = Process()
    let output = Pipe()
    snapshot.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    snapshot.arguments = ["--snapshot"]
    snapshot.standardOutput = output
    try snapshot.run()
    snapshot.waitUntilExit()
    return try JSONDecoder().decode([UInt32].self,
      from: output.fileHandleForReading.readDataToEndOfFile())
  }

  static func snapshotPhysical() throws -> [PhysicalDisplay] {
    let snapshot = Process()
    let output = Pipe()
    snapshot.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    snapshot.arguments = ["--physical-state"]
    snapshot.standardOutput = output
    try snapshot.run()
    snapshot.waitUntilExit()
    return try JSONDecoder().decode([PhysicalDisplay].self,
      from: output.fileHandleForReading.readDataToEndOfFile())
  }

  static func pinCapture(_ target: UInt32, backend: NativeDisplayBackend) throws {
    var config: CGDisplayConfigRef?
    try require(CGBeginDisplayConfiguration(&config) == .success, "Cannot prepare capture layout")
    var x: Int32 = 0
    let ordered = [target] + (try backend.online()).filter { $0 != target }.sorted()
    for id in ordered {
      guard CGConfigureDisplayOrigin(config, id, x, 0) == .success else {
        CGCancelDisplayConfiguration(config)
        throw DisplayControlError.configuration(-1)
      }
      x += Int32(CGDisplayBounds(id).width)
    }
    try require(CGCompleteDisplayConfiguration(config, .forSession) == .success,
      "Cannot pin the capture display like the real sender")
  }

  static func pinCaptureIndependently(_ target: UInt32) throws {
    let pin = Process()
    pin.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    pin.arguments = ["--pin", String(target)]
    try pin.run()
    pin.waitUntilExit()
    try require(pin.terminationStatus == 0, "Independent capture pin failed")
  }
}
