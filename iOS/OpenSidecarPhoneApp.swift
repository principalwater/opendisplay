import SwiftUI
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Landing page — hosts the Mac app download and explains the two-app setup.
let macAppURL = URL(string: "https://peetzweg.github.io/opendisplay/")!

@main
struct OpenSidecarPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverScreen()
        }
    }
}

// MARK: - Shake to open settings

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

// MARK: - Root screen

struct ReceiverScreen: View {
    @StateObject private var model = ReceiverModel()
    @StateObject private var versionGate = VersionGate()
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var nagDismissed = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    // On-screen modifier sidebar (issue #7). Opt-in — see the note at its use.
    @AppStorage("showModifierSidebar") private var showModifierSidebar = false
    // The "Switch to…" quick action over the video. On by default, but it only
    // appears once this device has actually seen more than one Mac — until
    // then there is nothing to switch between and the pixels stay with the
    // video.
    @AppStorage("showMacSwitcher") private var showMacSwitcher = true
    @AppStorage(TouchMode.defaultsKey) private var touchModeRaw = TouchMode.default.rawValue
    // First-run onboarding (issue #49): explain the Mac app is required.
    // Shown until either the user dismisses it or the device connects once.
    @AppStorage("hasConnectedBefore") private var hasConnectedBefore = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    // Below the force floor → present the blocking gate (issue #135). The
    // fullScreenCover binding's setter is a no-op so the user can't dismiss it.
    private var requiredUpdate: VersionGate.Update? {
        if case let .required(update) = versionGate.status { return update }
        return nil
    }

    // Soft nag: shown once per launch, dismissible.
    private var recommendedUpdate: VersionGate.Update? {
        if case let .recommended(update) = versionGate.status, !nagDismissed { return update }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isStreaming {
                    Color.black.ignoresSafeArea()
                    VideoLayerView(displayLayer: model.receiver.displayLayer,
                                   receiver: model.receiver,
                                   useMetal: metalRenderer,
                                   touchMode: TouchMode(rawValue: touchModeRaw) ?? .default)
                        .id(metalRenderer)   // rebuild the layer tree on toggle
                        .ignoresSafeArea()
                    if showAnalytics {
                        VStack {
                            Spacer()
                            PerfOverlay(stats: model.receiver.perf,
                                        videoSize: model.receiver.videoSize)
                                .padding(.bottom, 10)
                        }
                        .allowsHitTesting(false)   // never block touch input
                    }
                    // Off by default: it is an accessibility affordance for a
                    // device with no hardware keyboard, and its collapsed
                    // button sits permanently over the left edge of the video,
                    // swallowing every touch that lands there. Anyone driving
                    // this from a Magic Keyboard wants the pixels back.
                    if showModifierSidebar {
                        HStack {
                            ModifierSidebarView(receiver: model.receiver)
                            Spacer()
                        }
                    }
                    // Switch Macs without leaving the stream. Deliberately tiny
                    // and translucent, in the one corner a remote desktop's
                    // menu bar is least likely to be aimed at, and gated on
                    // there being a choice to make at all.
                    if showMacSwitcher, model.receiver.knownSenders.count > 1 {
                        VStack {
                            HStack {
                                Spacer()
                                MacSwitcherButton(receiver: model.receiver)
                                    .padding(.top, 8)
                                    .padding(.trailing, 12)
                            }
                            Spacer()
                        }
                    }
                } else {
                    IdleView(receiver: model.receiver, showSettings: $showSettings)
                }
            }
            .onAppear { model.receiver.setOrientation(portrait: geo.size.height > geo.size.width) }
            .onChange(of: geo.size) { size in
                model.receiver.setOrientation(portrait: size.height > size.width)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { onboardingDismissed = true }
            }
        }
        .ignoresSafeArea(edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .systemOverlaysHidden(isStreaming)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver)
        }
        // Below the force floor → blocking gate. Setter is a no-op: the user
        // cannot dismiss it, only update.
        .fullScreenCover(item: Binding(get: { requiredUpdate }, set: { _ in })) { update in
            UpdateRequiredView(update: update)
        }
        // At/above the floor but behind the recommended version → soft nag.
        .alert("Update available",
               isPresented: Binding(get: { recommendedUpdate != nil },
                                    set: { if !$0 { nagDismissed = true } })) {
            Button("Update") {
                if let update = recommendedUpdate { UIApplication.shared.open(update.url) }
            }
            Button("Later", role: .cancel) { nagDismissed = true }
        } message: {
            if let update = recommendedUpdate { Text(update.message) }
        }
        .task { await versionGate.check() }
        // Merge the connected Mac's compatibility signal into the same gate.
        .onReceive(model.receiver.$peerSignal) { versionGate.applyPeer($0) }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            showSettings = true
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active: model.sceneDidActivate()
            case .background: model.sceneDidBackground()
            default: break
            }
        }
        // The deliberate "screen off" signal: locking the device makes
        // protected data unavailable (a plain app switch doesn't). This is
        // what separates "put the iPhone to sleep — end the session now"
        // from "peeked at a message — keep the session alive".
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Log.info("protected data will become unavailable (device locking)")
            model.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Log.info("protected data available again (device unlocked)")
            model.deviceDidUnlock()
        }
        // Swiping the app away in the switcher (while we're still running)
        // grants a ~5s notice — enough for a clean goodbye so the Mac ends
        // the session at once. A kill without notice is covered Mac-side:
        // dead apps stop accepting redials, so the silence grace fires.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            model.appWillTerminate()
        }
        .onChange(of: model.receiver.connected) { isConnected in
            // The first valid connection retires the onboarding hint for good.
            if isConnected {
                hasConnectedBefore = true
                showOnboarding = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.start()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
        }
    }
}

/// The "Switch to…" quick action: one tap, a menu of every Mac this device has
/// seen, and the switch happens on the wire immediately — the Mac being left is
/// sent `rejected` with a short backoff, so the one being chosen is accepted on
/// its very next dial.
struct MacSwitcherButton: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        Menu {
            Picker("Connect to", selection: Binding(
                get: { receiver.preferredSenderID },
                set: { receiver.chooseSender($0) })) {
                Text("Any Mac").tag(SenderChoice.anyMac)
                ForEach(receiver.knownSenders) { sender in
                    Text(sender.displayName).tag(sender.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "desktopcomputer")
                Text(receiver.currentSender?.displayName ?? "Mac")
                    .lineLimit(1)
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .opacity(0.5)
    }
}

// MARK: - Idle view (no Mac connected) — regular iOS look, follows light/dark

struct IdleView: View {
    @ObservedObject var receiver: StreamReceiver
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 132)

