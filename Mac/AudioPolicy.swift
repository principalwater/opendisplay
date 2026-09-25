// Audio-related sender policy: which defaults keys exist, what they mean when
// absent, and the optional "mute this Mac's speakers while streaming".
//
// The decision logic is separated from CoreAudio so it can be unit-tested: the
// tests link this file, not the audio hardware.

import Foundation
import CoreAudio

// MARK: - Defaults policy

/// The sender's audio preferences and their fork defaults.
///
/// Both keys live in the Mac sender's own UserDefaults domain
/// (`com.peetzweg.opensidecar.mac.alfheim`), so they never touch the stock
/// app's settings.
enum AudioPolicy {

    /// Stream this Mac's system audio to the receiver.
    static let streamAudioKey = "audioEnabled"
    /// Mute this Mac's own speakers for as long as audio is being streamed.
    static let muteSpeakersKey = "muteMacSpeakersWhileStreaming"
    /// Breadcrumb written before the speakers are muted, so a crash can be
    /// undone at the next launch. See `SpeakerMuteController`.
    static let speakerMuteBreadcrumbKey = "speakerMuteBreadcrumb"

    /// **Fork policy: on unless the user turned it off.**
    ///
    /// Upstream defaults this off, on the sound reasoning that an update should
    /// not surprise anyone with sudden noise from their iPad. This fork is
    /// built for one operator who asked for the feature and whose complaint was
    /// its absence, so the polarity is flipped — but deliberately via
    /// "absent means on" rather than by writing a value at first launch, so
    /// `defaults delete` still returns the build to its documented default.
    static func resolveStreamAudio(_ stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    static var streamAudioEnabled: Bool {
        resolveStreamAudio(UserDefaults.standard.object(forKey: streamAudioKey))
    }

    /// **Off by default**, and unlike `streamAudioKey` that polarity matches
    /// `UserDefaults.bool(forKey:)`'s own "absent is false": silencing the
    /// machine the user is sitting at is not something to do unasked.
    static func resolveMuteSpeakers(_ stored: Any?) -> Bool {
        (stored as? Bool) ?? false
    }

    static var muteSpeakersWhileStreaming: Bool {
        resolveMuteSpeakers(UserDefaults.standard.object(forKey: muteSpeakersKey))
    }

    /// Whether the host's current output should be silenced right now.
    ///
    /// Pure so the three-way condition is testable: the option is on, audio
    /// capture is enabled, and at least one receiver has completed the audio
    /// protocol handshake. A session object by itself proves none of those
    /// things: the persistent dialer remains in `sessions` while the receiver
    /// is unreachable, which used to silence the host indefinitely while no
    /// audio could leave the Mac.
    static func shouldMuteSpeakers(optionEnabled: Bool,
                                   audioStreaming: Bool,
                                   audioDeliveryActive: Bool) -> Bool {
        optionEnabled && audioStreaming && audioDeliveryActive
    }
}

/// The receiver-side condition that makes host silencing safe.
///
/// Connection establishment alone is not enough: iOS may leave the TCP socket
/// accepting while the receiver app is suspended, and old receivers do not
/// understand audio frames at all. The same gate already protects the audio
/// packet path; publishing it to the controller keeps local silence and actual
/// delivery governed by one fact.
enum AudioDeliveryPolicy {
    static func isActive(connectionReady: Bool, peerSpeaksTaggedFrames: Bool) -> Bool {
        connectionReady && peerSpeaksTaggedFrames
    }
}

// MARK: - What a device lets software do to its level

/// The four ways a CoreAudio output device can be silenced, in the order they
/// are preferred.
///
/// Round 4 shipped only the first one, and the operator's MOTU M4 has none of
/// it: `speaker mute: the default output device has no settable mute — leaving
/// it alone`. A USB interface with four output channels is not unusual in that
/// — plenty of devices (HDMI, DisplayPort, most pro interfaces) expose no
/// master mute at all, some expose per-channel mute instead, and almost all
/// expose volume. "The feature reports itself unavailable" was an honest answer
/// to a question nobody asked: the operator wants the room quiet while the
/// sound is on the iPad, and there is more than one way to do that.
enum SilenceStrategy: Equatable {
    /// `kAudioDevicePropertyMute` on the output scope, master element.
    case masterMute
    /// The same property, per channel. Every listed channel is muted.
    case channelMute([UInt32])
    /// `kAudioDevicePropertyVolumeScalar`, master element, set to 0.
    case masterVolume
    /// The same property, per channel.
    case channelVolume([UInt32])
    /// Nothing software can set. The option disables itself and says so.
    case unavailable

