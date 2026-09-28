import SwiftUI
import Network
import Combine
import Sparkle

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle's standard updater, held for the app's lifetime so every window
    // (menu bar + control window) shares one instance.
    //
    // alfheim fork: `startingUpdater: false`. There is no appcast published
    // for this fork's bundle id, and the SUFeedURL inherited from upstream
    // advertises the *stock* app — letting Sparkle run would eventually offer
    // to replace this build with upstream 1.19.0 and undo the whole branch.
    // Not starting the updater is the smallest possible disable: no scheduled
    // check, no network traffic, and `canCheckForUpdates` stays false so the
    // "Check for Updates…" menu item disables itself instead of doing
    // something surprising. Nothing else in the app is touched, and flipping
    // this back to `true` is all it takes to re-enable updates if the fork
    // ever publishes its own appcast.
    let updater = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Undo a speaker mute left behind by a previous run that crashed or
        // was force-quit. Before anything else: a user who relaunches because
        // "the Mac went silent" should get their sound back immediately.
        SpeakerMuteController.shared.recoverFromPreviousRun()
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ordinary quit: put the speakers back before the process goes away,
        // so the breadcrumb path never has to run.
        SpeakerMuteController.shared.releaseForShutdown()
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    /// What adaptive quality has the stream at right now. Level 0 (full) is the
    /// steady state and is not shown; anything else is, because a user looking
    /// at a softer picture deserves to be told why.
    @Published var qualityLevel = QualityLevel.unconstrained
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false

    // Whether the sender's socket is up right now. A session that exists is
    // not a session that is serving anybody: see `SessionSnapshot.connected`.
    @Published var connected = false

    // Whether the receiver can actually accept this session's audio frames:
    // socket up AND tagged-framing hello received. This is intentionally not
    // derived from the existence of the session or from `connected` alone.
    @Published var audioDeliveryActive = false

    var transportLabel: String { onUSB ? "USB" : wired ? "Cable" : "WiFi" }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    /// What a session does to the desktop. **`remote` by default in this
    /// fork**; the legacy `mode` key (and the `-mode mirror` / `-mode extend`
    /// launch argument) still decides when `sessionLayout` is absent — see
    /// `SessionLayout.resolve`.
    @Published var sessionLayout = SessionLayout.resolved().layout {
        didSet {
            UserDefaults.standard.set(sessionLayout.rawValue, forKey: SessionLayout.defaultsKey)
            // Choosing in the picker writes the new key, so from here on the
            // answer came from the user, not from a default.
            sessionLayoutSource = .sessionLayoutKey
        }
    }
    /// Which key the live `sessionLayout` came from, carried into every session
    /// so the capture-start log line can say *why* — see `SessionLayout.Source`.
    private(set) var sessionLayoutSource = SessionLayout.resolved().source
    /// Which display the capture pipeline points at. Derived from the layout,
    /// so there is exactly one setting and the two can never disagree.
    var mode: CaptureMode { sessionLayout.captureMode }
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    // Which Option key on the device's hardware keyboard arrives as Command.
    // Read by the injector when a session is built, so a change here applies
    // to the next session — see CommandKeyRemap. The initial value goes
    // through `fromDefaults()` so the legacy `remapRightOptionToCommand`
    // boolean still decides what the picker shows on first launch.
    @Published var commandKeyRemap = CommandKeyRemap.fromDefaults() {
        didSet {
            UserDefaults.standard.set(commandKeyRemap.rawValue,
                                      forKey: CommandKeyRemap.defaultsKey)
        }
    }
    // The keys an iPad Magic Keyboard does not have. Same contract as
    // `commandKeyRemap`: read when the injector is built, so a change applies
    // to the next session. See `KeyRemapPlan` for why `escapeKey` outranks
    // `globeKey` when both name the Globe key.
    @Published var escapeKey = EscapeKeySource.fromDefaults() {
        didSet { UserDefaults.standard.set(escapeKey.rawValue, forKey: EscapeKeySource.defaultsKey) }
    }
    @Published var globeKey = GlobeKeyAction.fromDefaults() {
        didSet { UserDefaults.standard.set(globeKey.rawValue, forKey: GlobeKeyAction.defaultsKey) }
    }
    @Published var languageKey = LanguageKeySource.fromDefaults() {
        didSet { UserDefaults.standard.set(languageKey.rawValue, forKey: LanguageKeySource.defaultsKey) }
    }
    /// Nil unless two of the three settings above name the same key.
    var keyRemapConflict: String? {
        KeyRemapPlan.resolve(escapeKey: escapeKey, globeKey: globeKey,
                             languageKey: languageKey).conflictNote
    }
    /// Stream system audio alongside the picture. **On by default in this
    /// fork** — see `AudioPolicy.resolveStreamAudio`. Changing it restarts
    /// capture, because `capturesAudio` is fixed at stream creation.
    @Published var audioEnabled = AudioPolicy.streamAudioEnabled {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: AudioPolicy.streamAudioKey)
            updateSpeakerMute()
        }
    }
    /// Mute this Mac's own speakers for as long as audio is being streamed.
    /// Off by default; restored on session end, on quit, and — via a
    /// breadcrumb — at the next launch after a crash. See
    /// `SpeakerMuteController`.
    @Published var muteMacSpeakers = AudioPolicy.muteSpeakersWhileStreaming {
        didSet {
            UserDefaults.standard.set(muteMacSpeakers, forKey: AudioPolicy.muteSpeakersKey)
            updateSpeakerMute()
        }
    }

    /// What the "Mute Mac speakers" row says underneath itself. The honest
    /// version: a crash cannot be undone instantly, only at the next launch.
    var speakerMuteHint: String {
        let strategy = SpeakerMuteController.shared.strategy
        guard strategy.isAvailable else {
            return "Unavailable: this Mac's current output device exposes neither a mute switch nor a volume that software can set. Change the output device in Sound settings, or leave this off."
        }
        let how: String
        switch strategy {
        case .masterMute:
            how = "mutes the output device"
        case .channelMute(let channels):
            how = "mutes all \(channels.count) output channels (this device has no master mute)"
        case .masterVolume:
            how = "turns the output volume down to zero (this device has no mute switch) and puts your level back afterwards"
        case .channelVolume(let channels):
            how = "turns all \(channels.count) output channels down to zero (this device has neither a mute switch nor a master volume) and puts your levels back afterwards"
        case .unavailable:
            how = ""
        }
        return "Silences this Mac's own output while a device is receiving the audio: \(how). Restored when the session ends, when the app quits, and — if it is force-quit or crashes — at its next launch. Follows the default output device if you change it mid-session."
    }

    /// Bring host silence in line with the settings and actual audio delivery.
    /// A persistent waiting/reconnecting session does not count; only the
    /// sender's audio gate does. `SpeakerMuteController` follows the current
    /// default output device, so this is interface-agnostic (built-in, display,
    /// USB, Thunderbolt, aggregate, and future devices all take this path).
    func updateSpeakerMute() {
        SpeakerMuteController.shared.apply(optionEnabled: muteMacSpeakers,
                                           audioStreaming: audioEnabled,
                                           audioDeliveryActive:
                                               sessions.contains(where: \.audioDeliveryActive))
    }

    /// Target frame rate for the virtual display, the capture stream and the
    /// encoder. **120 by default in this fork** — the panel it drives is an
    /// iPad Pro 11 M1, i.e. ProMotion. See `FrameRate`.
    @Published var frameRate = FrameRate.fromDefaults() {
        didSet { UserDefaults.standard.set(frameRate.rawValue, forKey: FrameRate.defaultsKey) }
    }

    /// Step the bitrate (and, last, the frame rate) down when the link cannot
    /// carry what the settings ask for. **On by default** — see
    /// `AdaptiveQualityController`. Read when a sender is built, like the
    /// layout and the frame rate, so it applies to the next session.
    @Published var adaptiveQuality = AdaptiveQualityController.isEnabled {
        didSet {
            UserDefaults.standard.set(adaptiveQuality, forKey: AdaptiveQualityController.defaultsKey)
        }
    }

    /// Move the open windows onto the session display in `remote` layout.
    /// **On by default** — see `WindowGatherPolicy`. Read when a session
    /// starts, so it applies to the next one.
    @Published var gatherWindows = WindowGatherPolicy.enabled() {
        didSet {
            UserDefaults.standard.set(gatherWindows, forKey: WindowGatherPolicy.defaultsKey)
        }
    }

    var running: Bool { !sessions.isEmpty }

    private var browser: NWBrowser?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH only — never mid-session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    /// The receiver install id the `-host`/`-port` endpoint last reached.
    /// See `SessionDedupe.shouldDialManualEndpoint`.
    private var manualEndpointInstallID: String? =
        UserDefaults.standard.string(forKey: "manualEndpointInstallID") {
        didSet {
            UserDefaults.standard.set(manualEndpointInstallID, forKey: "manualEndpointInstallID")
        }
    }
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)

    /// Receivers this Mac has already talked to over any transport, by install
    /// id. The key to auto-connecting over Bonjour **at any time** instead of
    /// only in the 12 s launch window above — see
    /// `SessionDedupe.knownBonjourToDial`.
    private var knownInstallIDs: Set<String> {
        var ids = Set(installIDByUDID.values)
        if let manualEndpointInstallID { ids.insert(manualEndpointInstallID) }
        // A receiver first met over Bonjour counts too, once it has said hello.
        for session in sessions {
            if let id = session.deviceID { ids.insert(id) }
        }
        ids.formUnion(bonjourKnownInstallIDs)
        ids.remove("")
        return ids
    }

    /// Install ids learned over Bonjour, persisted so "already known" survives
    /// a relaunch — which is the whole point on a LAN with no Tailscale and no
    /// cable: after the first manual connect, every later launch dials by
    /// itself.
    private var bonjourKnownInstallIDs: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "bonjourKnownInstallIDs") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(bonjourKnownInstallIDs), forKey: "bonjourKnownInstallIDs")
        }
    }

    /// Bonjour service name → receiver install id, persisted.
    ///
    /// The fallback identity for a browse result that arrives without its TXT
    /// record, which is common enough that it is the reason auto-connect never
    /// fired. Weaker than the TXT id — rename the iPad and the pair is stale —
    /// so it is consulted only when the TXT is absent, and only for a pair this
    /// Mac has itself observed.
    private var installIDByServiceName: [String: String] =
        UserDefaults.standard.dictionary(forKey: "bonjourNameToInstallID") as? [String: String] ?? [:] {
        didSet {
            UserDefaults.standard.set(installIDByServiceName, forKey: "bonjourNameToInstallID")
        }
    }

    /// The last Bonjour decision logged per service, so a browse event that
    /// changes nothing does not repeat itself. Browse handlers fire on every
    /// mDNS refresh.
    private var loggedBonjourDecisions: [String: String] = [:]

    /// Dial targets a receiver has refused, and until when (PROTOCOL.md 6.6).
    private var rejectionBackoff = RejectionBackoff()

    /// What the panel shows for a refused sender.
    struct RejectionRow: Identifiable {
        let id: String
        let name: String
        let until: Date
        let reason: String

        var message: String {
            let seconds = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
            let why = reason == RejectionMessage.reasonOtherMacSelected
                ? "another Mac is selected on that device"
                : reason
            return "Refused: \(why) — retrying in \(seconds)s"
        }
    }

    @Published private(set) var rejections: [RejectionRow] = []

    init() {
        startBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.autoConnect()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = Array(results)
                self.endSessionsWhoseServiceVanished()
                self.autoConnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if let id = txtID(of: result), installIDByUDID[device.udid] == id { return true }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, case .wifi(let result) = s.target else { return false }
            if let id = installIDByUDID[device.udid],
               s.deviceID == id || txtID(of: result) == id { return true }
            return serviceName(of: result) != nil && device.name == serviceName(of: result)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)"),
           !direct.failed {
            return direct
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        //
        // ...unless the cable already covers the same receiver. Ending the
        // duplicate in `dedupeSessions` is only half the fix: this runs on
        // every hello, every browse event and every usbmux publish, and used to
        // re-dial `usb:first` the instant it saw no session with that id —
        // which turned a one-off collision into a ~2s ping-pong that lasted for
        // as long as the cable was in.
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"),
           SessionDedupe.shouldDialManualEndpoint(sessions: sessions.map(snapshot),
                                                  attachedUDIDs: cableCoveringUDIDs,
                                                  installIDByUDID: installIDByUDID,
                                                  knownInstallID: manualEndpointInstallID) {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if !usbDisabled.contains("usb:\(device.udid)") {
                connect(to: .usb(udid: device.udid))
            }
        }
        // Known receivers, over Bonjour, at ANY time — no launch deadline and
        // no dependence on the service *name*. This is what makes the LAN work
        // with Tailscale switched off: the iPad advertises `_opensidecar._tcp`
        // with its install id in the TXT record, and an id this Mac has already
        // driven is the same device however it is named today.
        let candidates = discovered.map { result in
            SessionDedupe.BonjourCandidate(sessionID: ConnectionTarget.wifi(result).sessionID,
                                           txtID: txtID(of: result),
                                           serviceName: serviceName(of: result))
        }
        // **Every** result gets a decision and a line, not just the ones that
        // match. Round 6's log had nothing at all here, which made "the TXT was
        // missing", "the id is not known" and "something else already serves
        // it" indistinguishable — three different bugs behind one silence.
        // Repeated only when the answer changes: browse handlers fire on every
        // mDNS refresh.
        let decisions = SessionDedupe.bonjourDecisions(
            candidates: candidates,
            sessions: sessions.map(snapshot),
            knownInstallIDs: knownInstallIDs,
            cabledUDIDs: cableCoveringUDIDs,
            installIDByUDID: installIDByUDID,
            manualEndpointInstallID: manualEndpointInstallID,
            installIDByServiceName: installIDByServiceName)
        var seenThisPass = Set<String>()
        for decision in decisions {
            seenThisPass.insert(decision.sessionID)
            let line = decision.logLine
            if loggedBonjourDecisions[decision.sessionID] != line {
                loggedBonjourDecisions[decision.sessionID] = line
                Log.info(line)
            }
            guard decision.dial,
                  let result = discovered.first(where: {
                      ConnectionTarget.wifi($0).sessionID == decision.sessionID
                  }) else { continue }
            connect(to: .wifi(result))
        }
        loggedBonjourDecisions = loggedBonjourDecisions.filter { seenThisPass.contains($0.key) }

        // Unknown receivers keep the old rule, deliberately: a device that has
        // never been connected appearing on the network is not consent, and the
        // launch window is what keeps "a flatmate opened the app" from grabbing
        // a display.
        guard wifiAutoConnectArmed, Date() < wifiAutoConnectDeadline else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if wifiRemembered.contains(target.sessionID),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)")
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: .usb(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard autoConnectEnabled, !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            Log.info("cable detached for \(session.id) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            session.sender.switchTransport(to: .tcp(result.endpoint))
        }
        // Re-arming the manual endpoint needs nothing here. `usbDevices` was
        // updated by the watcher *before* this call, so the detached udid has
        // already left `attachedUDIDs`, and the `autoConnect()` the watcher
        // makes immediately after this sees an uncovered manual endpoint and
        // dials it. Keyed on attachment rather than on a session existing
        // precisely so this case needs no extra state to reset — a session
        // that is still retrying the cable through its grace period must not
        // keep the manual endpoint suppressed.
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Record what a `hello` said about which physical receiver a session
    /// reaches. Called from both `onHello` and the pre-display admission
    /// check, whichever of the two lands first — writing the same values
    /// twice costs nothing and guarantees the decision sees them.
    private func learnIdentity(of session: DeviceSession, from info: PhoneInfo) {
        session.deviceID = info.id
        session.deviceKind = info.device
        if case .usb(let udid?) = session.target, let installID = info.id {
            installIDByUDID[udid] = installID
        }
        // Which receiver the manual endpoint actually reaches. Persisted,
        // because the gate in `autoConnect()` has to answer before the
        // manual session has said hello — on the launch after a session
        // that ping-ponged, that is the whole question.
        if case .usb(nil) = session.target, let installID = info.id {
            manualEndpointInstallID = installID
        }
        // A receiver met over Bonjour is "known" from now on, across launches:
        // that is what lets the next launch dial it without Tailscale, a cable
        // or the 12 s window.
        if case .wifi = session.target, let installID = info.id, !installID.isEmpty {
            bonjourKnownInstallIDs.insert(installID)
        }
        // Remember the **name ↔ id pair**, whatever transport learned it, for
        // the browse results whose TXT record never arrives. `NWBrowser.Result`
        // hands out `.metadata == .none` often enough that keying auto-connect
        // on the TXT id alone meant the LAN path silently never fired: the
        // round-6 log has no `known receiver … on Bonjour` line at all, on a
        // Mac whose `bonjourKnownInstallIDs` already held the right id.
        if let installID = info.id, !installID.isEmpty,
           let name = session.wifiServiceName ?? bonjourName(of: session) {
            if installIDByServiceName[name] != installID {
                installIDByServiceName[name] = installID
                Log.info("bonjour: remembering service name \"\(name)\" as receiver \(installID)")
            }
        }
    }

    /// The Bonjour service name this session's target names, if it is a WiFi
    /// target at all.
    private func bonjourName(of session: DeviceSession) -> String? {
        guard case .wifi(let result) = session.target else { return nil }
        return serviceName(of: result)
    }

    /// Flatten a session to the identity facts `SessionDedupe` needs. Keeping
    /// `NWBrowser.Result` out of the decision is what makes the decision
    /// testable at all — it has no public initializer.
    private func snapshot(_ session: DeviceSession) -> SessionSnapshot {
        let kind: SessionSnapshot.Kind
        switch session.target {
        case .usb(let udid?):  kind = .usbDevice(udid: udid)
        case .usb(nil):        kind = .manualEndpoint
        case .wifi:            kind = .wifi
        }
        var txt: String?
        var name: String?
        if case .wifi(let result) = session.target {
            txt = txtID(of: result)
            name = serviceName(of: result)
        }
        return SessionSnapshot(id: session.id, kind: kind, failed: session.failed,
                               installID: session.deviceID, txtID: txt,
                               serviceName: name ?? session.wifiServiceName,
                               connected: session.connected,
                               // `usb:first` is usbmuxd's first attached device
                               // unless `-host` was given, in which case it is
                               // a plain TCP endpoint — a tunnel. The two are
                               // the same `ConnectionTarget` and opposite ends
                               // of the precedence order.
                               manualEndpointIsTunnel:
                                   UserDefaults.standard.object(forKey: "host") != nil)
    }

    /// Which devices are on the cable right now.
    private var attachedUDIDs: Set<String> { Set(usbDevices.map(\.udid)) }

    /// The cables this app will actually drive: attached, not opted out of
    /// auto-connect, and not sitting on a session whose `start()` threw.
    ///
    /// The pre-emptive rules (`SessionDedupe.admits`,
    /// `manualEndpointsCoveredByCable`, `shouldDialManualEndpoint`) let a cable
    /// veto another transport *before* that transport has built anything, so
    /// the veto has to come from a cable that is going to work. A device the
    /// user disconnected, or one whose USB session failed to start, must not be
    /// allowed to suppress the only endpoint that can still reach it.
    private var cableCoveringUDIDs: Set<String> {
        Set(usbDevices.map(\.udid).filter { udid in
            if usbDisabled.contains("usb:\(udid)") { return false }
            if let existing = session(for: "usb:\(udid)"), existing.failed { return false }
            return true
        })
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the twin — WiFi *or* manual.
    ///
    /// The decision lives in `SessionDedupe`; what is left here is reading the
    /// controller's state into snapshots and carrying out the verdict.
    private func dedupeSessions() {
        let cabledNames = Set(usbDevices.compactMap { device -> String? in
            guard let s = session(for: "usb:\(device.udid)"), !s.failed else { return nil }
            return device.name
        })
        // First, the rule that does not need the loser's hello: a manual
        // endpoint whose receiver is on the cable. Persisted identity answers
        // this at launch, so the session is ended while it is still waiting to
        // be greeted — before `setupExtend` has created anything.
        let early = SessionDedupe.manualEndpointsCoveredByCable(
            sessions.map(snapshot),
            cabledUDIDs: cableCoveringUDIDs,
            installIDByUDID: installIDByUDID,
            knownInstallID: manualEndpointInstallID)
        for id in early {
            guard let s = session(for: id) else { continue }
            Log.info("the cable covers this receiver — dropping \(s.id) before it builds a display")
            end(s)
        }
        // Then the mirror of the dial gate: a tunnel that is still dialing
        // while Bonjour already reaches this receiver. It is always launched
        // first (before any browse result exists), so without this it redials
        // for the life of the process — the whole of the idle log, and a
        // session row that never delivers anything.
        let superseded = SessionDedupe.manualTunnelsCoveredByLAN(
            sessions.map(snapshot), knownInstallID: manualEndpointInstallID)
        for id in superseded {
            guard let s = session(for: id) else { continue }
            Log.info("Bonjour reaches this receiver — retiring the dialing tunnel \(s.id)")
            end(s)
        }
        let doomed = SessionDedupe.duplicateSessionIDs(sessions.map(snapshot),
                                                       cabledDeviceNames: cabledNames,
                                                       attachedUDIDs: attachedUDIDs)
        for id in doomed {
            guard let s = session(for: id) else { continue }
            Log.info("two sessions for one device — keeping the cable, dropping \(s.id)")
            end(s)
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Labels for the refusal rows. Kept beside the (pure) backoff rather than
    /// inside it: the policy cares about deadlines, the panel cares about names.
    private var rejectionNames: [String: String] = [:]
    private var rejectionReasons: [String: String] = [:]

    private func refreshRejectionRows() {
        let now = Date()
        rejectionBackoff.prune(at: now)
        rejections = rejectionBackoff.suppressedIDs.compactMap { id in
            guard let until = rejectionBackoff.deadline(id) else { return nil }
            return RejectionRow(id: id, name: rejectionNames[id] ?? id, until: until,
                                reason: rejectionReasons[id] ?? "")
        }
        .sorted { $0.name < $1.name }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        let id = target.sessionID
        // The receiver refused this sender and asked for a delay (PROTOCOL.md
        // 6.6). Honour it exactly: no dial, so no display, no encoder and no
        // audio pipeline exist while the other Mac has the device. A deliberate
        // click overrides — the user is allowed to change their mind, and the
        // receiver will simply refuse again if they have not.
        if rejectionBackoff.isSuppressed(id, at: Date()) {
            guard userInitiated else { return }
            Log.info("user asked for \(id) while it was backing off from a refusal — dialing anyway")
            rejectionBackoff.clear(id)
            refreshRejectionRows()
        }
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb: usbDisabled.remove(id)
        case .wifi: wifiRemembered.insert(id)
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        }

        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, layout: sessionLayout,
                               layoutSource: sessionLayoutSource,
                               quality: quality, frameRate: frameRate,
                               displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender)
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onConnectedChange = { [weak self, weak session] up in
            guard let self, let session, session.connected != up else { return }
            session.connected = up
            // A `-host`/`-port` session that has just gone down stops
            // suppressing the LAN dial of the same receiver — and one that has
            // just come up starts. Either way the answer changed, so ask again
            // rather than waiting for the next browse event.
            self.autoConnect()
        }
        sender.onAudioDeliveryChange = { [weak self, weak session] active in
            guard let self, let session, session.audioDeliveryActive != active else { return }
            session.audioDeliveryActive = active
            self.updateSpeakerMute()
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session else { return }
            self.learnIdentity(of: session, from: info)
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        // Asked on the FIRST hello only, before the sender has created a
        // virtual display, an H.264 encoder or an audio encoder. Answering
        // here rather than in `dedupeSessions` is the fix for the 20:25
        // incident: the loser used to be dropped only *after* both sessions
        // had a display and both were encoding audio.
        sender.admitSession = { [weak self, weak session] info in
            guard let self, let session else { return false }
            // Record the identity first: the decision is about this very id,
            // and `onHello` may not have run yet (it is a separate hop onto
            // the main actor). Idempotent — both paths write the same values.
            self.learnIdentity(of: session, from: info)
            let others = self.sessions.filter { $0 !== session }.map(self.snapshot)
            let admitted = SessionDedupe.admits(self.snapshot(session),
                                                helloInstallID: info.id,
                                                others: others,
                                                cabledUDIDs: self.cableCoveringUDIDs,
                                                installIDByUDID: self.installIDByUDID)
            if !admitted {
                Log.info("refusing \(session.id) at hello — the cable already covers receiver "
                    + "\(info.id ?? "(unidentified)"); no display and no encoder will be created")
            }
            return admitted
        }
        sender.onStats = { [weak session] frames, mbps in
            session?.framesSent = frames
            session?.mbps = mbps
        }
        sender.onQualityLevel = { [weak session] level in
            session?.qualityLevel = level
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
            self.exitAfterReceiverLossIfConfigured()
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            if self.exitAfterReceiverLossIfConfigured() { return }
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired in
            session?.wired = wired
        }
        sender.onRejectedByReceiver = { [weak self, weak session] ms, reason in
            // The device is pointed at a different Mac. End this session
            // outright rather than leaving it retrying: ending is what
            // guarantees "no display, no encoder" for the backoff, and the row
            // that replaces it says why and for how long.
            guard let self, let session else { return }
            let until = Date().addingTimeInterval(Double(ms) / 1000)
            self.rejectionBackoff.note(session.id, until: until)
            self.rejectionNames[session.id] = session.name
            self.rejectionReasons[session.id] = reason
            let target = session.target
            let id = session.id
            self.end(session)
            self.refreshRejectionRows()
            // Come back when it expires. Not a timer that has to be cancelled:
            // `connect` re-checks the backoff, so an early wake is harmless and
            // a late one just dials.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(ms + 500))
                guard let self else { return }
                self.rejectionBackoff.prune(at: Date())
                self.refreshRejectionRows()
                Log.info("refusal backoff for \(id) expired — dialing again")
                self.connect(to: target)
            }
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            self.end(session)
            self.exitAfterReceiverLossIfConfigured()
        }
        sessions.append(session)
        // A dialer row is not a live stream. Host silence begins only after
        // `onAudioDeliveryChange(true)` proves the receiver can accept audio.
        updateSpeakerMute()
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch is SessionSuperseded {
                // Refused at its first hello because the cable already covers
                // this receiver. Nothing was built, so there is nothing to
                // report and nothing to retry: take the row away.
                Log.info("session \(id) stood down — the cable serves this receiver")
                self.end(session)
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                session.audioDeliveryActive = false
                self.updateSpeakerMute()
                sender.stop()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi: wifiRemembered.remove(session.id)
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if session.onUSB, let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0.id == session.id }
        updateSpeakerMute()   // the last session leaving un-mutes the speakers
    }

    // A supervised headless Mac may need its physical display restored before
    // accepting another receiver. Opt in on that Mac only; the supervisor
    // relaunches this app after the display is ready.
    @discardableResult
    private func exitAfterReceiverLossIfConfigured() -> Bool {
        guard sessions.isEmpty, UserDefaults.standard.bool(forKey: "exitAfterReceiverLoss") else {
            return false
        }
        Log.info("exitAfterReceiverLoss — quitting after session teardown")
        NSApp.terminate(nil)
        return true
    }

    /// Layout/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        updateSpeakerMute()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads, iPhones and Macs as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button("Disconnect All") { controller.disconnectAll() }
                        .controlSize(.large)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Section("Devices") {
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.rejections) { rejection in
                        HStack(alignment: .firstTextBaseline) {
                            Circle()
                                .fill(.orange)
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rejection.name)
                                Text(rejection.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = entry.preferredTarget {
                                    Button("Connect") {
                                        controller.connect(to: target, userInitiated: true)
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Session layout", selection: $controller.sessionLayout) {
                        ForEach(SessionLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: controller.sessionLayout) { controller.restartAll() }
                    Text(controller.sessionLayout.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if controller.sessionLayout == .remote {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Gather windows onto the session display",
                               isOn: $controller.gatherWindows)
                        Text("When the session starts, move the open windows from the "
                             + "other displays onto this one, and put them back when it "
                             + "ends. Unplugging a monitor does this automatically; a "
                             + "virtual display cannot, because the other displays are "
                             + "still connected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Command key", selection: $controller.commandKeyRemap) {
                        ForEach(CommandKeyRemap.allCases, id: \.self) { remap in
                            Text(remap.label).tag(remap)
                        }
                    }
                    Text(controller.commandKeyRemap.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // The iPad Magic Keyboard has no Escape key and no function
                // row. These three decide which of the keys it *does* have
                // stand in — see `KeyRemapPlan`.
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Escape key", selection: $controller.escapeKey) {
                        ForEach(EscapeKeySource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    Text(controller.escapeKey.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Globe key", selection: $controller.globeKey) {
                        ForEach(GlobeKeyAction.allCases, id: \.self) { action in
                            Text(action.label).tag(action)
                        }
                    }
                    Text(controller.globeKey.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Input-source key", selection: $controller.languageKey) {
                        ForEach(LanguageKeySource.allCases, id: \.self) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    Text(controller.languageKey.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let conflict = controller.keyRemapConflict {
                        Text(conflict)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Stream audio", isOn: $controller.audioEnabled)
                        .onChange(of: controller.audioEnabled) { controller.restartAll() }
                    Text("Sends this Mac's audio to the connected device. Needs OpenDisplay 4 or newer on the receiving end; older devices keep showing the picture only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Silence this Mac while streaming audio",
                           isOn: $controller.muteMacSpeakers)
                        .disabled(!controller.audioEnabled)
                    Text(controller.speakerMuteHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Frame rate", selection: $controller.frameRate) {
                        ForEach(FrameRate.allCases) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .onChange(of: controller.frameRate) { controller.restartAll() }
                    Text(controller.frameRate.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Adapt quality to the link", isOn: $controller.adaptiveQuality)
                    Text("When the connection cannot carry the configured bitrate — an LTE hop, a busy WiFi — the stream aims at what the link actually delivers instead: a continuous target rate, cut hard the moment the send queue backs up or latency starts climbing, and raised 10% at a time after fifteen seconds of clean statistics. Below about 1 Mbps it also drops the frame rate (120 → 60 → 30). The virtual display never changes, so the desktop layout never moves. `defaults write com.peetzweg.opensidecar.mac.alfheim adaptiveFloorKbps 800` sets the lowest rate it may ask for; `adaptiveMaxLever scale` additionally lets it shrink the captured size below the lowest frame rate, which is off by default. Takes effect on the next session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 540)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(session.transportLabel) · \(session.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if session.qualityLevel.index > 0 {
                Text(session.qualityLevel.label)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The link could not carry the configured bitrate, so the congestion controller lowered the frame rate and/or the captured size on top of the rate cut. It gives them back, one at a time, after fifteen seconds of clean statistics.")
            }
            if session.mbps > 0 {
                Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                if session.failed {
                    controller.retry(session)
                } else {
                    session.sender.forceReconnect()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(session.failed
                ? "Start this connection over"
                : "Drop the connection and pair with the device again")
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}
