import Darwin
import Foundation
import Security

/// Main-actor session ownership; the native child keeps recovery alive beyond this process.
@MainActor
final class DisplaySessionController {
  static let shared = DisplaySessionController()

  private struct Session {
    var remote: Bool
    var display: UInt32?
  }

  var onStatus: ((String?) -> Void)?
  private var sessions: [ObjectIdentifier: Session] = [:]
  private var process: Process?
  private var commands: FileHandle?
  private var responses = Data()
  private var sequence: UInt64 = 0
  private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
  private var shuttingDown = false
  private var physicalControlFailed = false
  private var recoveryRestarted = false

  func start() {
    guard process == nil, !shuttingDown else { return }
    do {
      guard let executable = Bundle.main.url(forAuxiliaryExecutable: "OpenDisplayDisplayAgent")
      else { throw DisplayControlError.unavailableSymbol }
      try validateSignature(Bundle.main.bundleURL)
      try validateSignature(executable)
      let child = Process()
      let input = Pipe()
      let output = Pipe()
      let errors = Pipe()
      guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw DisplayControlError.journalUnavailable
      }
      child.executableURL = executable
      child.arguments = ["--state-directory", stateDirectory.path]
      child.standardInput = input
      child.standardOutput = output
      child.standardError = errors
      output.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        Task { @MainActor in
          guard let self, let child, self.process === child else { return }
          if data.isEmpty, child.isRunning, !self.shuttingDown {
            self.report("Display-agent connection closed; restoring local displays")
            child.terminate()
            return
          }
          self.receive(data)
        }
      }
      errors.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty { handle.readabilityHandler = nil }
        if !data.isEmpty, let message = String(data: data, encoding: .utf8) {
          Log.info("display agent: \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
      }
      child.terminationHandler = { [weak self] child in
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        Task { @MainActor in
          guard let self, self.process === child else { return }
          self.process = nil
          self.commands = nil
          self.responses.removeAll()
          self.finishWaiters(through: UInt64.max)
          guard !self.shuttingDown else { return }
          self.physicalControlFailed = true
          self.report("Display agent stopped; restoring local displays")
          await self.recoverAfterAgentExit()
        }
      }
      try child.run()
      // Only this writer owns the lifetime lease; no inherited spare writer keeps EOF away.
      try input.fileHandleForReading.close()
      try output.fileHandleForWriting.close()
      try errors.fileHandleForWriting.close()
      commands = input.fileHandleForWriting
      process = child
      responses.removeAll()
      _ = send()
    } catch {
      report("Native display control unavailable: \(error)")
    }
  }

  func prepare(session: ObjectIdentifier, remote: Bool) async {
    guard !shuttingDown else { return }
    if sessions.isEmpty {
      physicalControlFailed = false
      recoveryRestarted = false
    }
    sessions[session] = Session(remote: remote)
    start()
    guard let submitted = send() else { return }
    await withCheckedContinuation { continuation in
      waiters[submitted] = continuation
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard let self, let pending = self.waiters.removeValue(forKey: submitted) else { return }
        self.physicalControlFailed = true
        self.report("Native display preparation timed out; keeping local displays available")
        pending.resume()
        _ = self.send()
      }
    }
  }

  func captureReady(session: ObjectIdentifier, display: UInt32, remote: Bool) {
    guard !shuttingDown else { return }
    sessions[session] = Session(remote: remote, display: display)
    _ = send()
  }

  func end(session: ObjectIdentifier) {
    sessions.removeValue(forKey: session)
    _ = send()
  }

  func captureReleased(session: ObjectIdentifier, display: UInt32) {
    guard sessions[session]?.display == display else { return }
    sessions[session]?.display = nil
    _ = send()
  }

  func shutdown() {
    guard !shuttingDown else { return }
    shuttingDown = true
    sessions.removeAll()
    _ = send()
    try? commands?.close()
    commands = nil
  }

  private var stateDirectory: URL {
    let bundle = Bundle.main.bundleIdentifier ?? "com.peetzweg.opensidecar.mac.debug"
    if bundle.hasSuffix(".debug") {
      return DisplayRecoveryStore.defaultDirectory.deletingLastPathComponent()
        .appendingPathComponent("Debug Display Recovery", isDirectory: true)
    }
    return DisplayRecoveryStore.defaultDirectory
  }

  private func validateSignature(_ url: URL) throws {
    var code: SecStaticCode?
    let create = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
    guard create == errSecSuccess, let code else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(create))
    }
    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
      | kSecCSCheckNestedCode)
    let result = SecStaticCodeCheckValidity(code, flags, nil)
    guard result == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
    }
  }

  @discardableResult
  private func send() -> UInt64? {
    guard let commands else { return nil }
    sequence += 1
    let entries = Array(sessions.values)
    let intent = DisplayIntent(sequence: sequence,
      preparing: entries.contains(where: \.remote),
      captures: entries.compactMap(\.display).sorted(),
      remotes: physicalControlFailed ? [] : entries.filter(\.remote).compactMap(\.display).sorted(),
      shutdown: shuttingDown)
    do {
      try intent.validate()
      try commands.write(contentsOf: JSONEncoder().encode(intent) + Data([10]))
      return sequence
    } catch {
      physicalControlFailed = true
      report("Native display command failed: \(error)")
      return nil
    }
  }

  private func receive(_ data: Data) {
    guard !data.isEmpty else { return }
    responses.append(data)
    guard responses.count <= 65_536 else {
      report("Invalid display-agent response")
      process?.terminate()
      return
    }
    while let end = responses.firstIndex(of: 10) {
      do {
        let status = try JSONDecoder().decode(DisplayAgentStatus.self,
          from: responses.prefix(upTo: end))
        guard status.sequence <= sequence, status.disabled.count <= 32 else {
          throw DisplayControlError.invalidIntent
        }
        finishWaiters(through: status.sequence)
        if let error = status.error {
          physicalControlFailed = true
          Log.info("native display control: \(error)")
          onStatus?("Local displays remain on because their connection could not be changed.")
        } else if physicalControlFailed {
          onStatus?("Local displays kept on after a display-control failure")
        } else {
          onStatus?(nil)
        }
        Log.info("native displays: off=\(status.disabled) fallback=\(status.fallback ?? 0)")
      } catch {
        report("Invalid display-agent response: \(error)")
        process?.terminate()
      }
      responses.removeSubrange(...end)
    }
  }

  private func finishWaiters(through sequence: UInt64) {
    for key in waiters.keys.filter({ $0 <= sequence }) {
      waiters.removeValue(forKey: key)?.resume()
    }
  }

  private func report(_ message: String) {
    onStatus?(message)
    Log.info(message)
  }

  private func recoverAfterAgentExit() async {
    do {
      let store = DisplayRecoveryStore(directory: stateDirectory)
      try store.acquire()
      let backend = try NativeDisplayBackend()
      for attempt in 0..<4 {
        if try backend.recover(store).isEmpty { break }
        try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
      }
    } catch { report("Local display recovery pending: \(error)") }
    // One recovery-only restart also restores the headless fallback; do not repeat a crash loop.
    if process == nil, !shuttingDown, !recoveryRestarted {
      recoveryRestarted = true
      start()
    }
  }
}