    var isAvailable: Bool { self != .unavailable }

    /// Whether restoring means putting a *number* back rather than flipping a
    /// switch — i.e. whether the user changing the volume mid-session is a
    /// thing this strategy has to cope with.
    var isVolumeBased: Bool {
        switch self {
        case .masterVolume, .channelVolume: return true
        case .masterMute, .channelMute, .unavailable: return false
        }
    }

    /// Which property elements this strategy touches. 0 is the master element
    /// (`kAudioObjectPropertyElementMain`); anything else is a channel number.
    var elements: [UInt32] {
        switch self {
        case .masterMute, .masterVolume: return [SilenceStrategy.masterElement]
        case .channelMute(let channels), .channelVolume(let channels): return channels
        case .unavailable: return []
        }
    }

    static let masterElement: UInt32 = 0

    var label: String {
        switch self {
        case .masterMute: return "mute"
        case .channelMute(let c): return "per-channel mute (\(c.count) channels)"
        case .masterVolume: return "volume → 0"
        case .channelVolume(let c): return "per-channel volume → 0 (\(c.count) channels)"
        case .unavailable: return "nothing settable"
        }
    }
}

/// What a device actually offers, read once when a session starts.
struct OutputSilenceCapability: Equatable {
    var masterMuteSettable = false
    /// Channel numbers (1-based) whose mute is settable.
    var muteSettableChannels: [UInt32] = []
    var masterVolumeSettable = false
    var volumeSettableChannels: [UInt32] = []

    init(masterMuteSettable: Bool = false,
         muteSettableChannels: [UInt32] = [],
         masterVolumeSettable: Bool = false,
         volumeSettableChannels: [UInt32] = []) {
        self.masterMuteSettable = masterMuteSettable
        self.muteSettableChannels = muteSettableChannels
        self.masterVolumeSettable = masterVolumeSettable
        self.volumeSettableChannels = volumeSettableChannels
    }
}

/// Which strategy a capability earns. Pure, so the whole decision tree is a
/// table in a test rather than something only the operator's interface can
/// exercise.
enum SilencePolicy {

    /// Preference order, and the reasoning for it:
    ///
    /// 1. **master mute** — one property, exactly reversible, and the only one
    ///    that cannot be confused with a level the user set themselves.
    /// 2. **per-channel mute** — the same guarantee, N times. Restoring is
    ///    still a switch, so nothing can be lost.
    /// 3. **master volume** — reversible only as well as we remember the old
    ///    number, which is why the record is written before anything is touched
    ///    and why a mid-session change by the user is re-applied rather than
    ///    adopted.
    /// 4. **per-channel volume** — last, for the same reason as 2 versus 1.
    ///
    /// Mute is always preferred to volume even when both exist: a muted device
    /// remembers its own level, so the restore is the device's job rather than
    /// ours.
    static func strategy(for capability: OutputSilenceCapability) -> SilenceStrategy {
        if capability.masterMuteSettable { return .masterMute }
        if !capability.muteSettableChannels.isEmpty {
            return .channelMute(capability.muteSettableChannels)
        }
        if capability.masterVolumeSettable { return .masterVolume }
        if !capability.volumeSettableChannels.isEmpty {
            return .channelVolume(capability.volumeSettableChannels)
        }
        return .unavailable
    }
}

// MARK: - The breadcrumb

/// What was true before we silenced the device, persisted so a crash is
/// recoverable.
///
/// Silencing the system output is the one thing this app does that outlives the
/// process: if it dies between silence and restore, the user is left with a
/// quiet Mac and no indication why. There is no in-process way to run code
/// after a crash, so the next best guarantee is made instead — write down what
/// to undo *before* doing it, and undo it at the next launch.
///
/// The name is round 4's (`speakerMuteBreadcrumb`, and the same defaults key),
/// but the contents now describe whichever strategy was used, because a volume
/// set to 0 is exactly the kind of thing a crash must not leave behind.
struct SpeakerMuteBreadcrumb: Equatable {
    /// The CoreAudio device UID, so a restore lands on the device that was
    /// silenced rather than on whatever is default now.
    var deviceUID: String
    var strategy: SilenceStrategy
    /// Prior mute state per element (0 = master). Present for mute strategies.
    var mutes: [UInt32: Bool]
    /// Prior volume per element. Present for volume strategies.
    var volumes: [UInt32: Float]

