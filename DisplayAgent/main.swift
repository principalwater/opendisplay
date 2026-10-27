import AppKit
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

/// The pipe is a lifetime lease: EOF restores panels even after the sender is SIGKILLed.
final class DisplayAgent {
  private let backend: NativeDisplayBackend
  private let store: DisplayRecoveryStore
  private var intent = DisplayIntent()
  private var baseline: [PhysicalDisplay] = []
  private var disabled: [PhysicalDisplay] = []
  private var fallback: CGVirtualDisplay?
  private var fallbackToken: UUID?
  private var captureGrace = RemoteCaptureGrace()
  private var assertions: [IOPMAssertionID] = []
  private var input = Data()
  private var inputSource: DispatchSourceRead?
  private var signalSources: [DispatchSourceSignal] = []
  private var work: DispatchWorkItem?
  private var workDeadline: TimeInterval?
  private var workGeneration: UInt64 = 0
  private var restoreAttempts = 0
  private var fallbackAttempts = 0
  private var blocked = false
  private var stopping = false
  private var lastError: String?
  private var lastStatus: Data?
  private var disconnectAttempts: [UUID: (since: TimeInterval, count: Int)] = [:]

  init(directory: URL) throws {
    backend = try NativeDisplayBackend()
    store = DisplayRecoveryStore(directory: directory)
    try store.acquire()
    disabled = try backend.recover(store)
  }