            VStack(spacing: 6) {
                Text("OpenDisplay")
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Circle()
                        .fill(receiver.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(receiver.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Plug in the USB cable and start the Mac app",
                      systemImage: "cable.connector")
                Label("Or choose this \(deviceKind) under WiFi in the Mac app",
                      systemImage: "wifi")
                Label("Keep this app open — streaming starts automatically",
                      systemImage: "play.circle")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: 420)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings & Help", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Text("Tip: shake the \(deviceKind) to open settings anytime")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: OpenDisplay
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    var body: some View {
        AdaptiveNavigation {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    VStack(spacing: 10) {
                        Text("One more app to go")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("OpenDisplay turns this \(deviceKind) into a second screen for your Mac — but it needs the **OpenDisplay Mac app** running on a Mac connected by the same USB cable or on the same WiFi network.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Install the OpenDisplay Mac app on your Mac", systemImage: "1.circle.fill")
                        Label("Connect the \(deviceKind) by USB, or join the same WiFi", systemImage: "2.circle.fill")
                        Label("Keep this app open — streaming starts on its own", systemImage: "3.circle.fill")
                    }
                    .font(.subheadline)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))

                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("You can find this link again anytime in Settings — shake the \(deviceKind) to open it.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: StreamReceiver
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    @AppStorage("showModifierSidebar") private var showModifierSidebar = false
    @AppStorage("showMacSwitcher") private var showMacSwitcher = true
    @AppStorage(TouchMode.defaultsKey) private var touchModeRaw = TouchMode.default.rawValue

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        AdaptiveNavigation {
            Form {
                Section("Status") {
                    LabeledRow("Listening", value: "Port 9000")
                    LabeledRow("Connection",
                               value: receiver.connected ? "Connected" : "Waiting for Mac")
                    if receiver.videoSize != .zero {
                        LabeledRow("Stream",
                                   value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                    }
                }

                Section {
                    // Isolated from the receiver: the Status section above
                    // re-renders on every stream update, and a TextField that
                    // rebuilds mid-tap loses focus (the "tap twice to edit"
                    // bug). This subview owns its focus and doesn't observe
                    // the receiver, so it survives those rebuilds.
                    DeviceNameField { receiver.setServiceName($0) }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the Mac app's WiFi connection menu. iOS hides this \(deviceKind)'s real name from apps, so set it here once.")
                }

                Section {
                    Picker("Connect to", selection: Binding(
                        get: { receiver.preferredSenderID },
                        set: { receiver.chooseSender($0) })) {
                        Text("Any Mac").tag(SenderChoice.anyMac)
                        ForEach(receiver.knownSenders) { sender in
                            Text(sender.displayName).tag(sender.id)
                        }
                    }
                    if let current = receiver.currentSender {
                        LabeledContent("Now connected to", value: current.displayName)
                    }
                    Toggle("Switcher button while streaming", isOn: $showMacSwitcher)
                        .disabled(receiver.knownSenders.count < 2)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Macs dial this \(deviceKind), so with two of them running OpenDisplay the first one to connect wins. Pick one here and the others are politely refused and told to retry later — switching back is one tap, and the Mac you left comes back within seconds. “Any Mac” is the original behaviour. The switcher button is a small control in the top corner of the video that does the same thing without opening these settings.")
                }

                Section {
                    Picker("Touch mode", selection: $touchModeRaw) {
                        ForEach(TouchMode.allCases) { mode in
                            Text(mode.label).tag(mode.rawValue)
                        }
                    }
                    Text((TouchMode(rawValue: touchModeRaw) ?? .default).hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("On-screen modifier keys", isOn: $showModifierSidebar)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Touch mode changes what your fingers do on the glass; the Magic Keyboard trackpad, a mouse and the Apple Pencil behave the same either way. The modifier panel adds a small ⌘ ⌥ ⌃ ⇧ strip to the left edge while streaming, for latching modifiers without a hardware keyboard — its button covers that strip of the video, so leave it off if you use a keyboard.")
                }

                Section {
                    // Stored as `audioMuted` (the receiver's own field, shared
                    // with the Mac receiver app) but shown the way round the
                    // user thinks about it: this fork streams audio by default,
                    // so the switch people look for is "is the sound on".
                    Toggle("Play Mac audio", isOn: Binding(
                        get: { !receiver.audioMuted },
                        set: { receiver.audioMuted = !$0 }))
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Plays the sound from your Mac through this \(deviceKind). The Mac app has its own “Stream audio” switch that decides whether the sound is sent at all. Turning this off silences it without interrupting the stream, and audio from other apps keeps playing either way.")
                }

                Section {
                    Toggle("Performance overlay", isOn: $showAnalytics)
                    Toggle("Metal renderer (experimental)", isOn: $metalRenderer)
                } header: {
                    Text("Analytics")
                } footer: {
                    Text("The overlay shows FPS, bitrate, frame timing, stalls, and latency graphs at the bottom of the screen while streaming. The experimental Metal renderer decodes and presents frames manually — it adds decode and true on-glass latency metrics to the overlay, but in our measurements the system video layer displays frames faster. Leave it off unless you're debugging.")
                }

                Section {
                    Button("Open iOS Settings for OpenDisplay") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("WiFi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → OpenDisplay. USB mode works without it.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        Label("Connection log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("What this \(deviceKind) saw while connecting: sessions, restarts, decoder trouble. No screen content and nothing leaves the \(deviceKind) unless you share it. Attach it to a GitHub issue if a connection won't come up.")
                }

                Section {
                    Label("USB: plug in the cable, run the Mac app — it connects automatically through the wire (lowest latency).",
                          systemImage: "cable.connector")
                    Label("WiFi: both devices on the same network, then pick this \(deviceKind) in the Mac app's Connection menu.",
                          systemImage: "wifi")
                    Label("Rotate the \(deviceKind) for a vertical second monitor.",
                          systemImage: "rectangle.portrait.rotate")
                    Label("Touch: tap to click, drag to drag, two-finger pan to scroll.",
                          systemImage: "hand.tap")
                } header: {
                    Text("How to connect")
                }

                Section {
                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("OpenDisplay needs the Mac app running on a Mac on the same cable or WiFi network. Download it here if you haven't yet.")
                }

                Section("About") {
                    LabeledRow("Version", value: version)
                    Link(destination: URL(string: "https://github.com/peetzweg/opendisplay")!) {
                        Label("GitHub — peetzweg/opendisplay", systemImage: "link")
                    }
                    Link(destination: macAppURL) {
                        Label("Website", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("OpenDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// `NavigationStack` where it exists (iOS 16), a single-column
/// `NavigationView` on the iOS 15 floor. Both sheets here are one level deep,
/// so the two behave the same; this keeps the modern API where it is available.
struct AdaptiveNavigation<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 16, *) {
            NavigationStack { content() }
        } else {
            NavigationView { content() }
                .navigationViewStyle(.stack)
        }
    }
}

/// `LabeledContent` where it exists (iOS 16, with its VoiceOver pairing of
/// label and value); the equivalent HStack on the iOS 15 floor.
struct LabeledRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if #available(iOS 16, *) {
            LabeledContent(title, value: value)
        } else {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    /// Hide the home indicator while streaming. `persistentSystemOverlays`
    /// is iOS 16; on iOS 15 the indicator simply stays, which is what the
    /// app did before it existed.
    @ViewBuilder
    func systemOverlaysHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16, *) {
            persistentSystemOverlays(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }
}

/// The device-name editor, deliberately kept out of any high-frequency
/// @ObservedObject so streaming updates can't rebuild it and steal focus.
private struct DeviceNameField: View {
    @AppStorage("deviceName") private var deviceName = UIDevice.current.name
    @FocusState private var focused: Bool
    let onChange: (String) -> Void

    var body: some View {
        TextField("Device name", text: $deviceName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focused)
            .onChange(of: deviceName) { name in onChange(name) }
    }
}

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name)
        // Announce the native panel size to the Mac.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        receiver.setDisplayMaxFrameRate(UIScreen.main.maximumFramesPerSecond)
        if let budget = DecodeBudget.maxPixelsPerSecond(model: DecodeBudget.currentModel) {
            receiver.setDecodeBudget(maxPixelsPerSecond: budget)
        }
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        receiver.serviceName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        observeAudioSessionBreaks()
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start(port: 9000)
    }

    // MARK: - Lock vs app switch vs app quit

    // A plain app switch keeps the session (and the Mac's virtual display,
    // and therefore the user's window arrangement) alive INDEFINITELY. The
    // assertion buys ~30s of live pings; after iOS suspends us the kernel
    // still accepts the Mac's redials, so the session survives untouched
    // until we return. Only a device lock (deliberate "screen off") or the
    // app being quit ends the session. Known hole: a lock that happens
    // after we're already suspended is undetectable — no code runs and the
    // kernel behaves identically — so the display stays up until the user
    // returns or the app dies.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        configureAudioSession()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
    }

    /// Put the audio session in a state where streamed desktop audio can play.
    ///
    /// `.playback` is the category, which carries two consequences worth
    /// stating rather than discovering:
    ///
    /// * **The ring/silent switch is ignored.** `.playback` is the "this is
    ///   the content, not a sound effect" category, and iOS does not silence
    ///   it. That is the right answer here: the sound is the Mac's, the user
    ///   flipped that switch to silence *this device's* notifications, and a
    ///   monitor that goes mute because of a hardware switch on its stand is a
    ///   support question, not a feature. The in-app "Play Mac audio" switch
    ///   and the Mac's own "Stream audio" toggle are the two deliberate ways
    ///   to turn it off.
    /// * **It plays with the screen on only.** This build claims no `audio`
    ///   background mode (see Info.plist — `UIBackgroundModes` is absent), so
    ///   iOS stops the session when the app leaves the foreground. The
    ///   receiver stops the engine itself on the way out, in
    ///   `setRenderingPaused(true)`, rather than being cut off mid-buffer.
    ///
    /// `.mixWithOthers` is deliberate: using this as a second display should
    /// not stop whatever the user already had playing. Someone who wants the
    /// Mac's audio to take over can pause the other app; the reverse — being
    /// silently interrupted by plugging in a display — is not recoverable by
    /// the user at all.
    ///
    /// Failure is non-fatal. Audio is an optional addition to a display, and
    /// the picture must keep working on a device that refuses the session.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // **Idempotent.** `setCategory` posts a `.categoryChange` route
            // change even when nothing changed, and the route-change observer
            // below rebuilds the audio graph — so the round-5 build tore the
            // engine down and rebuilt it on every single foreground, for no
            // reason, dropping the jitter buffer each time. Asking only when
            // the answer would differ removes the loop at its source rather
            // than filtering it at the other end (which is also done, because
            // one of the two alone is not a guarantee).
            if session.category != .playback || session.mode != .default
                || session.categoryOptions != [.mixWithOthers] {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                Log.info("audio session: category playback/.mixWithOthers")
            }
            try session.setActive(true)
        } catch {
            Log.info("audio session unavailable (\(error)) — video only")
        }
    }

    /// True between an interruption's `.began` and its `.ended`.
    ///
    /// iOS does not promise one `.ended` per `.began` — a `.began` delivered
    /// as the app suspends often has no `.ended` at all, and the round-5 log
    /// has five `audio session interrupted` lines and not one resumption,
    /// every one of them in the same tenth of a second as
    /// `scenePhase -> background`. Handling `.ended` unconditionally therefore
    /// means rebuilding the graph for interruptions that never happened.
    private var audioInterrupted = false

    /// Bring audio back after the system took the session away.
    ///
    /// An interruption (a call, Siri, another app) stops the engine producing
    /// sound but leaves every object alive, and packets keep arriving and
    /// being decoded into a graph nobody hears — so without this the first
    /// interruption ends audio for the rest of the session while the picture
    /// carries on, which reads as "the audio feature is flaky". A route change
    /// (headphones out, a Bluetooth speaker appearing) needs the same rebuild
    /// because the engine's output format follows the route.
    private func observeAudioSessionBreaks() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: AVAudioSession.sharedInstance(),
                           queue: .main) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                guard !self.audioInterrupted else { return }
                self.audioInterrupted = true
                // Stop the engine ourselves rather than leaving the drain
                // timer decoding into a node that is no longer producing
                // sound: those buffers are scheduled, never consumed (the
                // node is stopped, so no completion fires), and playback
                // deadlocks at `maxScheduled` until something else rebuilds
                // the graph. Stopping discards them cleanly.
                Task { @MainActor in
                    self.receiver.suspendAudio()
                    Log.info("audio session interrupted — engine stopped")
                }
            case .ended:
                guard self.audioInterrupted else {
                    Log.info("audio session interruption ended with no begin — ignored")
                    return
                }
                self.audioInterrupted = false
                // Already on the main queue (the observer asked for it), but
                // the compiler cannot see that through a `@Sendable` closure
                // and `MainActor.assumeIsolated` needs iOS 17.
                Task { @MainActor in
                    // Re-activate before rebuilding: an engine started against
                    // an inactive session starts and stays silent.
                    self.configureAudioSession()
                    self.receiver.resumeAudio()
                    Log.info("audio session interruption ended — engine rebuilt")
                }
            @unknown default:
                break
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: AVAudioSession.sharedInstance(),
                           queue: .main) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                ?? .unknown
            // **Only the reasons that actually change where the sound goes.**
            // The engine's output format follows the route, so a device
            // appearing or disappearing needs a rebuild. `.categoryChange` is
            // the one we cause ourselves from `configureAudioSession`, and
            // `.routeConfigurationChange` is a property of a route we are
            // already on — rebuilding for either is a self-inflicted gap in
            // the audio every time the app comes forward.
            switch reason {
            case .newDeviceAvailable, .oldDeviceUnavailable, .override,
                 .wakeFromSleep, .noSuitableRouteForCategory:
                Log.info("audio route changed (\(Self.routeChangeName(reason))) — rebuilding the engine")
                Task { @MainActor in self.receiver.restartAudioEngine() }
            default:
                break
            }
        }
    }

    private static func routeChangeName(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "a new device appeared"
        case .oldDeviceUnavailable: return "the device went away"
        case .categoryChange: return "category change"
        case .override: return "overridden"
        case .wakeFromSleep: return "wake from sleep"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route reconfigured"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background
    /// — don't re-arm the listener or unpause rendering off-screen there;
    /// the real return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of after its silence grace.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Suspension takes us now; the session stays up by design (the
            // kernel keeps accepting for us) — just release the assertion.
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: StreamReceiver
    let useMetal: Bool
    /// Which finger gestures are live. Applied in `updateUIView`, so changing
    /// it in settings takes effect without rebuilding the layer tree — which
    /// matters, because rebuilding it would drop the decoder session.
    let touchMode: TouchMode

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver

        // The two numbers that say whether 120 can reach the glass at all: the
        // panel's own ceiling, and whether this build asked to be allowed near
        // it (`CADisableMinimumFrameDurationOnPhone`, see project.yml). Logged
        // because the device install is the master's job — this line is how a
        // ProMotion problem is diagnosed from the log rather than guessed at.
        let maxHz = UIScreen.main.maximumFramesPerSecond
        let highRefreshAllowed = Bundle.main
            .object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool ?? false
        Log.info("video view: metal=\(useMetal) panel=\(maxHz)Hz max, "
                 + "high refresh \(highRefreshAllowed ? "enabled" : "NOT declared — capped at 60")")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            view.metalRenderer = renderer
            view.layer.addSublayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            displayLayer.frame = view.bounds
            view.layer.addSublayer(displayLayer)
        }

        view.inputEngine.normalize = { [weak view] point in view?.normalized(point) }
        view.inputEngine.onPencil = { [weak receiver] phase, x, y, pressure, azimuth, altitude in
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        view.inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        view.inputEngine.install(on: view)

        let pan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        // Fingers only. A Magic Keyboard trackpad arrives as a single
        // `.indirectPointer` touch and scrolls as a scroll event, neither of
        // which should be able to drive the two-finger *touch* pan.
        pan.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        view.addGestureRecognizer(pan)
        view.trackpadStylePan = pan

        // --- Native touch mode ---------------------------------------------
        //
        // Four recognizers, all fingers-only, all disabled in Trackpad-style
        // mode (`applyTouchMode`). The arbitration between them is the whole
        // design: a tap must not fire when the user meant to scroll, a scroll
        // must not start when the user is holding still waiting to drag, and a
        // drag that has started must own the finger until it is released.
        let nativePan = HoldTolerantPanGestureRecognizer(
            target: view, action: #selector(VideoView.didNativePan(_:)))
        nativePan.minimumNumberOfTouches = 1
        // Two fingers scroll too. One is the point of the mode, but a
        // two-finger scroll is muscle memory from the trackpad and there is no
        // reason to make it stop working.
        nativePan.maximumNumberOfTouches = 2
        nativePan.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        nativePan.delegate = view
        view.addGestureRecognizer(nativePan)
        view.nativePan = nativePan

        // Touch and hold. On iPadOS this is the context-menu gesture, and what
        // it does next depends on what the finger does next: lift without
        // moving = the menu (a right click here), move = pick the thing up and
        // drag it. Both live in `didNativeLongPress`.
        let nativeLongPress = UILongPressGestureRecognizer(
            target: view, action: #selector(VideoView.didNativeLongPress(_:)))
        nativeLongPress.minimumPressDuration = VideoView.holdDuration
        nativeLongPress.numberOfTouchesRequired = 1
        // Tighter than the pan's own ~10pt threshold, and that ordering is the
        // arbitration: a finger that is really starting a scroll passes 8pt
        // (the hold fails) before it passes 10pt (the pan begins), so "moved
        // first = scroll" needs no tie-break. `allowableMovement` applies ONLY
        // until the press duration elapses; once the recognizer is `.began`,
        // UIKit reports every later sample as `.changed` however far the finger
        // travels, which is what makes hold-then-drag possible.
        // `HoldDragMachine.defaultCommitSlop` is the separate constant for the
        // distance that turns a committed hold into a drag.
        nativeLongPress.allowableMovement = VideoView.holdSlop
        nativeLongPress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        nativeLongPress.delegate = view
        view.addGestureRecognizer(nativeLongPress)
        view.nativeLongPress = nativeLongPress

        // The tie-break, made structural.
        //
        // The round-4 log shows 10 pan sessions and exactly ONE long press in a
        // whole session of trying to drag: the pan was taking fingers the hold
        // was still entitled to. The ordering of the two thresholds says it
        // should not (`HoldPriority`: the hold's 8 pt `allowableMovement` fails
        // *before* the pan's ~10 pt start threshold is reached), but "should
        // not" was doing the work, and UIKit is free to start a pan on velocity
        // as well as distance.
        //
        // This edge makes it a guarantee, and — this is why it is acceptable —
        // it costs a real scroll nothing. A long press enters `.failed` the
        // instant movement exceeds 8 pt, which for any finger that is actually
        // scrolling happens before the pan could have begun anyway; it is not
        // the 0.4 s wait `require(toFail:)` on a *duration* would impose,
        // because the distance limit fails first. A finger that stays inside
        // 8 pt for 0.4 s is holding, not scrolling, and the hold is right to
        // have it. Two fingers fail the hold immediately
        // (`numberOfTouchesRequired = 1`), so two-finger scrolling is untouched.
        nativePan.require(toFail: nativeLongPress)

        let nativeTap = UITapGestureRecognizer(target: view, action: #selector(VideoView.didNativeTap(_:)))
        nativeTap.numberOfTouchesRequired = 1
        nativeTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        nativeTap.delegate = view
        // A tap is what is left when the finger neither moved nor stayed: both
        // of the other two have to fail first.
        //
        // Neither edge costs latency, and for a double tap that is the whole
        // question — the Mac counts the clicks, so the second one has to reach
        // it inside `NSEvent.doubleClickInterval` (0.5 s by default) of the
        // first. A long press fails the instant the finger lifts before its
        // 0.4 s is up; a pan that never began fails the instant the last touch
        // ends. Both happen in the same event pass as the tap's own
        // recognition, so the click still lands on touch-up and two taps 250 ms
        // apart arrive 250 ms apart. (A pan that *did* begin never enters
        // `.failed`, so the tap stays blocked for that sequence — which is
        // correct: a scroll is not a tap.)
        //
        // The long-press edge is also what keeps a hold released in place from
        // being *both* a right click and a left one: it recognized, so it never
        // fails, so the tap never fires.
        //
        // What is deliberately NOT here: a second `UITapGestureRecognizer` with
        // `numberOfTapsRequired = 2`. Every single tap would then have to wait
        // out the double-tap window before it could fire, which is a ~350 ms
        // delay on every click in exchange for a count the Mac already keeps.
        nativeTap.require(toFail: nativeLongPress)
        nativeTap.require(toFail: nativePan)
        view.addGestureRecognizer(nativeTap)
        view.nativeTap = nativeTap

        let nativePinch = UIPinchGestureRecognizer(target: view, action: #selector(VideoView.didNativePinch(_:)))
        nativePinch.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        nativePinch.delegate = view
        view.addGestureRecognizer(nativePinch)
        view.nativePinch = nativePinch

        // Arm the right set. Not via the `touchMode` setter: its `didSet` only
        // fires on a *change*, and the initial value is usually already the
        // default — which would leave every recognizer at its `isEnabled`
        // default of true, so a two-finger pan would drive both the native and
        // the trackpad-style handler and scroll twice as far.
        view.touchMode = touchMode
        view.applyTouchMode()

        // Two-finger tap = right click, in BOTH modes: there is no other way to
        // reach a context menu from the glass, and it conflicts with nothing.
        let twoFingerTap = UITapGestureRecognizer(target: view, action: #selector(VideoView.didTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        view.addGestureRecognizer(twoFingerTap)
        // Held weakly only so a cancelled pinch can name what took its fingers
        // (`whatTookThePinch`) — this recognizer is deliberately outside the
        // Native arbitration and keeps UIView's own answers.
        view.twoFingerTap = twoFingerTap

        // Trackpad / mouse wheel scrolling. iPadOS delivers those as *scroll
        // events*, not touches, so the touch pan above never saw them and
        // two-finger scrolling on the Magic Keyboard did nothing at all. An
        // empty `allowedTouchTypes` plus `allowedScrollTypesMask` makes this
        // recognizer scroll-only, so it cannot compete with the finger pan.
        let scrollPan = UIPanGestureRecognizer(target: view, action: #selector(VideoView.didIndirectScroll(_:)))
        scrollPan.allowedTouchTypes = []
        scrollPan.allowedScrollTypesMask = [.continuous, .discrete]
        view.addGestureRecognizer(scrollPan)

        // Trackpad pointer hover -> Mac cursor. Mirrors the Pencil hover
        // recognizer in InputCaptureEngine, restricted to the indirect pointer
        // so fingers and the Pencil keep their own paths.
        let pointerHover = UIHoverGestureRecognizer(target: view, action: #selector(VideoView.didPointerHover(_:)))
        pointerHover.allowedTouchTypes = [UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        view.addGestureRecognizer(pointerHover)

        // Exactly one cursor on screen. The Mac already streams its own cursor
        // position (and sprite) over the cursor channel and this view draws it
        // in `cursorLayer`, so leaving the iPadOS pointer visible would show
        // two pointers chasing each other a round-trip apart. Hide the local
        // one while it is over the video; it reappears the moment it leaves.
        view.addInteraction(UIPointerInteraction(delegate: view))

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed
        // (first frames land after the connect-time sprite) or that the
        // previous view held (metal-renderer toggle rebuilds the view tree).
        if let sprite = receiver.cursorSprite {
            view.setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        view.moveCursor(x: state.x, y: state.y, visible: state.visible)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.touchMode = touchMode
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
        // Presenting the settings sheet (or the update gate) moves first
        // responder off the video view and SwiftUI never gives it back, which
        // silently kills the hardware keyboard for the rest of the session.
        // Every one of those presentations is a state change in ReceiverScreen,
        // so its body re-runs and lands here — the natural place to re-claim it.
        uiView.ensureKeyboardFocus()
    }

    /// A pan that does not exist until the finger has really moved.
    ///
    /// The whole of `PanSlopGate`'s reasoning applies; the UIKit half is three
    /// overrides and one rule: **while the recognizer is still `.possible`, a
    /// move it must not act on is simply not delivered to `super`.** UIKit
    /// cannot begin a gesture from a touch it was never told moved, so there
    /// is no refusal to express, nothing to un-begin, and — unlike
    /// `gestureRecognizerShouldBegin` returning false — no way to lose the
    /// rest of the sequence for a finger that starts slowly and then really
    /// does scroll.
    ///
    /// Once the gate opens, every later move goes straight through: a drag in
    /// progress must never be re-arbitrated.
    ///
    /// It also settles the two-finger question (`PinchArbiter`): fingers that
    /// change their separation decisively belong to the pinch, and this
    /// recognizer fails itself rather than racing for them.
    final class HoldTolerantPanGestureRecognizer: UIPanGestureRecognizer {

        private var gate = PanSlopGate()
        /// The touches this recognizer is tracking, in arrival order.
        /// `UITouch` is a reference type UIKit reuses, so identity is the only
        /// safe key and a plain array keeps the centroid stable.
        private var tracked: [UITouch] = []
        private var initialSpread: CGFloat?

        /// How far the centroid had travelled when the gate opened. The
        /// honest replacement for round 5's `translation(in:)` diagnostic,
        /// which measured the recognizer's own re-based translation and
        /// therefore always read near zero.
        private(set) var openedAfter: CGFloat = 0
        private(set) var withheldMoves = 0
        private(set) var yieldedToPinch = false

        override func reset() {
            super.reset()
            gate.reset()
            tracked.removeAll()
            initialSpread = nil
            openedAfter = 0
            withheldMoves = 0
            yieldedToPinch = false
        }

        private var trackedLocations: [CGPoint] {
            tracked.map { $0.location(in: view) }
        }

        private var currentSpread: CGFloat? {
            let points = trackedLocations
            guard points.count == 2 else { return nil }
            return PinchArbiter.spread(points[0], points[1])
        }

        private func rebase() {
            guard let centroid = PanSlopGate.centroid(of: trackedLocations) else { return }
            gate.touchCountChanged(centroid: centroid)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches where !tracked.contains(where: { $0 === touch }) {
                tracked.append(touch)
            }
            rebase()
            initialSpread = currentSpread
            super.touchesBegan(touches, with: event)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if state == .possible {
                if let initial = initialSpread, let now = currentSpread,
                   PinchArbiter.panYieldsToPinch(initialSpread: initial, currentSpread: now) {
                    yieldedToPinch = true
                    state = .failed
                    return
                }
                guard let centroid = PanSlopGate.centroid(of: trackedLocations) else { return }
                guard gate.shouldForward(centroid: centroid) else {
                    withheldMoves = gate.withheld
                    return
                }
                openedAfter = gate.openedAfter
            }
            super.touchesMoved(touches, with: event)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            tracked.removeAll { touch in touches.contains(where: { $0 === touch }) }
            rebase()
            initialSpread = currentSpread
            super.touchesEnded(touches, with: event)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            tracked.removeAll { touch in touches.contains(where: { $0 === touch }) }
            rebase()
            initialSpread = currentSpread
            super.touchesCancelled(touches, with: event)
        }
    }

    final class VideoView: UIView, UIPointerInteractionDelegate, UIGestureRecognizerDelegate {
        weak var receiver: StreamReceiver?
        var metalRenderer: MetalVideoRenderer?
        let inputEngine = InputCaptureEngine()

        // MARK: - Touch mode
        //
        // Which set of finger gestures is live. Set from `updateUIView`, so it
        // follows the AppStorage value without the view being rebuilt.

        var touchMode: TouchMode = .default {
            didSet {
                guard oldValue != touchMode else { return }
                applyTouchMode()
            }
        }

        weak var trackpadStylePan: UIPanGestureRecognizer?
        weak var nativePan: UIPanGestureRecognizer?
        weak var nativeLongPress: UILongPressGestureRecognizer?
        weak var nativeTap: UITapGestureRecognizer?
        weak var nativePinch: UIPinchGestureRecognizer?
        weak var twoFingerTap: UITapGestureRecognizer?

        /// Swap the two gesture sets. Switching mid-session must not be able to
        /// leave a button held or a momentum timer running, so both are ended
        /// before anything is re-enabled.
        func applyTouchMode() {
            endNativeHold(cancelled: true)
            stopMomentum(announce: true)
            swallowingTouch = false
            let native = touchMode == .native
            nativePan?.isEnabled = native
            nativeLongPress?.isEnabled = native
            nativeTap?.isEnabled = native
            nativePinch?.isEnabled = native
            // In Native mode the one-finger pan already covers two fingers, and
            // leaving the trackpad-style recognizer armed would give a
            // two-finger scroll two sources of deltas.
            trackpadStylePan?.isEnabled = !native
            if native { discardPendingDown() }
            Log.info("touch mode: \(touchMode.rawValue)")
        }

        private let cursorLayer: CALayer = {
            let layer = CALayer()
            layer.isHidden = true
            layer.zPosition = 10
            // Position updates arrive at 120Hz — implicit animations would
            // smear the cursor behind every move.
            layer.actions = ["position": NSNull(), "contents": NSNull(),
                             "bounds": NSNull(), "hidden": NSNull()]
            return layer
        }()
        private var cursorNormSize = CGSize.zero
        private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
        private var cursorVisible = false

        private var lastLoggedLayout = ""

        override func layoutSubviews() {
            super.layoutSubviews()
            ensureKeyboardFocus()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let renderer = metalRenderer {
                // The metal layer scales its drawable to fill its frame, so
                // the frame itself must be the aspect-fit rect.
                renderer.metalLayer.frame = videoRect() ?? bounds
            } else {
                // AVSBDL aspect-fits internally (videoGravity) — full bounds.
                layer.sublayers?.first?.frame = bounds
            }
            if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
            updateCursorLayout()
            CATransaction.commit()
            // Rotation diagnostics — one line per layout change.
            let video = receiver?.videoSize ?? .zero
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(layer.sublayers?.first?.frame.width ?? -1))x\(Int(layer.sublayers?.first?.frame.height ?? -1))"
            if line != lastLoggedLayout {
                lastLoggedLayout = line
                Log.info(line)
            }
        }

        /// Aspect-fit rect of the video inside the view (inverse of normalized()).
        /// The arithmetic lives in `VideoGeometry`, which is pure and tested —
        /// the metal layer's frame, the cursor sprite and every normalized
        /// touch have to agree on this rect, and three copies of it would not.
        private func videoRect() -> CGRect? {
            guard let video = receiver?.videoSize else { return nil }
            return VideoGeometry.videoRect(bounds: bounds.size, videoSize: video)
        }

        func moveCursor(x: Double, y: Double, visible: Bool) {
            cursorNorm = CGPoint(x: x, y: y)
            cursorVisible = visible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = !visible || cursorLayer.contents == nil
            updateCursorLayout()
            CATransaction.commit()
        }

        func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
            cursorLayer.anchorPoint = anchor
            cursorNormSize = normSize
            cursorLayer.isHidden = !cursorVisible
            updateCursorLayout()
            CATransaction.commit()
        }

        private func updateCursorLayout() {
            guard let rect = videoRect(), cursorNormSize != .zero else { return }
            cursorLayer.bounds = CGRect(x: 0, y: 0,
                                        width: cursorNormSize.width * rect.width,
                                        height: cursorNormSize.height * rect.height)
            cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                           y: rect.minY + cursorNorm.y * rect.height)
        }

        // The video is aspect-fit inside the view; map view coords into the
        // displayed video rect and normalize to [0,1]. `VideoGeometry` (pure,
        // tested) owns the arithmetic — the letterbox offset is the thing that
        // silently puts a touch a centimetre from where the user aimed, and it
        // is not something to have three hand-written copies of.
        fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
            guard let video = receiver?.videoSize else { return nil }
            return VideoGeometry.normalize(point, bounds: bounds.size, videoSize: video)
        }

        /// A fingertip on the glass. Deliberately *not* `.indirectPointer`:
        /// upstream lumped the trackpad pointer in with fingers, which sent it
        /// through the two-finger-cancel and press-and-hold machinery meant for
        /// touch — including a 120 ms delay before every trackpad click, and no
        /// way to express a secondary click. Pointer touches now have their own
        /// path (`sendPointerTouch`).
        private func isFinger(_ touch: UITouch) -> Bool {
            touch.type == .direct
        }

        /// A Magic Keyboard trackpad (or a mouse) driving the iPadOS pointer.
        private func isPointer(_ touch: UITouch) -> Bool {
            touch.type == .indirectPointer
        }

        private func isPencil(_ touch: UITouch) -> Bool {
            touch.type == .pencil
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        @objc func didTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            switch recognizer.state {
            case .began:
                twoFingerActive = true
                lastPan = .zero
                // macOS delivers scroll to whatever sits under the cursor, and
                // the cursor no longer follows the fingers now that a press is
                // withheld until it commits. Put it on the gesture once, up
                // front, so the scroll lands on the window being touched. Once
                // only: a real trackpad does not drag the cursor while
                // scrolling, and moving it mid-gesture would change the target.
                if let n = normalized(recognizer.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
            case .changed:
                let t = recognizer.translation(in: self)
                let scale = min(bounds.width / video.width, bounds.height / video.height)
                // Deltas in video pixels, natural-scrolling direction.
                receiver?.sendScroll(dx: (t.x - lastPan.x) / scale,
                                     dy: (t.y - lastPan.y) / scale)
                lastPan = t
            default:
                twoFingerActive = false
            }
        }

        @objc func didTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let video = receiver?.videoSize, video != .zero else { return }
            // A pinch that has only just been recognized has fingers that have
            // barely moved, which is also what a two-finger tap looks like —
            // and UIKit resolves that in the tap's favour, cancelling the
            // pinch. Round 7's `zoom: cancelled — 1 zoom message sent` is that
            // shape exactly. The pinch is allowed to lose (a tap is a discrete
            // gesture and it won fairly), but it must not also fire a **right
            // click** the user did not ask for: they were zooming.
            if CACurrentMediaTime() - zoomLastActiveAt < Self.pinchTapGuard {
                Log.info("gesture: two-finger tap ignored — a pinch was live "
                         + String(format: "%.0f ms ago", (CACurrentMediaTime() - zoomLastActiveAt) * 1000)
                         + "; a zoom is not a right click")
                return
            }
            guard let n = normalized(recognizer.location(in: self)) else { return }
            receiver?.sendTouch(phase: "began", x: n.x, y: n.y, button: "right")
            receiver?.sendTouch(phase: "ended", x: n.x, y: n.y, button: "right")
        }

        // MARK: - Native touch mode
        //
        // One finger scrolls, tap clicks, touch-and-hold opens the context
        // menu, hold-then-move drags, pinch zooms — the iPadOS conventions, as
        // close as a remote desktop can get to them. The invariant that matters
        // most: every `began` this section sends has exactly one `ended` or
        // `cancelled`, on every exit path, including a mode switch and the view
        // leaving the window. A mouse button stuck down on the Mac is the one
        // failure this code can cause that the user cannot undo from the iPad.

        /// How long a finger must stay still to become a hold, and how far it
        /// may stray while doing so. 0.4 s is iPadOS's own context-menu delay.
        ///
        /// `holdSlop` is the long press's `allowableMovement` and governs only
        /// the window *before* the press duration elapses — UIKit stops
        /// applying it the moment the recognizer reaches `.began`. What
        /// happens *after* the commit is
        /// `HoldDragMachine.defaultCommitSlop`'s business. The two numbers
        /// agree today and are still two constants: one answers "is this a
        /// hold", the other "has the hold become a drag", and conflating them
        /// is how retuning the feel of a drag silently changes what counts as
        /// a scroll.
        static let holdDuration = HoldPriority.holdDuration
        static let holdSlop = HoldPriority.holdSlop

        /// Touch-and-hold and what it becomes. The decisions — when a hold
        /// turns into a drag, where the drag's `began` belongs, which of the
        /// three endings a release is — live in `HoldDragMachine`, which is
        /// pure and has tests. What is left here is the wire and the haptic.
        private var holdMachine = HoldDragMachine()
        /// When the hold committed, so the drag line can say how long the user
        /// actually held before moving. Diagnostics only.
        private var holdCommittedAt: CFTimeInterval?
        private var nativePanLast = CGPoint.zero
        private lazy var holdHaptics = UIImpactFeedbackGenerator(style: .medium)

        /// True when the finger sequence on the glass began by interrupting
        /// scroll momentum. That first touch only stops the coast — it must not
        /// also click or open a context menu, exactly as a tap on a decelerating
        /// `UIScrollView` stops it without activating what is under the finger.
        /// A *pan* from the same touch still scrolls normally.
        private var swallowingTouch = false

        /// One-finger (or two-finger) scroll.
        ///
        /// Cursor policy: the Mac routes a scroll to whatever sits under its
        /// cursor, so the cursor is put on the finger once, at `began`, exactly
        /// as the trackpad-style two-finger pan already does. Once only —
        /// moving it per sample would retarget the scroll mid-gesture, and a
        /// real trackpad does not drag the cursor while scrolling either.
        @objc func didNativePan(_ recognizer: UIPanGestureRecognizer) {
            trace("nativePan", recognizer)
            guard let video = receiver?.videoSize, video != .zero else { return }
            let scale = min(bounds.width / video.width, bounds.height / video.height)
            guard scale > 0 else { return }

            switch recognizer.state {
            case .began:
                stopMomentum(announce: true)
                nativePanLast = .zero
                if let n = normalized(recognizer.location(in: self)) {
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                receiver?.sendScroll(dx: 0, dy: 0, phase: "began")
            case .changed:
                let t = recognizer.translation(in: self)
                receiver?.sendScroll(dx: (t.x - nativePanLast.x) / scale,
                                     dy: (t.y - nativePanLast.y) / scale,
                                     phase: "changed")
                nativePanLast = t
            case .ended:
                receiver?.sendScroll(dx: 0, dy: 0, phase: "ended")
                nativePanLast = .zero
                startMomentum(velocity: recognizer.velocity(in: self), scale: scale)
            case .cancelled, .failed:
                // A cancelled pan still owes the Mac its `ended`, or the window
                // under the cursor keeps its scroll bars up forever.
                receiver?.sendScroll(dx: 0, dy: 0, phase: "ended")
                nativePanLast = .zero
            default:
                break
            }
        }

        /// Tap = left click where the finger landed.
        ///
        /// No click counting here: the Mac already runs the multi-click chain
        /// (interval, slop distance, per-button history) for the touch path, so
        /// a double tap arrives as two clicks and becomes a double click there,
        /// with the same timings a local mouse gets.
        @objc func didNativeTap(_ recognizer: UITapGestureRecognizer) {
            trace("nativeTap", recognizer)
            guard recognizer.state == .ended, !swallowingTouch,
                  let n = normalized(recognizer.location(in: self)) else { return }
            stopMomentum(announce: true)
            lastNorm = n
            receiver?.sendTouch(phase: "began", x: n.x, y: n.y)
            receiver?.sendTouch(phase: "ended", x: n.x, y: n.y)
        }

        /// Touch and hold — the iPadOS context-menu gesture, with its two
        /// endings.
        ///
        /// The hold itself sends **nothing**: after `holdDuration` with the
        /// finger inside `holdSlop` it only commits the haptic, which is the
        /// feedback that says "this finger is mine now". What it becomes is
        /// decided afterwards:
        ///
        /// * the finger **lifts** without leaving the slop → a **right click**
        ///   at the hold point, i.e. the context menu. Never a left press: on
        ///   iPadOS a touch-and-hold that opens a menu did not click the thing
        ///   underneath, and sending a left down/up here is what made the
        ///   previous version unable to open a Finder context menu at all.
        /// * the finger **moves** past the slop → **drag and drop**: a left
        ///   `began` at the *original* hold point (the thing being picked up is
        ///   the thing that was pressed), `moved` for every sample after, and
        ///   `ended` on release.
        ///
        /// A finger that moves *before* the threshold never gets here — it
        /// crosses `allowableMovement`, the long press fails, and the pan
        /// scrolls. That is the arbitration in one sentence: moved first =
        /// scroll, held first = menu or drag.
        @objc func didNativeLongPress(_ recognizer: UILongPressGestureRecognizer) {
            trace("nativeLongPress", recognizer)
            switch recognizer.state {
            case .began:
                let point = recognizer.location(in: self)
                guard normalized(point) != nil else { return }
                stopMomentum(announce: true)
                // Take the finger off the pan for the rest of this sequence.
                //
                // Unconditional, and it does not test the pan's state: a
                // disabled recognizer drops the touches it is tracking and only
                // picks up *new* sequences when it is re-enabled, so this is a
                // hard guarantee that the pan cannot begin from the finger the
                // hold now owns. `gestureRecognizerShouldBegin` says the same
                // thing, but it is only consulted if UIKit gets as far as
                // asking; this does not depend on that. A pan that was already
                // live is driven to `.cancelled` by the disable, which sends
                // the scroll's closing `ended`.
                nativePan?.isEnabled = false
                nativePan?.isEnabled = true
                emit(holdMachine.begin(at: point))
                holdHaptics.impactOccurred()
                Log.info("gesture: hold committed at (\(Int(point.x)),\(Int(point.y)))")
                holdCommittedAt = CACurrentMediaTime()
            case .changed:
                // UIKit stops applying `allowableMovement` once a long press
                // has begun: every sample after the commit arrives here
                // unclamped, however far the finger has travelled. That is what
                // makes hold-then-drag possible at all, and
                // `HoldDragMachineTests` pins it on our side of the boundary.
                emit(holdMachine.move(to: recognizer.location(in: self)))
            case .ended:
                emit(holdMachine.end(at: recognizer.location(in: self), cancelled: false))
            case .cancelled, .failed:
                emit(holdMachine.end(at: recognizer.location(in: self), cancelled: true))
            default:
                break
            }
        }

        /// Put a hold-machine decision on the wire. The one place a drag's
        /// `began`, `moved`, `ended`/`cancelled` and the hold's right click are
        /// sent, so "every `began` has exactly one release" is checkable by
        /// reading `HoldDragMachine` rather than by auditing call sites.
        private func emit(_ emission: HoldDragMachine.Emission) {
            switch emission {
            case .nothing:
                break
            case .dragBegan(let origin, let movedTo):
                // The press lands where the finger was *held*: on iPadOS the
                // thing you pick up is the thing you were pressing, and
                // starting the drag where the slop was crossed would grab its
                // neighbour.
                guard let from = normalized(origin) else { return }
                lastNorm = from
                receiver?.sendTouch(phase: "began", x: from.x, y: from.y)
                if let to = normalized(movedTo) {
                    lastNorm = to
                    receiver?.sendTouch(phase: "moved", x: to.x, y: to.y)
                }
                // Three distinct lines — "hold committed", "drag began",
                // "drag ended" — because the round-4 log could not distinguish
                // "the hold never committed" from "it committed and never
                // became a drag", and those are different bugs.
                let held = holdCommittedAt.map { CACurrentMediaTime() - $0 } ?? 0
                Log.info("gesture: drag began — left down at "
                         + "(\(Int(origin.x)),\(Int(origin.y))), moved to "
                         + "(\(Int(movedTo.x)),\(Int(movedTo.y))) "
                         + String(format: "%.0f ms after the hold committed", held * 1000))
            case .dragMoved(let point):
                guard let n = normalized(point) else { return }
                lastNorm = n
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            case .dragEnded(let point, let cancelled):
                // The release must go out even when the video size is unknown
                // (a rotation tearing the view down mid-drag): fall back to the
                // last position rather than leaving the button down on the Mac.
                let n = normalized(point) ?? lastNorm
                lastNorm = n
                receiver?.sendTouch(phase: cancelled ? "cancelled" : "ended", x: n.x, y: n.y)
                Log.info("gesture: drag \(cancelled ? "cancelled" : "ended") at "
                         + "(\(Int(point.x)),\(Int(point.y)))")
                holdCommittedAt = nil
            case .rightClick(let point):
                guard let n = normalized(point) else { return }
                lastNorm = n
                receiver?.sendTouch(phase: "began", x: n.x, y: n.y, button: "right")
                receiver?.sendTouch(phase: "ended", x: n.x, y: n.y, button: "right")
                Log.info("gesture: hold released in place — right click")
            }
        }

        /// Close the hold, once, whatever the reason — for the paths that are
        /// not the recognizer itself: a touch-mode switch and the view leaving
        /// the window. Safe to call when no hold is running.
        private func endNativeHold(cancelled: Bool) {
            emit(holdMachine.end(cancelled: cancelled))
        }

        /// Pinch = zoom, as the additive `zoom` message.
        ///
        /// What goes on the wire is the **incremental** factor, computed as
        /// this callback's cumulative `scale` divided by the previous one — see
        /// `PinchScale`, which is where the round-6 defect and its reasoning
        /// are written down. The short version: `recognizer.scale = 1` is the
        /// documented way to get an increment and it silently does nothing for
        /// a *trackpad* pinch, so every indirect gesture sent its running total
        /// as if it were a step and the Mac was asked for `×225395`.
        ///
        /// Incremental rather than cumulative for the Mac's sake as well: it
        /// needs no gesture state, and a dropped message costs a fraction of a
        /// zoom step instead of desyncing the level for the rest of the
        /// session.
        private var zoomsSent = 0
        private var zoomFactor = 1.0
        private var zoomClamped = 0
        private var zoomLargestStep = 1.0
        /// How many of this gesture's messages carried the centroid. Anything
        /// less than `zoomsSent + 1` means the video size was unknown for part
        /// of the pinch and the Mac fell back to its own cursor for those.
        private var zoomCentroidsSent = 0
        /// When the pinch recognizer was last live, so a two-finger tap that
        /// cancelled it cannot also become a right click. A time rather than a
        /// flag because the tap fires in the same event pass as the
        /// cancellation and the recognizer has already been reset by then.
        private var zoomLastActiveAt = -Double.greatestFiniteMagnitude
        /// How long after a live pinch a two-finger tap is refused. One frame
        /// at 120 Hz is 8 ms; 400 ms is longer than any tap that could have
        /// been part of the same sequence and far shorter than the gap between
        /// a deliberate zoom and a deliberate right click.
        private static let pinchTapGuard: CFTimeInterval = 0.4
        /// The cumulative scale this recognizer last reported. The baseline the
        /// next increment is measured against, and the only state the fix
        /// needs.
        private var zoomLastCumulative = 1.0

        /// The pinch centroid, normalized like a touch — or nil while the video
        /// size is unknown. For an indirect (trackpad) pinch UIKit reports the
        /// pointer's location here, which is the right anchor for that case.
        private func pinchCentroid(_ recognizer: UIPinchGestureRecognizer) -> (x: Double, y: Double)? {
            normalized(recognizer.location(in: self))
        }

        @objc func didNativePinch(_ recognizer: UIPinchGestureRecognizer) {
            trace("nativePinch", recognizer)
            let centroid = pinchCentroid(recognizer)
            if recognizer.state == .began || recognizer.state == .changed {
                zoomLastActiveAt = CACurrentMediaTime()
            }
            switch recognizer.state {
            case .began:
                stopMomentum(announce: true)
                zoomsSent = 0
                zoomFactor = 1
                zoomClamped = 0
                zoomLargestStep = 1
                zoomCentroidsSent = 0
                // The baseline is whatever the recognizer says *now*, not 1:
                // a pinch is recognized only once the fingers have already
                // moved, so `scale` at `.began` is typically 1.1–1.3 and
                // treating it as a step would put a visible jump at the start
                // of every gesture.
                zoomLastCumulative = Double(recognizer.scale)
                if !(zoomLastCumulative.isFinite && zoomLastCumulative > 0) {
                    zoomLastCumulative = 1
                }
                receiver?.sendZoom(scale: 1, phase: "began", x: centroid?.x, y: centroid?.y)
                if centroid != nil { zoomCentroidsSent += 1 }
                Log.info("zoom: began (\(recognizer.numberOfTouches) touch"
                         + "\(recognizer.numberOfTouches == 1 ? "" : "es")"
                         + "\(recognizer.numberOfTouches == 0 ? ", i.e. the trackpad" : "")"
                         + String(format: ", baseline scale %.4f", zoomLastCumulative)
                         + (centroid.map { String(format: ", centroid n=(%.4f,%.4f)", $0.x, $0.y) }
                            ?? ", NO centroid — the video size is not known yet, "
                               + "so the Mac will zoom at its own cursor")
                         + ")")
            case .changed:
                let cumulative = Double(recognizer.scale)
                // **Every callback, no thresholding.** The Mac injects a real
                // magnify gesture, one event per message, and what makes that
                // feel like a trackpad is the cadence: ~120 messages a second,
                // each carrying a tiny increment. Only a reading with no
                // meaning is refused.
                guard let step = PinchScale.step(cumulative: cumulative,
                                                 previous: zoomLastCumulative) else { return }
                if PinchScale.wasClamped(cumulative: cumulative, previous: zoomLastCumulative) {
                    zoomClamped += 1
                }
                zoomLastCumulative = cumulative
                receiver?.sendZoom(scale: step, phase: "changed", x: centroid?.x, y: centroid?.y)
                zoomsSent += 1
                if centroid != nil { zoomCentroidsSent += 1 }
                zoomFactor *= step
                if abs(log(step)) > abs(log(zoomLargestStep)) { zoomLargestStep = step }
            case .ended:
                receiver?.sendZoom(scale: 1, phase: "ended", x: centroid?.x, y: centroid?.y)
                logZoomEnd("ended")
            case .cancelled, .failed:
                // The Mac ends the gesture cleanly either way (it posts the
                // `ended` phase for both), but the wire keeps the distinction:
                // it is the only place a reader can see that something took the
                // fingers away mid-pinch.
                receiver?.sendZoom(scale: 1, phase: "cancelled", x: centroid?.x, y: centroid?.y)
                logZoomEnd(recognizer.state == .failed ? "failed" : "cancelled",
                           blamedOn: whatTookThePinch(recognizer))
            default:
                break
            }
        }

        /// What was running when the pinch was cancelled.
        ///
        /// Round 7's iPad log has two cancelled pinches (`1 zoom message sent`,
        /// `4 zoom messages sent`) and no way at all to tell why: a recognizer
        /// that is prevented by another one is driven to `.cancelled` with no
        /// record of which one did it, and UIKit's own `trace` line only says
        /// how many touches were left. So the answer is assembled here, from
        /// the state of everything that could have taken them, and printed on
        /// the same line as the cancellation.
        ///
        /// The candidates, and what each would mean:
        ///
        /// * **the two-finger tap** — a quick pinch whose fingers barely moved
        ///   also satisfies a two-finger tap, which is a right click. That is
        ///   the shape of a 1–4 message pinch, and it is handled: a tap that
        ///   arrives while a pinch was live no longer sends one;
        /// * **the hold** — a finger already held (its 0.4 s elapsed) owns the
        ///   sequence, and a second finger landing cannot start a pinch;
        /// * **the pan** — allowed to run *with* the pinch
        ///   (`PinchArbiter.mayRunTogether`), so it cancelling one would mean
        ///   that rule has regressed;
        /// * **nothing at all** — then it was the system: touches cancelled by
        ///   a multitasking gesture, a notification, or the app leaving the
        ///   foreground.
        private func whatTookThePinch(_ recognizer: UIPinchGestureRecognizer) -> String {
            func active(_ other: UIGestureRecognizer?) -> Bool {
                guard let other, other !== recognizer else { return false }
                return other.state == .began || other.state == .changed || other.state == .ended
            }
            var blame: [String] = []
            if active(nativeTap) { blame.append("the one-finger tap") }
            if active(twoFingerTap) { blame.append("the two-finger tap (a right click)") }
            if active(nativeLongPress) || holdMachine.isActive { blame.append("the hold") }
            if active(nativePan) { blame.append("the pan") }
            if blame.isEmpty {
                return "nothing else was recognizing — the system cancelled the touches "
                    + "(a multitasking gesture, a notification, or the app leaving the foreground)"
            }
            return "taken by " + blame.joined(separator: " + ")
        }

        /// One line per gesture, not per message: a pinch sends ~110 `zoom`
        /// messages a second and that cadence is the feature (PROTOCOL.md 6.1),
        /// so the log has to summarise rather than transcribe.
        ///
        /// `largest step` is the diagnostic that would have found the round-6
        /// bug in one line: a real pinch never reports a step above ~1.05, and
        /// every nonsense session in that log was made of steps far larger.
        private func logZoomEnd(_ how: String, blamedOn blame: String? = nil) {
            Log.info(String(format: "zoom: %@ — %d zoom message%@ sent, net ×%.3f, "
                            + "largest step ×%.4f, %d carried the centroid%@%@",
                            how, zoomsSent, zoomsSent == 1 ? "" : "s", zoomFactor,
                            zoomLargestStep, zoomCentroidsSent,
                            zoomClamped > 0 ? ", \(zoomClamped) clamped (the recognizer re-based)" : "",
                            blame.map { " — \($0)" } ?? ""))
            zoomsSent = 0
            zoomFactor = 1
            zoomClamped = 0
            zoomLargestStep = 1
            zoomLastCumulative = 1
            zoomCentroidsSent = 0
        }

        // MARK: - Scroll momentum

        // The three numbers live in `ScrollMomentum` (pure, tested): how long a
        // flick keeps moving is something the operator feels, and round 4's
        // 16 pt/s floor is what kept the brake armed for two seconds after
        // every flick.
        private static let decelerationPerMs = ScrollMomentum.decelerationPerMs
        private static let momentumStartSpeed = ScrollMomentum.startSpeed
        private static let momentumStopSpeed = ScrollMomentum.stopSpeed

        private var momentumLink: CADisplayLink?
        /// Whether a flick is still coasting. Read at touch-down: a finger that
        /// lands during the coast is a brake.
        private var momentumRunning: Bool { momentumLink != nil }
        private var momentumVelocity = CGPoint.zero
        private var momentumScale: CGFloat = 1
        private var momentumLastTime: CFTimeInterval = 0
        /// How fast the coast is going right now, in points per second. Read at
        /// touch-down: the brake only costs a click when the content is still
        /// visibly moving (`MomentumBrake.swallowsTap`).
        private var momentumSpeed: CGFloat { hypot(momentumVelocity.x, momentumVelocity.y) }

        /// Begin the coast after a flick.
        ///
        /// The momentum phases go on the wire so macOS gets *its* inertia too:
        /// AppKit and WebKit read `scrollWheelEventMomentumPhase` to decide
        /// whether a scroll is still being driven, which is what drives
        /// rubber-band release and "scroll to load more" behaviours. Emitting
        /// decayed deltas without the phases would move the content but leave
        /// every app thinking a finger was still down.
        private func startMomentum(velocity: CGPoint, scale: CGFloat) {
            guard hypot(velocity.x, velocity.y) >= Self.momentumStartSpeed, scale > 0 else { return }
            momentumVelocity = velocity
            momentumScale = scale
            momentumLastTime = CACurrentMediaTime()
            receiver?.sendScroll(dx: 0, dy: 0, phase: "momentumBegan")
            let link = CADisplayLink(target: self, selector: #selector(stepMomentum))
            // Coast at the panel's rate, not at 60: on ProMotion a scroll that
            // emits deltas half as often as the picture refreshes is visibly
            // steppier than the content it is scrolling.
            let maxHz = Float(UIScreen.main.maximumFramesPerSecond)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: maxHz,
                                                            preferred: maxHz)
            link.add(to: .main, forMode: .common)
            momentumLink = link
        }

        @objc private func stepMomentum() {
            let now = CACurrentMediaTime()
            let dt = now - momentumLastTime
            momentumLastTime = now
            // A stalled main thread (a sheet presenting, say) must not deliver
            // one enormous delta when it comes back.
            let step = min(max(dt, 0), 0.05)
            let decay = pow(Self.decelerationPerMs, step * 1000)
            let dx = momentumVelocity.x * CGFloat(step)
            let dy = momentumVelocity.y * CGFloat(step)
            momentumVelocity.x *= CGFloat(decay)
            momentumVelocity.y *= CGFloat(decay)

            if hypot(momentumVelocity.x, momentumVelocity.y) < Self.momentumStopSpeed {
                stopMomentum(announce: true)
                return
            }
            receiver?.sendScroll(dx: Double(dx / momentumScale),
                                 dy: Double(dy / momentumScale),
                                 phase: "momentumChanged")
        }

        /// End the coast. `announce` sends the closing `momentumEnded`, which
        /// every consumer of the phases needs to see exactly once; it is
        /// skipped only when there was no coast to close.
        private func stopMomentum(announce: Bool) {
            guard momentumLink != nil else { return }
            momentumLink?.invalidate()
            momentumLink = nil
            momentumVelocity = .zero
            if announce { receiver?.sendScroll(dx: 0, dy: 0, phase: "momentumEnded") }
        }

        // MARK: - Trackpad pointer

        /// Moving the trackpad pointer over the video moves the *Mac's* cursor,
        /// with no button pressed — the thing that makes the iPad feel like a
        /// monitor rather than a touchscreen. Sent as the additive `pointer`
        /// control message; the Mac injects a CGEvent `.mouseMoved`.
        @objc func didPointerHover(_ recognizer: UIHoverGestureRecognizer) {
            // A click-drag is delivered as touches, not hover, and owns the
            // position while it lasts.
            guard pointerButton == nil else { return }
            guard let n = normalized(recognizer.location(in: self)) else { return }
            switch recognizer.state {
            case .began:
                // Entering the video starts a fresh hover epoch, so the Mac
                // knows not to measure a delta against wherever the cursor was
                // before something else moved it.
                lastNorm = n
                receiver?.sendPointer(phase: "began", x: n.x, y: n.y)
            case .changed:
                lastNorm = n
                receiver?.sendPointer(phase: "move", x: n.x, y: n.y)
            case .ended, .cancelled, .failed:
                // The Mac cursor stays where the user left it, exactly as it
                // would if they lifted a finger off a trackpad; only the
                // relative-motion history is closed.
                receiver?.sendPointer(phase: "ended", x: n.x, y: n.y)
            default:
                break
            }
        }

        /// Hide the iPadOS pointer over the video — see `addInteraction` above.
        func pointerInteraction(_ interaction: UIPointerInteraction,
                                styleFor region: UIPointerRegion) -> UIPointerStyle? {
            .hidden()
        }

        // MARK: - Gesture arbitration

        /// Which Native-mode recognizer this is, if any. The trackpad-style
        /// pan, the two-finger tap, the scroll-only pan and the hover
        /// recognizers are not part of this arbitration and keep UIView's own
        /// answers.
        private func nativeKind(of recognizer: UIGestureRecognizer) -> NativeRecognizer? {
            if recognizer === nativePan { return .pan }
            if recognizer === nativeTap { return .tap }
            if recognizer === nativeLongPress { return .longPress }
            if recognizer === nativePinch { return .pinch }
            return nil
        }

        /// Two rules UIKit's own precedence cannot express.
        ///
        /// 1. While a hold owns the finger — from the haptic to the release,
        ///    whether or not it has become a drag yet — the pan must not
        ///    start. A finger that was held and then moves is dragging
        ///    something, not scrolling. (Belt and braces: the hold also
        ///    disables and re-enables the pan at `.began`, which takes the
        ///    in-flight touch away from it outright.)
        /// 2. The touch that interrupted scroll momentum is a **brake**: it may
        ///    still scroll and it may still be held, but it may not *click*.
        ///    See `MomentumBrake` — refusing the long press here as well is
        ///    what took drag away for the ~2 s a coast runs.
        ///
        /// Everything else falls out of the `require(toFail:)` edges set up in
        /// `makeUIView` plus UIKit's "one recognizer at a time" default — a pan
        /// that began first prevents the long press, which is the behaviour we
        /// want (a finger that moved was scrolling).
        /// `override` because UIView declares this too, and the recognizers
        /// installed here without a delegate reach it that way. Returning true
        /// for everything else preserves UIView's own answer.
        override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let kind = nativeKind(of: recognizer) else { return true }
            if kind == .pan, holdMachine.isActive {
                Log.info("gesture: nativePan refused — a hold owns the finger")
                return false
            }
            if kind == .pan, let pan = recognizer as? HoldTolerantPanGestureRecognizer {
                // Evidence, and now honest evidence. Round 5 printed
                // `translation(in:)` here, which is the *recognizer's* own
                // translation: UIKit re-bases it at the moment it decides to
                // recognize and again whenever the touch count changes, so it
                // read 0.0–4.5 pt every time and the log concluded the pan was
                // stealing fingers from inside the hold's slop. What it was
                // really reporting was its own baseline.
                //
                // `openedAfter` is measured by `PanSlopGate` from where the
                // finger landed, and by construction it can never be less than
                // the hold's slop — the recognizer is not told about the moves
                // below it. If this line ever prints a smaller number, the gate
                // is broken and that is worth knowing loudly.
                Log.info(String(format: "gesture: nativePan begins after %.1f pt of real "
                                + "travel (hold slop %.0f pt, %d move%@ withheld)%@",
                                pan.openedAfter, HoldPriority.holdSlop,
                                pan.withheldMoves, pan.withheldMoves == 1 ? "" : "s",
                                HoldPriority.panMayBegin(movedBy: pan.openedAfter)
                                    ? "" : " — BELOW THE SLOP, the gate did not hold"))
            }
            if !MomentumBrake.allows(kind, braking: swallowingTouch) {
                Log.info("gesture: native \(kind.rawValue) refused — this touch braked the coast")
                return false
            }
            return true
        }

        /// The pan and the long press may **never** both own one finger.
        ///
        /// UIKit's default already says no, but only implicitly, and the rule
        /// this pair needs is load-bearing enough to be written down: a hold
        /// that has committed sends `began` at the hold point and drives the
        /// drag from its own `.changed`, while a pan running off the same
        /// finger would be sending `scroll` at the same time — a left button
        /// dragging and the window under it scrolling, from one finger.
        /// Answering for every pair (rather than just this one) keeps the
        /// delegate's answer identical to the default it replaces.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let a = nativeKind(of: gestureRecognizer),
                  let b = nativeKind(of: other) else { return false }
            // The one exception, and the reason it is one: a Mac trackpad
            // reports magnification and scroll from the same two fingers, and
            // "zoom the map and move it" is one gesture there. Making the pan
            // and the pinch exclusive is what produced the round-5 log's
            // `nativePan .began touches=2` in the middle of a run of pinches —
            // whichever reached `.began` first killed the other for the rest of
            // the sequence.
            //
            // This is only safe because neither can now begin by accident:
            // `PanSlopGate` keeps the pan out of a pinch whose centroid barely
            // moves, and `PinchArbiter` fails the pan outright once the fingers
            // have decisively changed their separation.
            return PinchArbiter.mayRunTogether(a, b)
        }

        // MARK: - Gesture diagnostics
        //
        // Every state transition of the four Native-mode recognizers, into the
        // log the Connection log screen shows and the share sheet exports.
        // Runs of `.changed` are counted rather than printed: a 120 Hz pan
        // would otherwise write a thousand lines a second and push everything
        // worth reading out of the file.
        private var traceState: [ObjectIdentifier: (state: UIGestureRecognizer.State, repeats: Int)] = [:]

        private func trace(_ name: String, _ recognizer: UIGestureRecognizer) {
            let key = ObjectIdentifier(recognizer)
            let state = recognizer.state
            let previous = traceState[key]
            if let previous, previous.state == state, state == .changed {
                traceState[key] = (state, previous.repeats + 1)
                return
            }
            if let previous, previous.state == .changed, previous.repeats > 0 {
                Log.info("gesture: \(name) .changed ×\(previous.repeats + 1)")
            }
            traceState[key] = (state, 0)
            Log.info("gesture: \(name) \(Self.label(state)) touches=\(recognizer.numberOfTouches)")
        }

        private static func label(_ state: UIGestureRecognizer.State) -> String {
            switch state {
            case .possible: return ".possible"
            case .began: return ".began"
            case .changed: return ".changed"
            case .ended: return ".ended"
            case .cancelled: return ".cancelled"
            case .failed: return ".failed"
            @unknown default: return ".state\(state.rawValue)"
            }
        }

        private var lastIndirectScroll = CGPoint.zero

        /// Trackpad / wheel scrolling. Same units and sign as the finger pan
        /// (video pixels, natural-scrolling direction), so the Mac side needs
        /// no new message: iPadOS already applies the user's "natural
        /// scrolling" preference to the translation it reports.
        ///
        /// Unlike the finger pan this does not move the cursor first — the
        /// trackpad pointer already drives it continuously via hover, so the
        /// scroll lands under the cursor the user is looking at.
        @objc func didIndirectScroll(_ recognizer: UIPanGestureRecognizer) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            switch recognizer.state {
            case .began:
                lastIndirectScroll = .zero
            case .changed:
                let t = recognizer.translation(in: self)
                let scale = min(bounds.width / video.width, bounds.height / video.height)
                guard scale > 0 else { return }
                receiver?.sendScroll(dx: (t.x - lastIndirectScroll.x) / scale,
                                     dy: (t.y - lastIndirectScroll.y) / scale)
                lastIndirectScroll = t
            default:
                lastIndirectScroll = .zero
            }
        }

        // MARK: - Trackpad buttons

        /// Which button the trackpad currently holds, so a drag and the release
        /// keep the button the press started with.
        private var pointerButton: String?

        /// Trackpad clicks and drags. Sent straight through, with none of the
        /// finger path's hold-delay/second-finger arbitration: a trackpad click
        /// is unambiguous the instant it happens, and nothing is going to turn
        /// it into a scroll after the fact.
        ///
        /// A two-finger click (or Control-click, or a secondary tap-to-click)
        /// reaches UIKit as an ordinary `.indirectPointer` touch whose event
        /// carries `.secondary` in `buttonMask` — that is the right button.
        private func sendPointerTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            switch phase {
            case "began":
                let secondary = event?.buttonMask.contains(.secondary) ?? false
                let button = secondary ? "right" : "left"
                pointerButton = button
                receiver?.sendTouch(phase: "began", x: norm.x, y: norm.y, button: button)
            case "moved":
                guard let button = pointerButton else { return }
                for t in event?.samples(for: touch) ?? [touch] {
                    guard let n = normalized(t.location(in: self)) else { continue }
                    lastNorm = n
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y, button: button)
                }
            case "ended", "cancelled":
                guard let button = pointerButton else { return }
                pointerButton = nil
                receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y, button: button)
            default:
                break
            }
        }

        // A press is only a click once we know a second finger is not coming.
        // Sending `began` on contact posted a mouse-down we then had to take
        // back, and taking it back only works when UIKit happens to deliver
        // `cancelled`; when the pan recognizer misses and we get a plain
        // `ended` instead, that down/up pair *is* a click, which is why every
        // other two-finger scroll opened whatever sat under the first finger.
        // So hold the down until the gesture commits to being one.
        private var pendingDown: (x: Double, y: Double)?
        private var downSent = false
        private var holdTimer: DispatchWorkItem?

        /// Movement (in points) that turns a held press into a drag.
        private let dragSlop: CGFloat = 10
        /// A press this long with no second finger is a deliberate hold, so
        /// commit it: press-and-hold menus and drag handles need the button.
        private let holdDelay: TimeInterval = 0.12
        private var pendingDownPoint: CGPoint = .zero

        /// Emit the withheld `began`, at the point the finger first landed so a
        /// drag starts where the user touched rather than where slop was crossed.
        private func commitPendingDown() {
            guard let p = pendingDown, !downSent else { return }
            downSent = true
            holdTimer?.cancel()
            holdTimer = nil
            receiver?.sendTouch(phase: "began", x: p.x, y: p.y)
        }

        /// Drop the press without a trace. Nothing reached the Mac, so there is
        /// no button to release and no click to suppress.
        private func discardPendingDown() {
            pendingDown = nil
            downSent = false
            holdTimer?.cancel()
            holdTimer = nil
        }

        private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || (event?.allTouches?.filter { isFinger($0) }.count ?? 1) > 1 {
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                }
                discardPendingDown()
                return
            }
            guard let touch = fingers.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            switch phase {
            case "began":
                let location = touch.location(in: self)
                pendingDown = norm
                pendingDownPoint = location
                downSent = false
                let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return
            case "ended":
                // A tap: nothing was posted yet, so post the whole click now.
                if pendingDown != nil, !downSent { commitPendingDown() }
                // No down means the press was already discarded (a second
                // finger took it), so there is nothing to release.
                if downSent { receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y) }
                discardPendingDown()
                return
            case "cancelled":
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y)
                }
                discardPendingDown()
                return
            case "moved":
                if pendingDown != nil, !downSent {
                    let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                      touch.location(in: self).y - pendingDownPoint.y)
                    // Below slop the finger is still deciding: track the cursor
                    // (the Mac turns a move without a down into mouseMoved) but
                    // keep the button up so a second finger can still cancel.
                    if moved > dragSlop { commitPendingDown() }
                }
            default:
                break
            }

            if phase == "moved", let event {
                // Forward every coalesced sample so the Mac gets the full-rate
                // drag, then UIKit's predicted touch so the cursor leads toward
                // where the finger will be (~1 frame of perceived latency back;
                // corrected by the next real sample).
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            if phase == "moved", let event {
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
            let pencil = touches.filter { isPencil($0) }
            let finger = touches.filter { isFinger($0) }
            let pointer = touches.filter { isPointer($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pointer.isEmpty { sendPointerTouch(phase, pointer, event) }

            if !pencil.isEmpty {
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }
            // Palm rejection: ignore resting fingers while the pen is down.
            // Suppress began and moved, but forward ended and cancelled so isDown does not stick (#189).
            //
            // Native mode takes the fingers entirely: taps, drags and scrolls
            // are decided by the recognizers above, so the raw press-and-hold
            // machinery here would post a second, competing button. Pencil and
            // trackpad paths are untouched by the mode.
            if touchMode == .trackpad,
               !finger.isEmpty, !inputEngine.hasActivePen || ended {
                send(phase, finger, event)
            }
        }

        /// Native-mode bookkeeping at touch-*down*, before any recognizer has
        /// decided anything.
        ///
        /// Stopping the coast has to happen here — from the raw touch, not
        /// from a recognizer — or the content would keep sliding for the ~10pt
        /// a pan needs or the 0.4s a hold needs while the user's finger is
        /// already on the glass telling it to stop. That is the one thing
        /// every iPadOS scroll view does that a recognizer-only design cannot.
        ///
        /// The interrupting sequence is then marked spent (`swallowingTouch`):
        /// it may still pan and it may still be *held*, but it may not click.
        /// See `MomentumBrake` for why the hold is no longer refused — that is
        /// what made hold-to-drag impossible for the ~2 s a coast runs, which
        /// is most of the time while somebody is actually using the thing.
        ///
        /// The flag is recomputed at the start of every fresh finger sequence
        /// **and** cleared when the last finger lifts. Recomputing alone was
        /// the design, so the mark could not depend on the order UIKit delivers
        /// a recognizer's action and the view's `touchesEnded`; clearing as
        /// well means a sequence that never gets a `touchesBegan` of its own
        /// (UIKit cancels touches into a view that a recognizer has taken over)
        /// cannot inherit a stale mark either. Both are cheap; only one of them
        /// being right is not worth a swallowed tap.
        private func noteNativeTouchDown(_ touches: Set<UITouch>, _ event: UIEvent?) {
            guard touchMode == .native, touches.contains(where: { isFinger($0) }) else { return }
            // Fresh sequence = nothing else was already down. A second finger
            // joining an interrupted sequence must not clear the mark.
            let othersAlreadyDown = (event?.allTouches ?? []).contains {
                isFinger($0) && !touches.contains($0) && ($0.phase == .moved || $0.phase == .stationary)
            }
            if !othersAlreadyDown { swallowingTouch = false }
            // Only a display link that is genuinely running marks the touch:
            // `momentumRunning` IS `momentumLink != nil`, and the link is
            // created only by `startMomentum` (above the flick threshold) and
            // dropped by every exit path in `stopMomentum`.
            if momentumRunning {
                // Read the speed BEFORE stopping: `stopMomentum` zeroes the
                // velocity, and the whole decision is about how fast the
                // content was moving when the finger landed.
                let speed = momentumSpeed
                let swallows = MomentumBrake.swallowsTap(coastSpeed: speed)
                stopMomentum(announce: true)
                if swallows {
                    swallowingTouch = true
                    Log.info("gesture: touch braked the coast at \(Int(speed)) pt/s "
                             + "— this sequence will not click")
                } else {
                    Log.info("gesture: touch stopped a coast that had decayed to "
                             + "\(Int(speed)) pt/s — the tap still clicks")
                }
            }
            // The hold is 0.4s away and a prepared generator fires in a few ms
            // instead of tens, so the haptic lands *with* the commit.
            holdHaptics.prepare()
        }

        /// The last finger left the glass: the brake mark has done its job.
        /// Cheap, idempotent, and the counterpart to the recomputation above.
        private func noteNativeTouchUp(_ touches: Set<UITouch>, _ event: UIEvent?) {
            guard touchMode == .native, swallowingTouch else { return }
            let stillDown = (event?.allTouches ?? []).contains {
                isFinger($0) && $0.phase != .ended && $0.phase != .cancelled
            }
            if !stillDown { swallowingTouch = false }
        }

        /// Leaving the window ends anything that is still running. The Mac
        /// resets input on disconnect anyway, but a view torn down while a
        /// drag is held (a rotation, the metal-renderer toggle rebuilding the
        /// tree) does not involve the connection at all.
        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                endNativeHold(cancelled: true)
                stopMomentum(announce: true)
                swallowingTouch = false
            }
        }

        // MARK: - Hardware keyboard focus
        //
        // Key presses only reach `pressesBegan` on the *first responder* chain.
        // #247 grabbed first responder on the first touch, which means a
        // session driven purely from the Magic Keyboard (no touching the glass
        // at all — the normal way this fork is used) never had a keyboard.

        override var canBecomeFirstResponder: Bool { true }

        /// Claim first responder whenever the view is on screen and nothing is
        /// presented over it. The presentation check matters: the settings
        /// sheet has text fields, and stealing focus back from them would make
        /// them untypable.
        func ensureKeyboardFocus() {
            guard let window, !isFirstResponder else { return }
            guard window.rootViewController?.presentedViewController == nil else { return }
            becomeFirstResponder()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            ensureKeyboardFocus()
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            ensureKeyboardFocus()
            noteNativeTouchDown(touches, event)
            routeTouches("began", touches, event, ended: false)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("moved", touches, event, ended: false)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("ended", touches, event, ended: true)
            noteNativeTouchUp(touches, event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("cancelled", touches, event, ended: true)
            noteNativeTouchUp(touches, event)
        }

        /// Every key event this view is handed, at debug level.
        ///
        /// Exists to settle one question that cannot be settled any other way:
        /// **does a chord actually reach a third-party app on iPadOS, or does
        /// the window server eat it first?** §5's table is a list of chords
        /// this fork believes never arrive, and round 6 proved one of its
        /// entries (the bare Globe key) wrong by reading a raw key code out of
        /// a log. This is that instrument, made permanent and general: turn it
        /// on, press the chord, grep.
        ///
        /// `defaults write com.peetzweg.opensidecar.ios.alfheim logKeys -bool true`
        /// on the iPad, then restart the app. Off by default — a held key
        /// repeats, and at debug level this is one line per repeat.
        private static let logKeys = UserDefaults.standard.bool(forKey: "logKeys")

        private func traceKey(_ what: String, _ key: UIKey) {
            guard Self.logKeys else { return }
            let mods = key.modifierFlags
            var names: [String] = []
            if mods.contains(.alphaShift) { names.append("caps") }
            if mods.contains(.shift) { names.append("shift") }
            if mods.contains(.control) { names.append("ctrl") }
            if mods.contains(.alternate) { names.append("opt") }
            if mods.contains(.command) { names.append("cmd") }
            if mods.contains(.numericPad) { names.append("numpad") }
            Log.info("key \(what): HID 0x\(String(key.keyCode.rawValue, radix: 16)) "
                     + "(\(key.keyCode.rawValue)) mods=[\(names.joined(separator: "+"))] "
                     + "raw=0x\(String(mods.rawValue, radix: 16)) "
                     + "chars=\(key.characters.debugDescription) "
                     + "noMods=\(key.charactersIgnoringModifiers.debugDescription)")
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let receiver else { super.pressesBegan(presses, with: event); return }
            var handled = false
            for press in presses {
                if let key = press.key {
                    traceKey("down", key)
                    receiver.sendKey(code: Int(key.keyCode.rawValue), down: true,
                                     mod: UInt(key.modifierFlags.rawValue), char: key.characters)
                    handled = true
                }
            }
            if !handled { super.pressesBegan(presses, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let receiver else { super.pressesEnded(presses, with: event); return }
            var handled = false
            for press in presses {
                if let key = press.key {
                    traceKey("up", key)
                    receiver.sendKey(code: Int(key.keyCode.rawValue), down: false,
                                     mod: UInt(key.modifierFlags.rawValue), char: key.characters)
                    handled = true
                }
            }
            if !handled { super.pressesEnded(presses, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let receiver else { super.pressesCancelled(presses, with: event); return }
            for press in presses {
                if let key = press.key {
                    traceKey("cancelled", key)
                    receiver.sendKey(code: Int(key.keyCode.rawValue), down: false,
                                     mod: UInt(key.modifierFlags.rawValue), char: key.characters)
                }
            }
            super.pressesCancelled(presses, with: event)
        }
    }
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        // Hover tilt/azimuth on the recognizer is iOS 16.4. Pencil hover needs
        // an M2 iPad Pro or newer, which never runs anything older, so
        // skipping the recognizer below 16.4 loses nothing on those devices.
        if #available(iOS 16.4, *) {
            let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
            hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
            view.addGestureRecognizer(hover)
        }
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard #available(iOS 16.4, *) else { return }
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for c in event?.samples(for: touch) ?? [touch] {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil("move", x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}

// MARK: - On-Screen Modifier Key Sidebar (issue #7)

struct ModifierSidebarView: View {
    // #247 named this `PhoneReceiver`, a type that does not exist in this
    // tree — the receiver object is `StreamReceiver` (Shared/). As merged the
    // iOS target did not compile at all.
    //
    // The latched set lives on the receiver, not in `@State` here: it is
    // connection-scoped wire state that has to be re-asserted after every
    // `hello` and dropped when a session ends. A local copy could (and did)
    // drift — showing ⌘ lit while the Mac had cleared it on a path migration
    // the user never saw.
    @ObservedObject var receiver: StreamReceiver
    @State private var collapsed = true

    private var flags: UInt { receiver.stickyModifierFlags }

    private func toggle(_ bit: UInt) {
        receiver.sendStickyModifiers(flags ^ bit)
    }

    var body: some View {
        HStack(spacing: 0) {
            if !collapsed {
                VStack(spacing: 8) {
                    modButton(label: "⌘", bit: 1 << 20)
                    modButton(label: "⌥", bit: 1 << 19)
                    modButton(label: "⌃", bit: 1 << 18)
                    modButton(label: "⇧", bit: 1 << 17)
                }
                .padding(6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 4)
            }
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    collapsed.toggle()
                }
            } label: {
                Image(systemName: collapsed ? "command.circle.fill" : "chevron.left.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(6)
            }
        }
        .padding(.leading, 6)
    }

    private func modButton(label: String, bit: UInt) -> some View {
        let active = flags & bit != 0
        return Button {
            toggle(bit)
        } label: {
            Text(label)
                .font(.system(size: 18, weight: .bold))
                .frame(width: 38, height: 38)
                .background(active ? Color.blue : Color.white.opacity(0.15))
                .foregroundColor(.white)
                .cornerRadius(8)
        }
    }
}