    /// Whether the device was already muted when we found it — in which case
    /// there is nothing to undo, and the record exists only so the restore path
    /// knows to leave it alone. Kept as a name because it is the one question
    /// the recovery path asks, and because round 4's breadcrumbs on disk say
    /// exactly this and nothing else.
    var wasMuted: Bool { mutes[SilenceStrategy.masterElement] ?? false }

    /// Nothing to undo: every element was already where we would put it back.
    var hasNothingToRestore: Bool {
        switch strategy {
        case .masterMute, .channelMute:
            return !mutes.values.contains(false) && !mutes.isEmpty
        case .masterVolume, .channelVolume:
            return volumes.values.allSatisfy { $0 <= 0 } && !volumes.isEmpty
        case .unavailable:
            return true
        }
    }

    init(deviceUID: String, strategy: SilenceStrategy,
         mutes: [UInt32: Bool] = [:], volumes: [UInt32: Float] = [:]) {
        self.deviceUID = deviceUID
        self.strategy = strategy
        self.mutes = mutes
        self.volumes = volumes
    }

    /// Round-4 shape, kept so the old tests and the old on-disk breadcrumbs
    /// still mean what they meant.
    init(deviceUID: String, wasMuted: Bool) {
        self.init(deviceUID: deviceUID, strategy: .masterMute,
                  mutes: [SilenceStrategy.masterElement: wasMuted])
    }

    var asDictionary: [String: Any] {
        var dict: [String: Any] = [
            "uid": deviceUID,
            "strategy": Self.encode(strategy),
            // Round-4 readers (and the tests that pin them) look for this.
            "wasMuted": wasMuted,
        ]
        if !mutes.isEmpty {
            dict["mutes"] = Dictionary(uniqueKeysWithValues: mutes.map { (String($0.key), $0.value) })
        }
        if !volumes.isEmpty {
            dict["volumes"] = Dictionary(uniqueKeysWithValues: volumes.map { (String($0.key), Double($0.value)) })
        }
        return dict
    }

    init?(_ stored: Any?) {
        guard let dict = stored as? [String: Any],
              let uid = dict["uid"] as? String else { return nil }
        self.deviceUID = uid
        self.mutes = (dict["mutes"] as? [String: Bool]).map {
            Dictionary(uniqueKeysWithValues: $0.compactMap { key, value in
                UInt32(key).map { ($0, value) }
            })
        } ?? [:]
        self.volumes = (dict["volumes"] as? [String: Double]).map {
            Dictionary(uniqueKeysWithValues: $0.compactMap { key, value in
                UInt32(key).map { ($0, Float(value)) }
            })
        } ?? [:]
        if let encoded = dict["strategy"], let strategy = Self.decode(encoded) {
            self.strategy = strategy
        } else {
            // A breadcrumb written by round 4: master mute, and `wasMuted` is
            // everything it recorded.
            self.strategy = .masterMute
            if mutes.isEmpty {
                self.mutes = [SilenceStrategy.masterElement: (dict["wasMuted"] as? Bool) ?? false]
            }
        }
    }

    private static func encode(_ strategy: SilenceStrategy) -> [String: Any] {
        switch strategy {
        case .masterMute: return ["kind": "masterMute"]
        case .masterVolume: return ["kind": "masterVolume"]
        case .channelMute(let channels):
            return ["kind": "channelMute", "channels": channels.map { Int($0) }]
        case .channelVolume(let channels):
            return ["kind": "channelVolume", "channels": channels.map { Int($0) }]
        case .unavailable: return ["kind": "unavailable"]
        }
    }

