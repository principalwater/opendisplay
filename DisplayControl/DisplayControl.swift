import CoreGraphics
import Darwin
import Foundation

struct DisplayIntent: Codable, Equatable {
  var sequence: UInt64 = 0
  var preparing = false
  var captures: [UInt32] = []
  var remotes: [UInt32] = []
  var shutdown = false

  func validate() throws {
    guard captures.count <= 32, remotes.count <= 32,
      !captures.contains(0), Set(captures).count == captures.count,
      Set(remotes).count == remotes.count,
      Set(remotes).isSubset(of: Set(captures)) else {
      throw DisplayControlError.invalidIntent
    }
  }
}

struct DisplayAgentStatus: Codable {
  var sequence: UInt64
  var disabled: [UInt32]
  var fallback: UInt32?
  var error: String?
}

enum DisplayControlError: Error {
  case unavailableSymbol, displayQuery(Int32), configuration(Int32), invalidIntent
  case invalidJournal, alreadyRunning, journalUnavailable
  case unstableTopology
}

struct PhysicalDisplay: Codable, Equatable {
  var id: UInt32
  let uuid: UUID
  let x: Int32
  let y: Int32
  let mode: Int32
}

/// UUIDs identify panels; opaque display IDs are only recovery hints within one boot.
struct DisplayRecovery: Codable {
  var version = 1
  var boot: String
  var displays: [PhysicalDisplay]
}

final class DisplayRecoveryStore {
  let directory: URL
  private var lockDescriptor: Int32 = -1

  init(directory: URL) { self.directory = directory }

  static var defaultDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("OpenDisplay Alfheim/Display Recovery", isDirectory: true)
  }

  static func bootSession() throws -> String {
    var count = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &count, nil, 0) == 0,
      count > 1, count < 128 else { throw DisplayControlError.journalUnavailable }
    var bytes = [CChar](repeating: 0, count: count)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &count, nil, 0) == 0 else {
      throw DisplayControlError.journalUnavailable
    }
    return String(cString: bytes)
  }

  func acquire() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.appendingPathComponent("owner.lock").path,
      O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw DisplayControlError.journalUnavailable }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      throw DisplayControlError.alreadyRunning
    }
    lockDescriptor = descriptor
  }

  deinit { if lockDescriptor >= 0 { close(lockDescriptor) } }

  func read() throws -> [PhysicalDisplay] {
    let path = directory.appendingPathComponent("physical-displays.json").path
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0, errno == ENOENT { return [] }
    guard descriptor >= 0 else { throw DisplayControlError.invalidJournal }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0, attributes.st_uid == getuid(),
      attributes.st_mode & S_IFMT == S_IFREG, attributes.st_size <= 32_768 else {
      throw DisplayControlError.invalidJournal
    }
    let recovery = try JSONDecoder().decode(DisplayRecovery.self,
      from: handle.readToEnd() ?? Data())
    guard recovery.version == 1, recovery.displays.count <= 32,
      !recovery.displays.contains(where: { $0.id == 0 }),
      Set(recovery.displays.map(\.id)).count == recovery.displays.count,
      Set(recovery.displays.map(\.uuid)).count == recovery.displays.count else {
      throw DisplayControlError.invalidJournal
    }
    return recovery.boot == (try Self.bootSession()) ? recovery.displays : []
  }

  func write(_ displays: [PhysicalDisplay]) throws {
    guard lockDescriptor >= 0 else { throw DisplayControlError.journalUnavailable }
    guard displays.count <= 32, !displays.contains(where: { $0.id == 0 }),
      Set(displays.map(\.id)).count == displays.count,
      Set(displays.map(\.uuid)).count == displays.count else {
      throw DisplayControlError.invalidJournal
    }
    let data = try JSONEncoder().encode(DisplayRecovery(
      boot: Self.bootSession(), displays: displays))
    let destination = directory.appendingPathComponent("physical-displays.json")
    try data.write(to: destination, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
      ofItemAtPath: destination.path)
  }
}

/// Small dynamic boundary around two private system functions; missing APIs fail closed.
final class NativeDisplayBackend {
  private typealias SetEnabled =
    @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> Int32
  private typealias CopyInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
  private let setEnabled: SetEnabled?
  private let copyInfo: CopyInfo