  func start() throws {
    signal(SIGPIPE, SIG_IGN)
    let result = CGDisplayRegisterReconfigurationCallback({ _, flags, context in
      guard !flags.contains(.beginConfigurationFlag), let context else { return }
      let agent = Unmanaged<DisplayAgent>.fromOpaque(context).takeUnretainedValue()
      DispatchQueue.main.async {
        if flags.contains(.addFlag) { agent.restoreAttempts = 0 }
        agent.schedule()
      }
    }, Unmanaged.passUnretained(self).toOpaque())
    guard result == .success else { throw DisplayControlError.displayQuery(result.rawValue) }
    guard fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) == 0 else {
      throw DisplayControlError.journalUnavailable
    }
    let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
    source.setEventHandler { [weak self] in self?.readInput() }
    source.resume()
    inputSource = source
    for number in [SIGTERM, SIGINT, SIGHUP] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in self?.stop() }
      source.resume()
      signalSources.append(source)
    }
    reconcile()
  }

  private func readInput() {
    guard !stopping else { return }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count == 0 { stop(); return }
    guard count > 0 else {
      if errno != EAGAIN && errno != EINTR { stop() }
      return
    }
    input.append(contentsOf: bytes.prefix(count))
    guard input.count <= 65_536 else { fail("Oversized display command"); stop(); return }
    while let end = input.firstIndex(of: 10) {
      let line = input.prefix(upTo: end)
      do {
        let next = try JSONDecoder().decode(DisplayIntent.self, from: line)
        try next.validate()
        guard next.sequence > intent.sequence else {
          throw DisplayControlError.invalidIntent
        }
        if next.preparing && !intent.preparing {
          baseline = try backend.online().compactMap { backend.physical($0) }
          blocked = false
          lastError = nil
          disconnectAttempts.removeAll()
        }
        intent = next
        restoreAttempts = 0
        fallbackAttempts = 0
        if next.shutdown { stop() } else { reconcile() }
      } catch {
        fail("Invalid display command: \(error)")
        stop()
      }
      if stopping { return }
      input.removeSubrange(...end)
    }
  }

  private func schedule(after delay: TimeInterval = 0.15) {
    let deadline = ProcessInfo.processInfo.systemUptime + delay
    if let pending = workDeadline, pending <= deadline { return }
    work?.cancel()
    workGeneration += 1
    let generation = workGeneration
    let next = DispatchWorkItem { [weak self] in
      guard let self, self.workGeneration == generation else { return }
      self.work = nil
      self.workDeadline = nil
      self.reconcile()
    }
    work = next
    workDeadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: next)
  }

  private func createFallback() throws {
    guard fallback == nil else { return }
    guard fallbackAttempts < 12 else { throw DisplayControlError.unstableTopology }
    let token = UUID()
    fallbackToken = token
    let descriptor = CGVirtualDisplayDescriptor()
    descriptor.setDispatchQueue(.main)
    descriptor.name = "OpenDisplay Recovery Desktop"
    descriptor.maxPixelsWide = 1280
    descriptor.maxPixelsHigh = 800
    descriptor.sizeInMillimeters = CGSize(width: 320, height: 200)
    descriptor.vendorID = 0x5043
    descriptor.productID = 0x4F54
    descriptor.serialNum = 0x48534C53
    descriptor.terminationHandler = { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self, self.fallbackToken == token else { return }
        self.fallbackToken = nil
        self.fallback = nil
        self.fallbackAttempts += 1
        self.schedule()
      }
    }
    let display = CGVirtualDisplay(descriptor: descriptor)
    let settings = CGVirtualDisplaySettings()
    settings.hiDPI = 0
    settings.modes = [CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60)]
    guard display.apply(settings) else { throw DisplayControlError.configuration(-1) }
    fallback = display
  }

  private func keepAwake(_ enabled: Bool) throws {
    if !enabled {
      assertions.forEach { IOPMAssertionRelease($0) }
      assertions.removeAll()
    } else if assertions.isEmpty {
      for kind in [kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventUserIdleDisplaySleep] {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kind as CFString,
          IOPMAssertionLevel(kIOPMAssertionLevelOn), "OpenDisplay remote desktop" as CFString,
          &assertion)
        guard result == kIOReturnSuccess else {
          try keepAwake(false)
          throw DisplayControlError.configuration(result)
        }
        assertions.append(assertion)
      }
    }
  }

  private func reconcile() {
    do {
      let online = try backend.online()
      let captures = intent.captures.filter {
        online.contains($0) && CGDisplayIsActive($0) != 0 && backend.isVirtual($0)
      }
      let now = ProcessInfo.processInfo.systemUptime
      let remote = captureGrace.retainRemote(
        sessionRequested: !stopping && !blocked && intent.preparing,
        captureActive: intent.remotes.contains { captures.contains($0) }, now: now)
      if remote, let deadline = captureGrace.deadline {
        schedule(after: max(deadline - now, 0.01))
      }
      if remote {
        try createFallback()
        guard let fallback, CGDisplayIsActive(fallback.displayID) != 0 else {
          fallbackAttempts += 1
          guard fallbackAttempts <= 12 else {
            throw DisplayControlError.configuration(-1)
          }
          schedule(after: 0.25)
          publish()
          return
        }
        try keepAwake(true)
        let targets = online.compactMap { backend.physical($0) }.map { panel in
          var saved = disabled.first(where: { $0.uuid == panel.uuid })
            ?? baseline.first(where: { $0.uuid == panel.uuid }) ?? panel
          saved.id = panel.id
          return saved
        }
        if !targets.isEmpty {
          let now = ProcessInfo.processInfo.systemUptime
          for panel in targets {
            let prior = disconnectAttempts[panel.uuid] ?? (since: now, count: 0)
            let recent = now - prior.since < 10
            let count = recent ? prior.count + 1 : 1
            guard count <= 3 else { throw DisplayControlError.unstableTopology }
            disconnectAttempts[panel.uuid] = (recent ? prior.since : now, count)
          }
          let updated = Set(targets.map(\.uuid))
          let saved = disabled.filter { !updated.contains($0.uuid) } + targets
          try store.write(saved)  // Persist ownership BEFORE the first irreversible request.
          disabled = saved
          do {
            try backend.change(targets, enabled: false)
          } catch {
            // Some drivers apply the change and still return illegalArgument.
            guard targets.allSatisfy({ CGDisplayIsOnline($0.id) == 0 }) else { throw error }
          }
          if targets.contains(where: { CGDisplayIsOnline($0.id) != 0 }) {
            throw DisplayControlError.configuration(-1)
          }
        }
      } else {
        if !disabled.isEmpty, restoreAttempts < 4 {
          restoreAttempts += 1
          disabled = try backend.recover(store)
          if !disabled.isEmpty { schedule(after: Double(restoreAttempts) * 0.5) }
        }
        let headed = try backend.online().contains { backend.physical($0) != nil }
        if headed {
          fallbackToken = nil
          fallback = nil
        } else if !stopping {
          try createFallback()
        }
        try keepAwake(!stopping && (!headed || !captures.isEmpty))
        if !intent.preparing, disabled.isEmpty { baseline.removeAll(); blocked = false }
      }
      publish()
    } catch {
      if stopping { restoreAttempts += 1 }
      blocked = true
      fail("Native display transition refused: \(error)")
      do { disabled = try backend.recover(store) } catch {
        fail("Physical recovery pending: \(error)")
      }
      publish()
    }
    if stopping {
      if !disabled.isEmpty, restoreAttempts < 4 { schedule(after: 0.5); return }
      try? keepAwake(false)
      // The fallback is retained until restoration has completed or its bounded retry ends.
      fallbackToken = nil
      fallback = nil
      exit(disabled.isEmpty ? 0 : 1)
    }
  }

  private func stop() {
    guard !stopping else { return }
    stopping = true
    inputSource?.cancel()
    inputSource = nil
    input.removeAll()
    work?.cancel()
    work = nil
    workDeadline = nil
    workGeneration += 1
    restoreAttempts = 0
    reconcile()
  }

  private func fail(_ message: String) {
    lastError = message
    let data = Data((message + "\n").utf8)
    data.withUnsafeBytes { bytes in
      if let address = bytes.baseAddress { _ = write(STDERR_FILENO, address, bytes.count) }
    }
  }

  private func publish() {
    let status = DisplayAgentStatus(sequence: intent.sequence,
      disabled: disabled.map(\.id), fallback: fallback?.displayID, error: lastError)
    guard let data = try? JSONEncoder().encode(status), data != lastStatus else { return }
    lastStatus = data
    let line = data + Data([10])
    line.withUnsafeBytes { bytes in
      if let address = bytes.baseAddress { _ = write(STDOUT_FILENO, address, bytes.count) }
    }
  }
}

do {
  let arguments = CommandLine.arguments
  let directory: URL
  if arguments.count == 3, arguments[1] == "--state-directory" {
    directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
  } else if arguments.count == 1 {
    directory = DisplayRecoveryStore.defaultDirectory
  } else {
    throw DisplayControlError.invalidIntent
  }
  let application = NSApplication.shared
  application.setActivationPolicy(.prohibited)
  application.finishLaunching()
  let agent = try DisplayAgent(directory: directory)
  try agent.start()
  // CoreGraphics caches stay stale unless the process consumes WindowServer events.
  withExtendedLifetime(agent) { application.run() }
} catch {
  fputs("OpenDisplay display agent: \(error)\n", stderr)
  exit(1)
}