    private static func decode(_ stored: Any) -> SilenceStrategy? {
        guard let dict = stored as? [String: Any], let kind = dict["kind"] as? String else { return nil }
        let channels = (dict["channels"] as? [Int])?.map { UInt32(max(0, $0)) } ?? []
        switch kind {
        case "masterMute": return .masterMute
        case "masterVolume": return .masterVolume
        case "channelMute": return .channelMute(channels)
        case "channelVolume": return .channelVolume(channels)
        case "unavailable": return .unavailable
        default: return nil
        }
    }
}

// MARK: - CoreAudio

/// The system's default output device, and the two properties that can silence
/// it: mute and volume, each addressable at the master element or per channel.
///
/// Everything here is a thin, failure-tolerant wrapper. The decisions are in
/// `SilencePolicy` above; this file's job is only to ask CoreAudio what is
/// settable and to set it.
enum SystemAudioOutput {

    // MARK: Devices

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputAddress
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func uid(of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    static func name(of device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return uid(of: device) ?? "(unnamed)" }
        return name as String
    }

    static func device(withUID wanted: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { uid(of: $0) == wanted }
    }

    /// How many output channels this device has, from its output stream
    /// configuration. Zero means "not an output device" (or a device that
    /// vanished mid-query), and nothing per-channel is attempted.
    static func outputChannelCount(of device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + $1.mNumberChannels }
    }

    // MARK: Properties