  init() throws {
    let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
      RTLD_LAZY | RTLD_LOCAL)
    guard let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        RTLD_LAZY | RTLD_LOCAL),
      let info = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary") else {
      throw DisplayControlError.unavailableSymbol
    }
    // These handles intentionally live as long as their function pointers (the process).
    let enabled = sky.flatMap {
      dlsym($0, "CGSConfigureDisplayEnabled") ?? dlsym($0, "SLSConfigureDisplayEnabled")
    }
    setEnabled = enabled.map { unsafeBitCast($0, to: SetEnabled.self) }
    copyInfo = unsafeBitCast(info, to: CopyInfo.self)
  }

  func online() throws -> [UInt32] {
    var count: UInt32 = 0
    let query = CGGetOnlineDisplayList(0, nil, &count)
    guard query == .success, count <= 128 else {
      throw DisplayControlError.displayQuery(query.rawValue)
    }
    var ids = [UInt32](repeating: 0, count: Int(max(count, 1)))
    let result = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
    guard result == .success else { throw DisplayControlError.displayQuery(result.rawValue) }
    return Array(ids.prefix(Int(count)))
  }

  func uuid(_ id: UInt32) -> UUID? {
    guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
      return nil
    }
    return UUID(uuidString: CFUUIDCreateString(nil, value) as String)
  }

  func physical(_ id: UInt32) -> PhysicalDisplay? {
    guard let info = copyInfo(id)?.takeRetainedValue() as? [String: Any],
      info["kCGDisplayIsVirtualDevice"] as? Bool == false,
      CGDisplayIsBuiltin(id) != 0 || info["IODisplayLocation"] as? String != nil,
      let uuid = uuid(id) else { return nil }
    let origin = CGDisplayBounds(id).origin
    guard let x = Int32(exactly: origin.x), let y = Int32(exactly: origin.y) else { return nil }
    return PhysicalDisplay(id: id, uuid: uuid, x: x, y: y,
      mode: CGDisplayCopyDisplayMode(id)?.ioDisplayModeID ?? 0)
  }

  func isVirtual(_ id: UInt32) -> Bool {
    guard let info = copyInfo(id)?.takeRetainedValue() as? [String: Any] else { return false }
    return info["kCGDisplayIsVirtualDevice"] as? Bool == true
  }

  func change(_ displays: [PhysicalDisplay], enabled: Bool) throws {
    guard !displays.isEmpty else { return }
    guard let setEnabled else { throw DisplayControlError.unavailableSymbol }
    var config: CGDisplayConfigRef?
    let begin = CGBeginDisplayConfiguration(&config)
    guard begin == .success, let config else {
      throw DisplayControlError.configuration(begin.rawValue)
    }
    for display in displays {
      let result = setEnabled(config, display.id, enabled)
      guard result == 0 else {
        CGCancelDisplayConfiguration(config)
        throw DisplayControlError.configuration(result)
      }
    }
    let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
    guard result == .success else { throw DisplayControlError.configuration(result.rawValue) }
  }

  /// Never address a recycled ID belonging to a different panel.
  func recoveryID(_ display: PhysicalDisplay) -> UInt32? {
    let value = CFUUIDCreateFromString(nil, display.uuid.uuidString as CFString)
    let current = CGDisplayGetDisplayIDFromUUID(value)
    if current != 0, uuid(current) == display.uuid { return current }
    if let observed = uuid(display.id), observed != display.uuid { return nil }
    return display.id
  }

  func restoreLayout(_ displays: [PhysicalDisplay]) throws {
    let online = try online()
    let restored = displays.filter { online.contains($0.id) && uuid($0.id) == $0.uuid }
    guard !restored.isEmpty else { return }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success, let config else {
      throw DisplayControlError.configuration(-1)
    }
    var failure: CGError = .success
    for display in restored {
      failure = CGConfigureDisplayOrigin(config, display.id, display.x, display.y)
      if failure != .success { break }
      if let modes = CGDisplayCopyAllDisplayModes(display.id, nil) as? [CGDisplayMode],
        let mode = modes.first(where: { $0.ioDisplayModeID == display.mode }),
        CGDisplayCopyDisplayMode(display.id)?.ioDisplayModeID != mode.ioDisplayModeID {
        failure = CGConfigureDisplayWithDisplayMode(config, display.id, mode, nil)
        if failure != .success { break }
      }
    }
    let physicalBounds = online.filter { physical($0) != nil }.map { CGDisplayBounds($0) }
    // Leave unrelated virtual desktops alone unless they overlap the restored panels.
    var x = physicalBounds.map(\.maxX).max() ?? 0
    for id in online where isVirtual(id)
      && physicalBounds.contains(where: { $0.intersects(CGDisplayBounds(id)) }) {
      guard failure == .success else { break }
      guard let origin = Int32(exactly: x) else {
        failure = .rangeCheck
        break
      }
      failure = CGConfigureDisplayOrigin(config, id, origin, 0)
      x += CGDisplayBounds(id).width
    }
    guard failure == .success else {
      CGCancelDisplayConfiguration(config)
      throw DisplayControlError.configuration(failure.rawValue)
    }
    // The sender pins its capture display for the session; restore that session baseline too.
    let result = CGCompleteDisplayConfiguration(config, .forSession)
    guard result == .success else { throw DisplayControlError.configuration(result.rawValue) }
  }

  /// Safe both at agent startup and after a child crash; the journal precedes every off.
  func recover(_ store: DisplayRecoveryStore) throws -> [PhysicalDisplay] {
    let records = try store.read()
    guard !records.isEmpty else { return [] }
    var pending: [PhysicalDisplay] = []
    var restored: [PhysicalDisplay] = []
    for var display in records {
      guard let id = recoveryID(display) else { pending.append(display); continue }
      display.id = id
      do { try change([display], enabled: true) } catch {
        // A commit can report an error after applying; actual topology decides recovery.
      }
      if CGDisplayIsOnline(id) != 0, uuid(id) == display.uuid {
        restored.append(display)
      } else {
        pending.append(display)
      }
    }
    try store.write(pending)
    do { try restoreLayout(restored) } catch {
      // Connection recovery is complete even if a concurrent layout change wins the race.
      fputs("Physical panels restored; layout recovery was best effort: \(error)\n", stderr)
    }
    return pending
  }
}