    private static func address(_ selector: AudioObjectPropertySelector,
                                element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: element)
    }

    static func isSettable(_ selector: AudioObjectPropertySelector,
                           on device: AudioDeviceID, element: UInt32) -> Bool {
        var addr = address(selector, element: element)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Everything `SilencePolicy` needs to choose a strategy for this device.
    ///
    /// Channels are probed only when the master element cannot answer, and only
    /// up to the device's real channel count — a four-output interface is four
    /// property queries, not a scan.
    static func capability(of device: AudioDeviceID) -> OutputSilenceCapability {
        var capability = OutputSilenceCapability()
        capability.masterMuteSettable = isSettable(kAudioDevicePropertyMute, on: device,
                                                   element: SilenceStrategy.masterElement)
        capability.masterVolumeSettable = isSettable(kAudioDevicePropertyVolumeScalar, on: device,
                                                     element: SilenceStrategy.masterElement)
        let channels = outputChannelCount(of: device)
        if channels > 0, !capability.masterMuteSettable || !capability.masterVolumeSettable {
            for channel in 1...channels {
                if !capability.masterMuteSettable,
                   isSettable(kAudioDevicePropertyMute, on: device, element: channel) {
                    capability.muteSettableChannels.append(channel)
                }
                if !capability.masterVolumeSettable,
                   isSettable(kAudioDevicePropertyVolumeScalar, on: device, element: channel) {
                    capability.volumeSettableChannels.append(channel)
                }
            }
        }
        return capability
    }

    static func isMuted(_ device: AudioDeviceID, element: UInt32) -> Bool? {
        var addr = address(kAudioDevicePropertyMute, element: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    @discardableResult
    static func setMuted(_ muted: Bool, on device: AudioDeviceID, element: UInt32) -> Bool {
        var addr = address(kAudioDevicePropertyMute, element: element)
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr
    }

    static func volume(_ device: AudioDeviceID, element: UInt32) -> Float? {
        var addr = address(kAudioDevicePropertyVolumeScalar, element: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    static func setVolume(_ volume: Float, on device: AudioDeviceID, element: UInt32) -> Bool {
        var addr = address(kAudioDevicePropertyVolumeScalar, element: element)
        var value = Float32(min(max(volume, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, size, &value) == noErr
    }

    // MARK: Listeners

    /// Watch a property and call back on the main queue. Returns the block so
    /// it can be removed again — CoreAudio identifies a listener by its block.
    static func addListener(_ selector: AudioObjectPropertySelector,
                            on object: AudioObjectID, scope: AudioObjectPropertyScope,
                            element: UInt32,
                            handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &addr, DispatchQueue.main, block) == noErr else {
            return nil
        }
        return block
    }

    static func removeListener(_ block: @escaping AudioObjectPropertyListenerBlock,
                               _ selector: AudioObjectPropertySelector,
                               on object: AudioObjectID, scope: AudioObjectPropertyScope,
                               element: UInt32) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        AudioObjectRemovePropertyListenerBlock(object, &addr, DispatchQueue.main, block)
    }
}

// MARK: - The controller

/// Silences the Mac's own output while audio is being streamed, and puts it
/// back. Whatever the device allows: master mute, per-channel mute, master
/// volume, per-channel volume — see `SilencePolicy`.
///
/// Restore paths, in order of how much is guaranteed:
///
/// 1. **Session end** — `apply(…)` is called whenever the sessions list or
///    either setting changes, so the ordinary path restores immediately.
/// 2. **App quit** — `AppDelegate.applicationWillTerminate`.
/// 3. **Crash or force-quit** — the breadcrumb written before silencing is read
///    at the next launch and undone there. This is the honest limit of the
///    feature: between a crash and the next launch the Mac stays quiet, and the
///    user's fix in the meantime is the volume key they already know.
///
/// Two things it also has to survive, both of which the operator hit:
///
/// * **the default output device changing mid-session** (their words: "the
///   default output device changes from time to time"). A listener un-silences
///   the device we had and silences the new one, so the sound never comes back
///   in the room because something was replugged.
/// * **the user moving the volume while it is silenced.** With a volume
///   strategy that is indistinguishable from the device drifting, so it is
///   re-applied — and the number restored at the end is still *their* last
///   pre-session value, never the 0 we wrote or a level they set while they
///   could not hear it.
@MainActor
final class SpeakerMuteController {

    static let shared = SpeakerMuteController()

    private let defaults: UserDefaults
    /// The device currently silenced, what was true before, and how.
    private var engaged: (device: AudioDeviceID, record: SpeakerMuteBreadcrumb)?
    /// Whether the settings currently want silence at all — remembered so the
    /// default-device listener knows whether to silence the newcomer.
    private var wanted = false
    private var loggedUnavailable = false
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    /// Re-apply listeners, one per silenced element, so a user turning the
    /// volume up mid-session is put back down instead of being heard.
    private var reapplyListeners: [(block: AudioObjectPropertyListenerBlock,
                                    selector: AudioObjectPropertySelector,
                                    device: AudioDeviceID, element: UInt32)] = []
    /// Set while we are writing, so our own write does not read as the user's.
    private var applyingSilence = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Cached capability probe, keyed on the device it was taken for.
    ///
    /// `strategy` is read from a SwiftUI body (the settings hint), i.e. on every
    /// re-render, and probing costs a device enumeration plus one property
    /// query per channel. The cache is invalidated by the device changing,
    /// which is the only thing that can change the answer.
    private var cachedStrategy: (device: AudioDeviceID, strategy: SilenceStrategy)?

    /// What the current default output device allows, for the settings UI.
    var strategy: SilenceStrategy {
        guard let device = SystemAudioOutput.defaultOutputDevice() else { return .unavailable }
        if let cachedStrategy, cachedStrategy.device == device { return cachedStrategy.strategy }
        let strategy = SilencePolicy.strategy(for: SystemAudioOutput.capability(of: device))
        cachedStrategy = (device, strategy)
        return strategy
    }

    /// True when the current default output device can be silenced at all.
    var isAvailable: Bool { strategy.isAvailable }

    /// Bring the hardware in line with the settings. Idempotent.
    func apply(optionEnabled: Bool, audioStreaming: Bool, audioDeliveryActive: Bool) {
        wanted = AudioPolicy.shouldMuteSpeakers(optionEnabled: optionEnabled,
                                                audioStreaming: audioStreaming,
                                                audioDeliveryActive: audioDeliveryActive)
        if wanted {
            watchDefaultDevice()
            engage()
        } else {
            release()
            stopWatchingDefaultDevice()
        }
    }

    // MARK: Engage / release

    private func engage() {
        guard engaged == nil else { return }
        guard let device = SystemAudioOutput.defaultOutputDevice(),
              let uid = SystemAudioOutput.uid(of: device) else {
            logUnavailableOnce("no default output device")
            return
        }
        let capability = SystemAudioOutput.capability(of: device)
        let strategy = SilencePolicy.strategy(for: capability)
        guard strategy.isAvailable else {
            logUnavailableOnce("\(SystemAudioOutput.name(of: device)) exposes neither a settable mute "
                + "(master or per channel) nor a settable volume — leaving it alone")
            return
        }
        // Read what is there BEFORE touching anything, and write the breadcrumb
        // before the first property is set. If the process dies between those
        // two statements the worst case is a stale record that restores a
        // device to the state it is already in; the other order loses the
        // record of a change that did happen.
        var mutes: [UInt32: Bool] = [:]
        var volumes: [UInt32: Float] = [:]
        for element in strategy.elements {
            if strategy.isVolumeBased {
                volumes[element] = SystemAudioOutput.volume(device, element: element) ?? 0
            } else {
                mutes[element] = SystemAudioOutput.isMuted(device, element: element) ?? false
            }
        }
        let record = SpeakerMuteBreadcrumb(deviceUID: uid, strategy: strategy,
                                           mutes: mutes, volumes: volumes)
        defaults.set(record.asDictionary, forKey: AudioPolicy.speakerMuteBreadcrumbKey)
        engaged = (device, record)
        loggedUnavailable = false
        applySilence(to: device, strategy: strategy)
        watchForUserChanges(on: device, strategy: strategy)
        let before = strategy.isVolumeBased
            ? "volume was " + volumes.map { "ch\($0.key)=\(String(format: "%.2f", $0.value))" }.sorted().joined(separator: " ")
            : "was " + (record.hasNothingToRestore ? "already muted" : "unmuted")
        Log.info("speaker silence: \(SystemAudioOutput.name(of: device)) (\(uid)) via "
                 + "\(strategy.label) while streaming audio — \(before)")
    }

    private func applySilence(to device: AudioDeviceID, strategy: SilenceStrategy) {
        applyingSilence = true
        defer { applyingSilence = false }
        for element in strategy.elements {
            if strategy.isVolumeBased {
                SystemAudioOutput.setVolume(0, on: device, element: element)
            } else {
                SystemAudioOutput.setMuted(true, on: device, element: element)
            }
        }
    }

    private func release() {
        stopWatchingUserChanges()
        guard let engaged else {
            // Nothing engaged in this process, but a previous one may have died
            // mid-silence; that is `recoverFromPreviousRun`'s job, not this path's.
            return
        }
        self.engaged = nil
        restore(engaged.record, on: engaged.device)
        defaults.removeObject(forKey: AudioPolicy.speakerMuteBreadcrumbKey)
        Log.info("speaker silence: restored \(engaged.record.deviceUID) "
                 + "(\(engaged.record.strategy.label))")
    }

    /// Put a device back exactly as the record found it.
    ///
    /// Never "unmute everything" or "set the volume to something sensible":
    /// an element that was already muted, or already at zero, stays that way.
    /// The user's own state is not ours to improve.
    private func restore(_ record: SpeakerMuteBreadcrumb, on device: AudioDeviceID) {
        applyingSilence = true
        defer { applyingSilence = false }
        for (element, wasMuted) in record.mutes where !wasMuted {
            SystemAudioOutput.setMuted(false, on: device, element: element)
        }
        for (element, volume) in record.volumes {
            SystemAudioOutput.setVolume(volume, on: device, element: element)
        }
    }

    // MARK: The default device moving under us

    private func watchDefaultDevice() {
        guard defaultDeviceListener == nil else { return }
        defaultDeviceListener = SystemAudioOutput.addListener(
            kAudioHardwarePropertyDefaultOutputDevice,
            on: AudioObjectID(kAudioObjectSystemObject),
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain) { [weak self] in
                self?.defaultOutputDeviceChanged()
            }
    }

    private func stopWatchingDefaultDevice() {
        guard let block = defaultDeviceListener else { return }
        SystemAudioOutput.removeListener(block, kAudioHardwarePropertyDefaultOutputDevice,
                                         on: AudioObjectID(kAudioObjectSystemObject),
                                         scope: kAudioObjectPropertyScopeGlobal,
                                         element: kAudioObjectPropertyElementMain)
        defaultDeviceListener = nil
    }

    private func defaultOutputDeviceChanged() {
        guard wanted else { return }
        let now = SystemAudioOutput.defaultOutputDevice()
        if let engaged, engaged.device == now { return }
        cachedStrategy = nil
        Log.info("speaker silence: the default output device changed"
                 + (now.map { " to \(SystemAudioOutput.name(of: $0))" } ?? " (to nothing)")
                 + " — handing the silence over")
        // Un-silence the one we had first: leaving a device we no longer own
        // silenced is the failure this whole class exists to prevent.
        release()
        engage()
    }

    // MARK: The user turning it back up

    private func watchForUserChanges(on device: AudioDeviceID, strategy: SilenceStrategy) {
        stopWatchingUserChanges()
        let selector: AudioObjectPropertySelector = strategy.isVolumeBased
            ? kAudioDevicePropertyVolumeScalar
            : kAudioDevicePropertyMute
        for element in strategy.elements {
            guard let block = SystemAudioOutput.addListener(
                selector, on: device, scope: kAudioDevicePropertyScopeOutput,
                element: element, handler: { [weak self] in
                    self?.reassertSilence(on: device, selector: selector, element: element)
                }) else { continue }
            reapplyListeners.append((block, selector, device, element))
        }
    }

    private func stopWatchingUserChanges() {
        for listener in reapplyListeners {
            SystemAudioOutput.removeListener(listener.block, listener.selector,
                                             on: listener.device,
                                             scope: kAudioDevicePropertyScopeOutput,
                                             element: listener.element)
        }
        reapplyListeners.removeAll()
    }

    /// The user moved something we are holding down. Put it back — but do NOT
    /// adopt the new value into the record: what gets restored at the end is
    /// still their last pre-session level, not a level they chose while the
    /// device was silent and they could not hear the result.
    private func reassertSilence(on device: AudioDeviceID,
                                 selector: AudioObjectPropertySelector, element: UInt32) {
        guard !applyingSilence, let engaged, engaged.device == device else { return }
        applyingSilence = true
        defer { applyingSilence = false }
        if selector == kAudioDevicePropertyVolumeScalar {
            guard let current = SystemAudioOutput.volume(device, element: element), current > 0 else { return }
            SystemAudioOutput.setVolume(0, on: device, element: element)
            Log.info(String(format: "speaker silence: volume on element %u was raised to %.2f "
                            + "while streaming — putting it back to 0 (restoring %.2f at the end)",
                            element, current, engaged.record.volumes[element] ?? 0))
        } else {
            guard SystemAudioOutput.isMuted(device, element: element) == false else { return }
            SystemAudioOutput.setMuted(true, on: device, element: element)
            Log.info("speaker silence: element \(element) was unmuted while streaming — re-muting")
        }
    }

    // MARK: Recovery and shutdown

    /// Undo a silence left behind by a crashed or force-quit previous run.
    /// Called once from `applicationDidFinishLaunching`.
    func recoverFromPreviousRun() {
        guard let record = SpeakerMuteBreadcrumb(defaults.object(forKey: AudioPolicy.speakerMuteBreadcrumbKey)) else {
            return
        }
        defaults.removeObject(forKey: AudioPolicy.speakerMuteBreadcrumbKey)
        guard !record.hasNothingToRestore else {
            Log.info("speaker silence: the previous run's breadcrumb has nothing to undo "
                     + "(\(record.deviceUID) was already silent)")
            return
        }
        guard let device = SystemAudioOutput.device(withUID: record.deviceUID) else {
            Log.info("speaker silence: the device silenced by the previous run (\(record.deviceUID)) "
                     + "is gone — cannot restore")
            return
        }
        restore(record, on: device)
        Log.info("speaker silence: the previous run did not shut down cleanly — "
                 + "restored \(record.deviceUID) (\(record.strategy.label))")
    }

    /// Last-chance restore on quit.
    func releaseForShutdown() {
        wanted = false
        release()
        stopWatchingDefaultDevice()
    }

    private func logUnavailableOnce(_ detail: String) {
        guard !loggedUnavailable else { return }
        loggedUnavailable = true
        Log.info("speaker silence unavailable: \(detail)")
    }
}
