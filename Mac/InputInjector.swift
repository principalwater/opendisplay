import CoreGraphics
import AppKit
import Darwin

/// The thresholds that turn two clicks into a double click, plus the clock they
/// are measured against. Injectable so multi-click behaviour can be tested
/// deterministically instead of against wall-clock time and whatever the
/// tester's System Settings happen to say.
protocol ClickMetricsProviding {
    var doubleClickInterval: TimeInterval { get }
    var doubleClickDistance: CGFloat { get }
    /// The same threshold for a *fingertip*, which is a different instrument.
    /// Defaulted below, so a conformance (and every existing test fake) only
    /// has to override it when it wants to.
    var touchDoubleClickDistance: CGFloat { get }
    var now: CFAbsoluteTime { get }
}

/// Finger-specific click thresholds.
enum TouchClick {
    /// How far apart two finger taps may land and still extend a multi-click
    /// chain, in global desktop points.
    ///
    /// The system value is a **mouse** threshold — 4 points here, and small by
    /// design: a hand holding a mouse does not move it between the two clicks
    /// of a double click, so anything further apart is two separate clicks.
    /// A fingertip is ~40 points wide, lands somewhere inside its own contact
    /// patch, and is lifted clear of the glass between taps: 5–15 points of
    /// drift between the two taps of a perfectly deliberate double tap is
    /// normal. Measured against the mouse threshold, most double taps are two
    /// single clicks — which is exactly what the device reported.
    ///
    /// 12 points is a fingertip's worth of slop and still an order of
    /// magnitude below "anywhere on the screen". Only the touch chain uses it;
    /// the Pencil keeps the precise system value, because it has a tip and a
    /// spurious double click from a pen is worse than a missed one.
    static let doubleClickDistance: CGFloat = 12
}

extension ClickMetricsProviding {
    /// Never *tighter* than the system's own answer: a user who has widened
    /// the mouse threshold has said something, and a finger should not be
    /// held to a stricter rule than a mouse.
    var touchDoubleClickDistance: CGFloat {
        max(doubleClickDistance, TouchClick.doubleClickDistance)
    }
}

/// System double-click thresholds. Interval is public API; distance is read from
/// AppKit's `NSDoubleClickDistance()` (same value the Window Server uses).
struct SystemClickMetrics: ClickMetricsProviding {
    var doubleClickInterval: TimeInterval { NSEvent.doubleClickInterval }

    /// 4 is not a fallback in practice but the answer: `NSDoubleClickDistance`
    /// is not resolvable through `dlsym` on macOS 26 (verified on the machine
    /// this fork runs on — AppKit does not export it), so this is always 4
    /// there. Kept because it is right where the symbol does resolve, and
    /// because `touchDoubleClickDistance` is what the finger path reads.
    var doubleClickDistance: CGFloat { Self.doubleClickDistanceFn?() ?? 4 }

    var now: CFAbsoluteTime { CFAbsoluteTimeGetCurrent() }

    private typealias DoubleClickDistanceFn = @convention(c) () -> CGFloat
    private static let doubleClickDistanceFn: DoubleClickDistanceFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY),
              let sym = dlsym(handle, "NSDoubleClickDistance") else { return nil }
        return unsafeBitCast(sym, to: DoubleClickDistanceFn.self)
    }()
}

/// Where synthesised events go, and where the cursor is read from.
///
/// Injecting straight into `CGEvent.post(tap:)` is right in the app and wrong
/// in a test: the upstream InputInjector suites construct an injector on
/// `CGMainDisplayID()` and drive real clicks, drags and keystrokes, which on a
/// developer machine means clicking whatever happens to be under the cursor of
/// a live desktop. Everything that leaves the injector goes through this seam
/// instead, so tests can record events rather than fire them.
protocol InputEventSink {
    func post(_ event: CGEvent)
    /// Re-homes the hardware cursor (used before a synthetic touch click so it
    /// lands on the virtual display — upstream PR #218).
    func warpCursor(to point: CGPoint)
    /// Current hardware cursor position in global CG coordinates.
    var cursorLocation: CGPoint { get }
}

/// Production sink: the HID event tap, i.e. the bottom of the event stream,
/// which is what makes injected input indistinguishable from a real device.
struct HIDEventTapSink: InputEventSink {
    func post(_ event: CGEvent) { event.post(tap: .cghidEventTap) }
    func warpCursor(to point: CGPoint) { _ = CGWarpMouseCursorPosition(point) }
    var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }
}

/// Turns normalized touch coordinates from the phone into mouse events on a
/// target display. Touch semantics: finger down = left button down, finger
/// move = drag, finger up = button up — i.e. the phone acts as a touchscreen.
/// The `scroll.phase` values, and how each maps onto the two CGEvent fields
/// macOS reads to decide whether a scroll is a trackpad gesture.
///
/// The split matters: `scrollWheelEventScrollPhase` is "a finger is on the
/// glass", `scrollWheelEventMomentumPhase` is "the content is coasting". They
/// are never both non-zero, and an app uses the first to decide when to show
/// its scroll bars and the second to decide whether it is still being driven.
enum ScrollPhase: String, CaseIterable {
    case began
    case changed
    case ended
    case momentumBegan
    case momentumChanged
    case momentumEnded

    // kCGScrollPhase* from CGEventTypes.h. Spelled out rather than taken from
    // `CGScrollPhase.began.rawValue` so the wire-to-kernel mapping is readable
    // in one place and pinned by a test.
    var scrollPhaseValue: Int64 {
        switch self {
        case .began:   return 1     // kCGScrollPhaseBegan
        case .changed: return 2     // kCGScrollPhaseChanged
        case .ended:   return 4     // kCGScrollPhaseEnded
        // Momentum is not a scroll phase: the finger has already left.
        case .momentumBegan, .momentumChanged, .momentumEnded: return 0
        }
    }

    // kCGMomentumScrollPhase* from CGEventTypes.h.
    var momentumPhaseValue: Int64 {
        switch self {
        case .began, .changed, .ended: return 0   // kCGMomentumScrollPhaseNone
        case .momentumBegan:   return 1           // ...Begin
        case .momentumChanged: return 2           // ...Continue
        case .momentumEnded:   return 3           // ...End
        }
    }

    /// True while a finger is still down. The receiver must send exactly one
    /// `ended` per `began`, and the momentum run (if any) follows it.
    var isFingerDown: Bool {
        self == .began || self == .changed
    }
}

/// Normalized-to-desktop coordinate mapping, and the one-line description of
/// it that goes in the log.
///
/// Pure, and used by every path that turns a `[0,1]` pair into a point, so a
/// touch, a hover and a diagnostics line can never disagree about where a
/// normalized coordinate lands. The offset the operator saw ("the tap opened
/// the NEIGHBOURING tab") is a disagreement between two coordinate systems, and
/// the only way to tell *which* two from a log is to print all of them.
enum InputGeometry {

    /// `[0,1]` in video space (origin top-left) → global CoreGraphics desktop
    /// coordinates, which are also y-down.
    static func point(nx: Double, ny: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + nx * bounds.width,
                y: bounds.minY + ny * bounds.height)
    }

    /// Everything needed to diagnose an offset from one line: what came in,
    /// which display it was resolved against, where that display currently is,
    /// what came out, and whether that display is the Mac's main one.
    static func describe(_ kind: String, nx: Double, ny: Double,
                         displayID: CGDirectDisplayID, bounds: CGRect,
                         point: CGPoint, mainDisplayID: CGDirectDisplayID) -> String {
        String(format:
            "input %@: n=(%.4f,%.4f) display %u bounds=(%d,%d %dx%d) → (%d,%d) main=%u%@",
            kind, nx, ny, displayID,
            Int(bounds.origin.x), Int(bounds.origin.y),
            Int(bounds.width), Int(bounds.height),
            Int(point.x.rounded()), Int(point.y.rounded()),
            mainDisplayID,
            displayID == mainDisplayID ? "" : " (this display is NOT main)")
    }
}

/// One line per `interval`, per kind. The touch path runs at up to 120 Hz and
/// the hover path faster; an unthrottled diagnostics line would be the only
/// thing in the log.
struct InputDiagnosticsRate {
    private let interval: TimeInterval
    private var lastAt: CFAbsoluteTime?

    init(interval: TimeInterval = 2) {
        precondition(interval > 0)
        self.interval = interval
    }

    /// True the first time, then at most once per `interval`.
    mutating func allows(at now: CFAbsoluteTime) -> Bool {
        if let lastAt, now - lastAt < interval { return false }
        lastAt = now
        return true
    }
}

/// How a pinch reaches the Mac.
///
/// `defaults write com.peetzweg.opensidecar.mac.alfheim zoomMode magnify` asks
/// for the synthetic gesture instead; it is read when the injector is built, so
/// it takes effect on the next session.
///
/// **The default changed in round 8, and the reason is measured rather than
/// argued.** `MagnifySelfTest` posts the fork's own magnify packing and then
/// asks AppKit what it makes of it, and the answer is that a synthesised
/// gesture cannot carry a magnification at all:
///
/// * `+[NSEvent eventWithCGEvent:]` — the same initializer AppKit uses to build
///   the `NSEvent` an application receives — turns a `kCGEventGesture` (29)
///   into `NSEventTypeGesture` (29), **not** `NSEventTypeMagnify` (30). An
///   application's `magnify(with:)` is never called for it;
/// * a CGEvent of type 30 *is* an `NSEventTypeMagnify`, and its phase decodes
///   exactly (field 132: began→`.began`, changed→`.changed`, ended→`.ended`,
///   cancelled→`.cancelled`) — but `NSEvent.magnification` reads **0** whatever
///   is written into any of the 2000 fields the self-test scans, because for a
///   real trackpad that number comes from the IOHIDEvent the window server
///   attaches, and a posted CGEvent carries none;
/// * the `kCGEventGestureStartEndSeriesType` variant is worse than useless: the
///   self-test shows writing field 115 **overwrites the zoom delta**, so the
///   packing that adds it sends zeroes.
///
/// So the round-7 log is exactly consistent: 53 events posted, sane increments,
/// nothing zooms. Rather than ship a default that is a silent no-op, `keys` —
/// ⌘= / ⌘-, public API, works in every application with zoom menu items — is
/// the default, and `magnify` stays one `defaults write` away for the day a
/// macOS release (or a better packing) makes it real.
enum ZoomMode: String, CaseIterable {
    /// Synthesised `NSEventTypeMagnify` events — continuous, and what a
    /// trackpad pinch produces. **Private API** (see the bridging header), in
    /// the same sense and with the same risk profile as `CGVirtualDisplay`,
    /// which this app already depends on to exist at all. Not the default: see
    /// the note above, and `MagnifySelfTest`.
    case magnify
    /// ⌘= / ⌘- per accumulated threshold step. Public API, works in every app
    /// that has zoom menu items, and is visibly steppy — which is the price of
    /// being the one that actually zooms.
    case keys

    static let defaultsKey = "zoomMode"
    static let forkDefault = ZoomMode.keys

    static func resolve(_ stored: Any?) -> ZoomMode {
        guard let raw = stored as? String, let mode = ZoomMode(rawValue: raw) else {
            return forkDefault
        }
        return mode
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> ZoomMode {
        resolve(defaults.object(forKey: defaultsKey))
    }
}

/// The field packing for a synthetic magnify gesture, as pure arithmetic.
///
/// Separated from the posting so the numbers that actually matter — the event
/// type, the three private field ids, the phase bits and the conversion from
/// the wire's incremental *scale* to AppKit's incremental *magnification* — can
/// be asserted in a test instead of being discovered on a user's desktop.
enum MagnifyGesture {

    /// `IOHIDEventPhaseBits`, the values `NSEvent.phase` is built from.
    enum Phase: Int64 {
        case began = 1        // kIOHIDEventPhaseBegan
        case changed = 2      // kIOHIDEventPhaseChanged
        case ended = 4        // kIOHIDEventPhaseEnded
        case cancelled = 8    // kIOHIDEventPhaseCancelled
    }

    /// Wire `zoom.phase` → gesture phase. Unknown phases are treated as
    /// `changed`, which is what PROTOCOL.md section 6 asks of an unknown value
    /// inside a known message.
    static func phase(for wire: String) -> Phase {
        switch wire {
        case "began": return .began
        case "ended": return .ended
        case "cancelled": return .cancelled
        default: return .changed
        }
    }

    /// The largest magnification one message may carry.
    ///
    /// The wire is unauthenticated, `scale` is a peer-supplied double, and
    /// AppKit hands whatever arrives straight to the frontmost app. An iPad
    /// pinch at 120 Hz reports steps in the 0.001–0.05 range, so **0.25 is five
    /// times the top of anything a real gesture produces** and still bounds
    /// what one hostile — or one buggy — message can do.
    ///
    /// Round 6 shipped 0.5, and the round-6 logs are the argument for halving
    /// it: the iPad was sending its running total as if it were a step, every
    /// message pinned the clamp, and 24 of them in 200 ms is a 6.0 magnification
    /// delta handed to whatever was frontmost. The clamp did its job — the
    /// numbers reaching AppKit were bounded — but a bound that a *broken* sender
    /// can sit on for a whole gesture is too loose to be a safety property, and
    /// the count of clamped messages is now in the log so that a sender sitting
    /// on it says so out loud.
    static let maxMagnificationPerMessage = 0.25

    /// The wire carries an *incremental scale* (1.0 = no change, 1.02 = 2%
    /// bigger). AppKit's `NSEvent.magnification` is an *incremental delta*
    /// around zero, so the conversion is `scale - 1` — the same quantity a
    /// trackpad reports, which is why this feels like a trackpad pinch and the
    /// keystroke path does not.
    ///
    /// Returns nil for a scale that has no meaning (non-finite, zero or
    /// negative): those get nothing rather than a NaN delta that an app would
    /// have no way to recover from.
    static func magnification(fromIncrementalScale scale: Double) -> Double? {
        guard scale.isFinite, scale > 0 else { return nil }
        let delta = scale - 1
        return min(max(delta, -maxMagnificationPerMessage), maxMagnificationPerMessage)
    }

    /// Whether `scale` had to be clamped to fit. Reported per gesture: a real
    /// pinch never clamps, so a non-zero count names the sender.
    static func clamps(_ scale: Double) -> Bool {
        guard scale.isFinite, scale > 0 else { return false }
        return abs(scale - 1) > maxMagnificationPerMessage
    }
}

final class InputInjector {

    private let displayID: CGDirectDisplayID
    /// The display every normalized coordinate this injector receives is
    /// resolved against. Read by the sender so the capture-start line can
    /// assert it equals the display that is actually being captured — a
    /// mismatch is exactly the bug class "the tap landed on the neighbour".
    var targetDisplayID: CGDirectDisplayID { displayID }
    /// Diagnostics throttles, one per kind so a busy hover cannot starve the
    /// touch line (or the reverse). Guarded by `stateLock` like every other
    /// mutable field.
    private var touchDiagnostics = InputDiagnosticsRate()
    private var pointerDiagnostics = InputDiagnosticsRate()
    /// Which mouse button the phone currently holds down, if any. A bool was
    /// not enough once #216 added a right button: a right-button drag whose
    /// `moved` messages carried no `button` field was posted as a *left* drag.
    private var downButton: CGMouseButton?
    /// Where that button was last posted, so a cancellation releases it where
    /// the user left it rather than wherever the cursor has since drifted.
    private var downButtonPoint: CGPoint?
    /// True while any synthetic mouse button is held.
    var isDown: Bool { withState { downButton != nil } }
    private var penContact = false
    var penDown: Bool { withState { penContact } }
    /// Last hover position, for the relative-motion fields on `.mouseMoved`.
    private var lastPointerPoint: CGPoint?
    // A real event source (vs nil) plus non-zero clickState on down/up: menu
    // tracking treats sourceless/zero-click synthetic clicks as malformed — menus
    // open but their tracking session breaks, leaving zombie menu windows
    // composited on the display (visible in the stream, unclickable).
    private let source = CGEventSource(stateID: .hidSystemState)
    // Synthetic OpenDisplay tablet — conspicuous in logs; not Wacom (0x056A) or
    // typical small driver IDs (1, 2, …).
    private let tabletVendorID: Int64 = 0x0D15       // "ODIS"
    private let tabletProductID: Int64 = 0x0101
    private let deviceID: Int64 = 424242
    private let pointerID: Int64 = 0x0D02              // pen tip
    private let vendorPointerType: Int64 = 0x0802    // Grip Pen (what apps expect)
    private let capabilityMask: Int64 = 0x05C7       // pressure + tilt + rotation + buttons
    private var proximity = false
    var inRange: Bool { withState { proximity } }
    private var stickyModifiers: CGEventFlags = []

    // Synthetic click counting — mirror macOS double-click prefs for both finger touch and pencil.
    private struct ClickSession {
        let downLocation: CGPoint
        let clickState: Int
        /// Which button this press belongs to; a release for a different one
        /// must not consume it.
        let button: CGMouseButton
    }

    private struct CompletedClick {
        let upTime: CFAbsoluteTime
        let downLocation: CGPoint
        let clickState: Int
    }

    private var touchClickSession: ClickSession?
    /// Per button: the left and right multi-click chains are independent, as
    /// they are on a real mouse.
    private var touchLastClick: [CGMouseButton: CompletedClick] = [:]
    private var penClickSession: ClickSession?
    private var penLastClick: CompletedClick?

    /// Every non-modifier key the receiver has pressed and not yet released,
    /// with the virtual keycode actually posted for it. Independent of which
    /// key owns the auto-repeat: `reset()` has to release all of them.
    private var heldKeys: [UInt16: CGKeyCode] = [:]

    /// True between a ⌘` chord firing and the backtick key being released, so
    /// the release is swallowed instead of arriving as a key-up nobody pressed.
    /// See `KeyRemapPlan.GraveRule.commandChordIsEscape`.
    private var graveChordConsumed = false
    /// Auto-repeat ownership token — see `startRepeat`.
    private var repeatGeneration: UInt64 = 0

    /// Everything this injector emits goes through `sink`; the default is the
    /// real HID event tap, tests pass a recorder.
    private let sink: InputEventSink

    // MARK: Serialization
    //
    // `stateLock` guards **every** mutable field of this class and is held
    // across the posting of the events an entry point produces.
    //
    // Confining the injector to one serial executor is not optional here. Four
    // different contexts reach it: `handleControl` on the connection's receive
    // queue, `stop()` from the main actor, the capture/reconfigure tasks that
    // reset and replace it on a rebuild, and the auto-repeat timer on its own
    // queue. Locking only the keyboard fields (as this fork originally did)
    // left `downButton`, the Pencil contact/proximity flags, the click
    // sessions and the hover position racing — and on this machine the
    // injector's target is the Mac's *only* display, where a lost mouse-up or
    // a repeat that outlives its key-up is not a glitch but a desk that no
    // longer responds.
    //
    // Holding the lock across `sink.post` is deliberate: it makes the event
    // order a peer observes the same order the messages arrived in, which
    // matters most for down/up pairs. Posting a CGEvent is a microsecond-scale
    // syscall and nothing the sink does re-enters the injector, so the lock is
    // never held long and cannot deadlock.
    //
    // Every method that runs with the lock already held is named `locked…` and
    // must never re-acquire it.

    private let stateLock = NSLock()
    private var modifiers = ModifierKeyState()
    private let keyRepeat: KeyRepeatController
    /// Which Option key stands in for Command this session. Read from
    /// `commandKeyRemap` (with the legacy `remapRightOptionToCommand` boolean
    /// as a fallback) when the injector is built, so it is constant for the
    /// lifetime of every key down/up pair — see `CommandKeyRemap`.
    private let commandKeyRemap: CommandKeyRemap
    /// Which pinch path this session uses. Constant for the injector's life,
    /// like `commandKeyRemap`, so a gesture can never change mechanism halfway
    /// through and leave a phase open on one path and closed on the other.
    private let zoomMode: ZoomMode
    /// Which keys stand in for Escape and the input-source switch this
    /// session. Constant for the injector's life, like `commandKeyRemap`, for
    /// the same reason: a key must not go down as one thing and come up as
    /// another.
    private let keyRemapPlan: KeyRemapPlan
    /// Injected so a test can assert the switch was asked for without
    /// changing the tester's own keyboard.
    private let switchInputSource: () -> Void

    /// Double-click thresholds and clock; swapped in tests.
    private let metrics: ClickMetricsProviding

    init(displayID: CGDirectDisplayID,
         sink: InputEventSink = HIDEventTapSink(),
         commandKeyRemap: CommandKeyRemap = CommandKeyRemap.fromDefaults(),
         zoomMode: ZoomMode = ZoomMode.fromDefaults(),
         keyRemapPlan: KeyRemapPlan = KeyRemapPlan.resolveFromDefaults(),
         switchInputSource: (() -> Void)? = nil,
         keyRepeat: KeyRepeatController = KeyRepeatController(),
         metrics: ClickMetricsProviding = SystemClickMetrics()) {
        self.displayID = displayID
        self.sink = sink
        self.commandKeyRemap = commandKeyRemap
        self.zoomMode = zoomMode
        self.keyRemapPlan = keyRemapPlan
        // Not `selectNext()` directly: this closure runs on whatever queue the
        // key arrived on, and the Text Input Source list is main-queue-only.
        self.switchInputSource = switchInputSource ?? { InputSourceSwitcher.selectNextOnMain() }
        self.keyRepeat = keyRepeat
        self.metrics = metrics
        Log.info(keyRemapPlan.summary)
    }

    /// Runs `body` with the injector serialized. The single entry point to
    /// every mutable field; see the note on `stateLock`.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    /// Sets sticky modifier flags sent from the on-screen modifier sidebar
    /// (issue #7). State, not an event: the receiver sends the whole new set.
    func setStickyModifiers(_ rawFlags: UInt) {
        withState { stickyModifiers = Self.eventFlags(for: rawFlags) }
    }

    /// Injects one key transition from the iPad's hardware keyboard (issue #6).
    ///
    /// - `hidUsage`: USB HID Keyboard/Keypad usage page (0x07) code, i.e.
    ///   `UIKey.keyCode.rawValue` straight off the wire.
    /// - `rawModifiers`: `UIKeyModifierFlags` bitmask at the time of the press.
    /// - `characters`: `UIKey.characters`, used **only** when the usage has no
    ///   macOS virtual keycode. For everything else the keycode is forwarded
    ///   and the Mac's own input source decides the character, which is what
    ///   makes non-Latin layouts (the user's Russian one) work.
    ///
    /// Three things happen here that upstream #247 did not do, and each of them
    /// was a real defect:
    ///   1. modifier keys are posted as `.flagsChanged`, not `keyDown`/`keyUp`
    ///      — the Window Server does not read a modifier transition out of a
    ///      key event, so Shift-as-a-key never actually shifted anything;
    ///   2. the character string is no longer attached to mapped keys, which
    ///      overrode the Mac's input source and pinned everything to whatever
    ///      layout the iPad had selected;
    ///   3. a held key auto-repeats (see KeyRepeat.swift).
    func handleKey(hidUsage: UInt16, down: Bool, rawModifiers: UInt = 0, characters: String? = nil) {
        withState {
            lockedHandleKey(hidUsage: hidUsage, down: down,
                            rawModifiers: rawModifiers, characters: characters)
        }
    }

    private func lockedHandleKey(hidUsage: UInt16, down: Bool,
                                 rawModifiers: UInt, characters: String?) {
        let isModifier = KeyboardMap.isModifier(hidUsage)
        if isModifier { modifiers.update(hidUsage: hidUsage, down: down) }
        // Sticky sidebar flags are virtual: they belong on the key and mouse
        // events they modify, never on a *physical* modifier's own
        // `.flagsChanged`. Stamping them there would assert a modifier the
        // Window Server was never told went down, and the next real modifier
        // release would look like that virtual one going up too.
        var flags = modifiers.flags(reported: rawModifiers,
                                    includeReported: !isModifier,
                                    commandKeyRemap: commandKeyRemap,
                                    sticky: isModifier ? [] : stickyModifiers)
        // With Caps Lock remapped, the Mac's own latch is never toggled — so
        // the `.maskAlphaShift` the iPad keeps reporting (it toggled *its*
        // latch, which this app cannot stop) describes a state that does not
        // exist on this side. Carried through, every key after the first
        // remapped press would arrive capitalised on the Mac and not on the
        // iPad. Dropped here, once, for every key rather than only the
        // remapped one.
        if keyRemapPlan.claimsCapsLock { flags.subtract(.maskAlphaShift) }

        // The ⌘` chord is decided on the **down edge only**, and its release is
        // swallowed. Deciding it again on the way up would be wrong in both
        // directions: a user who presses ` and *then* Command would get a
        // stray Escape and a backtick left held down on the Mac, and a user who
        // releases Command before ` would get a backtick released that was
        // never pressed.
        if hidUsage == KeyboardMap.HID.grave,
           keyRemapPlan.graveRule == .commandChordIsEscape {
            if !down, graveChordConsumed {
                graveChordConsumed = false
                return
            }
            if !down { graveChordConsumed = false }
        }

        // The missing-keys remap, before anything else consumes the usage —
        // in particular before the Caps Lock early return below, which would
        // otherwise swallow `escapeKey capsLock` and `languageKey capsLock`
        // without a trace. See `KeyRemapPlan`.
        switch keyRemapPlan.action(for: hidUsage,
                                   shift: rawModifiers & KeyboardMap.uiShift != 0,
                                   option: rawModifiers & KeyboardMap.uiAlternate != 0,
                                   // Command *after* normalization, so a
                                   // `commandKeyRemap`ped Option counts — see
                                   // `EscapeKeySource.leftCommandGrave`.
                                   command: down && flags.contains(.maskCommand)) {
        case .escape:
            postRemappedEscape(from: hidUsage, down: down, flags: flags)
            return
        case .escapeWithoutCommand:
            // Down + up in one go, with Command removed. No auto-repeat: the
            // release is swallowed, so a repeat started here would have nothing
            // left to stop it.
            graveChordConsumed = true
            let vk = KeyboardMap.macKeyCode(for: KeyboardMap.HID.escape) ?? 0x35
            let clean = flags.subtracting(.maskCommand)
            post(virtualKey: vk, down: true, flags: clean, isModifier: false, autorepeat: false)
            post(virtualKey: vk, down: false, flags: clean, isModifier: false, autorepeat: false)
            return
        case .switchInputSource:
            // On the way down only: the key has one meaning per press, and
            // acting on both edges would switch twice.
            if down { switchInputSource() }
            return
        case .passThroughWithoutOption:
            // `⌥`` means "the key itself". Strip the Option the user held so
            // the Mac produces a plain backtick instead of whatever its layout
            // binds ⌥` to (on several layouts, a dead key).
            lockedPostGrave(down: down, flags: flags.subtracting(.maskAlternate))
            return
        case .unchanged:
            break
        }

        // Caps Lock is a latched state, not a keystroke. Injecting the key
        // would toggle the *Mac's* Caps Lock as well, double-applying it
        // against the `.maskAlphaShift` the iPad already reports; carrying the
        // flag on the following keys is both simpler and correct.
        if hidUsage == KeyboardMap.HID.capsLock { return }

        guard let vk = KeyboardMap.macKeyCode(for: hidUsage,
                                              commandKeyRemap: commandKeyRemap) else {
            if down { postUnicodeFallback(characters, flags: flags) }
            return
        }

        if isModifier {
            post(virtualKey: vk, down: down, flags: flags, isModifier: true, autorepeat: false)
            return
        }

        if down {
            heldKeys[hidUsage] = vk
            post(virtualKey: vk, down: true, flags: flags, isModifier: false, autorepeat: false)
            startRepeat(hidUsage: hidUsage, virtualKey: vk)
        } else {
            // Ownership first, post second. A timer tick that is already past
            // its cancellation and blocked on `stateLock` must not land after
            // this key-up — that leaves an unmatched down, i.e. a key the Mac
            // believes is still held. Bumping the generation here, under the
            // same lock that posts the up, is what makes the tick a no-op.
            stopRepeat(ifOwnedBy: hidUsage)
            heldKeys.removeValue(forKey: hidUsage)
            post(virtualKey: vk, down: false, flags: flags, isModifier: false, autorepeat: false)
        }
    }

    /// Escape, from a key that is not Escape.
    ///
    /// **Down and up in one go, and no auto-repeat**, for the two keys where
    /// iPadOS does not guarantee a matching release: a Caps Lock or Globe
    /// press whose up never arrives would otherwise leave Escape held and
    /// repeating on the Mac, which is a state the user cannot get out of from
    /// the iPad. The backtick is a normal key whose up does arrive, so it
    /// keeps the ordinary down/up pair and its repeat.
    ///
    /// The `.maskAlphaShift` a Caps Lock press reports is dropped: this press
    /// is an Escape, the Mac's own latch is never toggled, and carrying the
    /// flag would put everything typed afterwards into capitals on one side of
    /// the link only.
    private func postRemappedEscape(from hidUsage: UInt16, down: Bool, flags: CGEventFlags) {
        let vk = KeyboardMap.macKeyCode(for: KeyboardMap.HID.escape) ?? 0x35
        let clean = keyRemapPlan.claimsCapsLock ? flags.subtracting(.maskAlphaShift) : flags
        guard hidUsage == KeyboardMap.HID.grave else {
            guard down else { return }
            post(virtualKey: vk, down: true, flags: clean, isModifier: false, autorepeat: false)
            post(virtualKey: vk, down: false, flags: clean, isModifier: false, autorepeat: false)
            return
        }
        if down {
            heldKeys[hidUsage] = vk
            post(virtualKey: vk, down: true, flags: clean, isModifier: false, autorepeat: false)
            startRepeat(hidUsage: hidUsage, virtualKey: vk)
        } else {
            stopRepeat(ifOwnedBy: hidUsage)
            heldKeys.removeValue(forKey: hidUsage)
            post(virtualKey: vk, down: false, flags: clean, isModifier: false, autorepeat: false)
        }
    }

    /// The backtick key, posted as itself.
    private func lockedPostGrave(down: Bool, flags: CGEventFlags) {
        let vk = KeyboardMap.macKeyCode(for: KeyboardMap.HID.grave) ?? 0x32
        if down {
            heldKeys[KeyboardMap.HID.grave] = vk
            post(virtualKey: vk, down: true, flags: flags, isModifier: false, autorepeat: false)
            startRepeat(hidUsage: KeyboardMap.HID.grave, virtualKey: vk)
        } else {
            stopRepeat(ifOwnedBy: KeyboardMap.HID.grave)
            heldKeys.removeValue(forKey: KeyboardMap.HID.grave)
            post(virtualKey: vk, down: false, flags: flags, isModifier: false, autorepeat: false)
        }
    }

    // MARK: Auto-repeat ownership
    //
    // `repeatGeneration` is the token. Every change of ownership — a new key
    // taking over, the owner releasing, a reset — bumps it, and a tick only
    // posts if its captured token is still current *and* its key is still in
    // `heldKeys`. Both checks happen under `stateLock`, so a tick can never
    // interleave between a key-up's bookkeeping and the key-up event itself.

    private func startRepeat(hidUsage: UInt16, virtualKey: CGKeyCode) {
        repeatGeneration &+= 1
        let generation = repeatGeneration
        keyRepeat.keyDown(hidUsage: hidUsage) { [weak self] in
            self?.repeatTick(usage: hidUsage, virtualKey: virtualKey, generation: generation)
        }
    }

    /// Stops the repeat only if this key owns it — releasing a superseded key
    /// must not silence the key that took over.
    private func stopRepeat(ifOwnedBy hidUsage: UInt16) {
        guard keyRepeat.repeatingUsage == hidUsage else { return }
        repeatGeneration &+= 1
        keyRepeat.keyUp(hidUsage: hidUsage)
    }

    @discardableResult
    private func stopRepeat() -> UInt16? {
        repeatGeneration &+= 1
        return keyRepeat.reset()
    }

    /// One auto-repeat tick, on the scheduler's queue. Flags are recomputed
    /// rather than captured at key down: pressing Shift while a letter is held
    /// must make the repeats uppercase, exactly as on a local keyboard.
    private func repeatTick(usage: UInt16, virtualKey: CGKeyCode, generation: UInt64) {
        withState {
            guard generation == repeatGeneration, heldKeys[usage] == virtualKey else { return }
            let flags = modifiers.flags(reported: 0, includeReported: false,
                                        commandKeyRemap: commandKeyRemap,
                                        sticky: stickyModifiers)
            post(virtualKey: virtualKey, down: true, flags: flags,
                 isModifier: false, autorepeat: true)
        }
    }

    private func post(virtualKey: CGKeyCode, down: Bool, flags: CGEventFlags,
                      isModifier: Bool, autorepeat: Bool) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: virtualKey, keyDown: down) else { return }
        // A modifier transition is a `.flagsChanged` event carrying the new
        // flag set; the keycode rides along so apps can tell left from right.
        if isModifier { event.type = .flagsChanged }
        event.flags = flags
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        sink.post(event)
    }

    /// Last resort for HID usages macOS has no virtual keycode for (media and
    /// volume keys, the Application "menu" key…): type the literal characters
    /// the iPad produced, as a down/up pair on virtual key 0 with an attached
    /// unicode string — the documented CGEvent way to insert text.
    ///
    /// Skipped while Command or Control is held: those flags make apps read the
    /// *keycode* and ignore the string, so the fallback would fire a bogus ⌘A
    /// instead of doing nothing.
    private func postUnicodeFallback(_ characters: String?, flags: CGEventFlags) {
        guard let characters, !characters.isEmpty else { return }
        guard !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return }
        // A peer is not trusted to be sane about length; one keystroke cannot
        // legitimately produce more than a couple of code units.
        let utf16 = Array(characters.utf16.prefix(Self.maxFallbackUnicodeUnits))
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: 0, keyDown: isDown) else { continue }
            // Shift/Caps are already baked into the character the iPad gave us;
            // leaving them on would shift it a second time in some apps.
            event.flags = flags.subtracting([.maskShift, .maskAlphaShift])
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            sink.post(event)
        }
    }

    private static let maxFallbackUnicodeUnits = 16

    /// Releases everything the keyboard is holding: every key that got a down,
    /// then each held modifier, each `.flagsChanged` carrying the flags that
    /// remain. Without this a disconnect with ⌘ down leaves the Mac believing
    /// ⌘ is still held, and the next real keystroke is a shortcut.
    private func lockedResetKeyboard() {
        stopRepeat()
        // A chord whose release never arrived (disconnect mid-press) must not
        // swallow the next legitimate backtick.
        graveChordConsumed = false

        // Every held key, not just the repeating one. Hold A, then press B:
        // B owns the repeat, but A is still down as far as the Window Server
        // is concerned, and releasing only B left A stuck for good.
        let flagsWhileKeysHeld = modifiers.flags(reported: 0, includeReported: false,
                                                 commandKeyRemap: commandKeyRemap)
        for (_, vk) in heldKeys.sorted(by: { $0.key < $1.key }) {
            post(virtualKey: vk, down: false, flags: flagsWhileKeysHeld,
                 isModifier: false, autorepeat: false)
        }
        heldKeys.removeAll()

        let held = modifiers.held
        modifiers.clear()
        stickyModifiers = []
        var remaining = ModifierKeyState()
        for usage in held { remaining.update(hidUsage: usage, down: true) }
        for usage in held.sorted() {
            remaining.update(hidUsage: usage, down: false)
            guard let vk = KeyboardMap.macKeyCode(for: usage,
                                                  commandKeyRemap: commandKeyRemap) else { continue }
            let flags = remaining.flags(reported: 0, includeReported: false,
                                        commandKeyRemap: commandKeyRemap)
            post(virtualKey: vk, down: false, flags: flags, isModifier: true, autorepeat: false)
        }
    }


    /// `prompt: false` answers the same question without raising the system
    /// "grant Accessibility access" dialog — what a unit-test run wants.
    static func ensureAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            Log.info("Accessibility permission missing — prompt requested")
        }
        return trusted
    }

    /// Releases every input held on behalf of the receiver: mouse button,
    /// Pencil contact and proximity, keyboard keys and modifiers, and any
    /// auto-repeat. Called whenever the input epoch ends — disconnect, session
    /// stop, display rebuild — and normative per PROTOCOL.md section 6.1.
    func reset() { withState { lockedReset() } }

    private func lockedReset() {
        lockedReleaseHeldButton()
        lockedCancelPenContact()
        if proximity { lockedSetProximity(entering: false, at: currentCursor()) }
        touchClickSession = nil
        touchLastClick.removeAll()
        penClickSession = nil
        penLastClick = nil
        lastPointerPoint = nil
        zoomAccumulator = 0
        zoomKeysSent = 0
        zoomKeysNet = 1
        // A magnify gesture left open would have the frontmost app believing
        // two fingers are still on a trackpad — the zoom equivalent of a mouse
        // button stuck down, and just as un-undoable from the iPad. Ended
        // rather than cancelled, for the reason `lockedEndMagnify` gives.
        if magnifying {
            lockedEndMagnify("cancelled by a reset (disconnect, display rebuild or touch-mode switch)")
        }
        zoomAnchor = nil
        lockedResetKeyboard()
    }

    /// Releases whatever mouse button is held, as a **cancellation**: click
    /// state 0 so AppKit and WebKit do not synthesise a click out of an
    /// interrupted press, and the multi-click chain for that button is dropped
    /// so the next press cannot inherit it. Released at the last point the
    /// button was posted at, not wherever the cursor has since drifted.
    private func lockedReleaseHeldButton() {
        guard let held = downButton else { return }
        let point = downButtonPoint ?? currentCursor()
        downButton = nil
        downButtonPoint = nil
        touchClickSession = nil
        touchLastClick[held] = nil
        let up: CGEventType = held == .right ? .rightMouseUp : .leftMouseUp
        guard let ev = CGEvent(mouseEventSource: source, mouseType: up,
                               mouseCursorPosition: point, mouseButton: held) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: 0)
        sink.post(ev)
    }

    /// Ends Pencil contact as an interruption rather than a stroke: the normal
    /// `up` path runs `finishPenClickSession`, which would hand the Window
    /// Server a click state of 1 (or 2) and *complete* the click the user was
    /// halfway through when the link died.
    private func lockedCancelPenContact() {
        guard penContact else { return }
        penClickSession = nil
        penLastClick = nil
        postTabletPoint(phase: .up, x: nil, y: nil, pressure: 0,
                        tiltX: 0, tiltY: 0, rotation: 0, clickStateOverride: 0)
        penContact = false
    }

    /// x/y are normalized [0,1] in video space (origin top-left).
    func handleTouch(phase: String, x: Double, y: Double, button: String = "left") {
        withState { lockedHandleTouch(phase: phase, x: x, y: y, button: button) }
    }

    private func lockedHandleTouch(phase: String, x: Double, y: Double, button: String) {
        let bounds = CGDisplayBounds(displayID)   // global CG coords, y-down
        let point = InputGeometry.point(nx: x, ny: y, in: bounds)
        if phase == "began", touchDiagnostics.allows(at: metrics.now) {
            Log.info(InputGeometry.describe("touch began", nx: x, ny: y,
                                            displayID: displayID, bounds: bounds,
                                            point: point, mainDisplayID: CGMainDisplayID()))
        }

        let requested: CGMouseButton = (button == "right") ? .right : .left
        let btn: CGMouseButton
        let type: CGEventType
        // Click count on the release. A cancel means "a second finger joined,
        // this was a scroll, not a tap" — but there is no CGEvent for undoing a
        // press, and a plain up over the press point is indistinguishable from a
        // click, so every two-finger scroll opened whatever was under finger one.
        // Releasing with clickCount 0 keeps the button state honest while telling
        // AppKit and WebKit not to synthesize a click. Only the cancel path gets
        // 0: a zero-click *down* is what breaks menu tracking (see above).
        var clickState = 1
        switch phase {
        case "began":
            // A finger press and a trackpad press are independent UIKit touch
            // sequences and the wire has no way to say they are two different
            // pointers. The Mac has one cursor and one button state, so the
            // press already in flight is released as a cancellation before the
            // new one is accepted — otherwise its `ended` is attributed to the
            // newcomer and the original button is never released at all.
            lockedReleaseHeldButton()
            btn = requested
            type = requested == .right ? .rightMouseDown : .leftMouseDown
            downButton = requested
            downButtonPoint = point
            clickState = beginTouchClickSession(at: point, button: requested)
        // Drags and releases follow the button that is actually held, not the
        // one this message claims: the sender only tags `button` on the press.
        case "moved":
            if let held = downButton {
                btn = held
                type = held == .right ? .rightMouseDragged : .leftMouseDragged
                downButtonPoint = point
            } else {
                btn = requested
                type = .mouseMoved
            }
        case "ended":
            guard let held = downButton else { return }   // spurious up without a down
            btn = held
            type = held == .right ? .rightMouseUp : .leftMouseUp
            downButton = nil
            downButtonPoint = nil
            clickState = finishTouchClickSession(at: point, button: held)
        case "cancelled":
            guard let held = downButton else { return }
            btn = held
            type = held == .right ? .rightMouseUp : .leftMouseUp
            downButton = nil
            downButtonPoint = nil
            touchClickSession = nil
            touchLastClick[held] = nil
            clickState = 0
        default:
            return
        }
        // The touch path owns the cursor from here, so the hover history is
        // stale: the next trackpad sample must not report the jump as motion.
        lastPointerPoint = nil

        sink.warpCursor(to: point)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: btn) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        if !stickyModifiers.isEmpty { event.flags.insert(stickyModifiers) }
        sink.post(event)
    }

    /// Trackpad pointer hover: move the Mac's cursor without pressing anything.
    /// x/y are normalized [0,1] in video space, exactly like `handleTouch`.
    ///
    /// No cursor warp here, unlike the touch path (#218): a hover is a stream
    /// of up to 120 samples a second and `.mouseMoved` posted at the HID tap
    /// already re-homes the cursor, so warping each one would be redundant
    /// work in the hot path.
    func handlePointerMove(x: Double, y: Double) {
        withState { lockedHandlePointerMove(x: x, y: y) }
    }

    /// Full `pointer` message handling, including the enter/leave phases.
    ///
    /// The phases exist only so the relative-motion fields can be trusted: the
    /// pointer leaving the video and coming back somewhere else must report no
    /// delta rather than one flick-sized jump, which is what a game or a 3D
    /// viewport reading `mouseEventDeltaX/Y` would otherwise act on.
    /// Unknown phases are ignored, per PROTOCOL.md section 6.
    func handlePointer(phase: String, x: Double, y: Double) {
        withState {
            switch phase {
            case "began":
                // Fresh hover epoch: nothing before this sample is comparable.
                lastPointerPoint = nil
                lockedHandlePointerMove(x: x, y: y)
            case "move":
                lockedHandlePointerMove(x: x, y: y)
            case "ended":
                // The pointer left the video. The Mac cursor stays where the
                // user left it — only the delta history is dropped.
                lastPointerPoint = nil
            default:
                break
            }
        }
    }

    private func lockedHandlePointerMove(x: Double, y: Double) {
        // A held button or a pen on the glass owns the cursor — the touch/pen
        // paths are posting drags at their own positions, and a hover sample
        // landing between them would tear the drag.
        guard downButton == nil, !penContact else { return }
        let bounds = CGDisplayBounds(displayID)
        let point = InputGeometry.point(nx: x, ny: y, in: bounds)
        if pointerDiagnostics.allows(at: metrics.now) {
            Log.info(InputGeometry.describe("pointer move", nx: x, ny: y,
                                            displayID: displayID, bounds: bounds,
                                            point: point, mainDisplayID: CGMainDisplayID()))
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        // Relative motion for the apps that read it (games, 3D viewports)
        // rather than the absolute position. Only ever measured against the
        // *previous hover sample*: any other path that moved the cursor clears
        // `lastPointerPoint`, so a jump is reported as no delta rather than a
        // fictitious flick across the screen.
        if let previous = lastPointerPoint {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
        }
        lastPointerPoint = point
        event.setIntegerValueField(.mouseEventClickState, value: 0)
        if !stickyModifiers.isEmpty { event.flags.insert(stickyModifiers) }
        sink.post(event)
    }

    /// The encoded stream size currently being sent to the receiver, in pixels.
    /// Zero until capture starts.
    private var encodedPixelsWide = 0

    /// Told by the sender whenever capture (re)starts, including after a
    /// quality change, a rotation or a clamp to the receiver's decode ceiling.
    func setEncodedSize(pixelsWide: Int, pixelsHigh: Int) {
        withState { encodedPixelsWide = max(0, pixelsWide) }
    }

    /// dx/dy in **video pixels** (PROTOCOL.md section 7), natural-scrolling
    /// sign from the phone. Scroll events take points, so convert via the
    /// scale of the stream the receiver actually measured its deltas against.
    /// `phase` is the additive `scroll.phase` field (PROTOCOL.md 6.1). Absent
    /// — every sender before this fork, and the trackpad path inside it —
    /// posts exactly the event it always did.
    func handleScroll(dx: Double, dy: Double, phase: ScrollPhase? = nil) {
        withState { lockedHandleScroll(dx: dx, dy: dy, phase: phase) }
    }

    private func lockedHandleScroll(dx: Double, dy: Double, phase: ScrollPhase?) {
        let bounds = CGDisplayBounds(displayID)
        // Video pixels are the *encoded* pixels, not the display's native
        // grid. At 50% quality — or clamped by the receiver's decode ceiling —
        // the stream is half the native width, so converting with the native
        // scale made the same trackpad movement scroll half as far. Fall back
        // to the native scale only before capture has announced a size.
        let scale: Double
        if encodedPixelsWide > 0, bounds.width > 0 {
            scale = Double(encodedPixelsWide) / bounds.width
        } else if bounds.width > 0 {
            scale = Double(CGDisplayPixelsWide(displayID)) / bounds.width
        } else {
            scale = 2
        }
        guard scale > 0 else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32((dy / scale).rounded()),
                                  wheel2: Int32((dx / scale).rounded()),
                                  wheel3: 0) else { return }
        // Gesture phases are what make macOS treat this as a trackpad scroll
        // rather than a wheel click: rubber-banding at a document's edge, the
        // scroll-bar overlay appearing and fading, and — for the momentum
        // phases — real inertia in AppKit and WebKit. A `nil` phase leaves both
        // fields at 0, which is the "not a gesture" value and byte-for-byte
        // what this posted before the field existed.
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase,
                                       value: phase.scrollPhaseValue)
            event.setIntegerValueField(.scrollWheelEventMomentumPhase,
                                       value: phase.momentumPhaseValue)
        }
        sink.post(event)
    }

    // MARK: - Zoom (pinch)

    /// Accumulated magnification, in log2 space, not yet spent on a keystroke.
    ///
    /// log2 because zoom is multiplicative: pinching to 2x then to 0.5x must
    /// come back to where it started, and summing raw scale factors does not
    /// do that. Cleared on `began` and on `reset()`, so a gesture never
    /// inherits leftovers from the last one.
    private var zoomAccumulator = 0.0

    /// How much accumulated magnification is worth one ⌘= / ⌘- keystroke.
    /// 0.2 in log2 is ~15% — roughly one step in apps that zoom in eighths, and
    /// slow enough that a two-finger twitch does not resize a document.
    private static let zoomStepLog2 = 0.2

    /// A pinch.
    ///
    /// Two mechanisms, chosen by the `zoomMode` defaults key and fixed for the
    /// life of the injector:
    ///
    /// * **`magnify` (default)** — a real `NSEventTypeMagnify` stream, one
    ///   event per received message, phases and all. Continuous, so Safari,
    ///   Preview and Maps scale smoothly under the finger instead of jumping in
    ///   ~15% notches. There is no *public* constructor for it: AppKit builds
    ///   magnification from an IOHIDEvent the window server synthesises for
    ///   trackpad hardware, and the only injectable equivalent is a CGEvent of
    ///   type `kCGEventGesture` (29) carrying three undocumented fields. That
    ///   is the same class of dependency as `CGVirtualDisplay`, which this app
    ///   cannot exist without, and it is why the keystroke path stays.
    /// * **`keys`** (default) — the round-3 behaviour: accumulate in log2 space
    ///   and spend ⌘= / ⌘- per threshold step. Public API, universally
    ///   supported, and steppy by construction. The default since round 8
    ///   because the magnify path provably delivers no magnification — see
    ///   `ZoomMode`.
    ///
    /// `x`/`y` are the pinch centroid, normalized `[0,1]` in video space
    /// exactly like `touch` (PROTOCOL.md 6.1), and additive: a receiver that
    /// does not send them gets the old behaviour, which is "wherever the Mac's
    /// cursor happens to be". That was the round-7 defect. The events were
    /// posted at the cursor, the cursor was nowhere near the fingers, and
    /// Safari only zooms a pinch that lands over the page.
    func handleZoom(scale: Double, phase: String, x: Double? = nil, y: Double? = nil) {
        let centroid: CGPoint? = (x != nil && y != nil) ? screenPoint(nx: x!, ny: y!) : nil
        withState { lockedHandleZoom(scale: scale, phase: phase, centroid: centroid) }
    }

    private func lockedHandleZoom(scale: Double, phase: String, centroid: CGPoint?) {
        switch zoomMode {
        case .magnify:
            lockedHandleZoomByMagnifying(scale: scale, phase: phase, centroid: centroid)
        case .keys:
            lockedHandleZoomByKeystrokes(scale: scale, phase: phase, centroid: centroid)
        }
    }

    /// Where this gesture is happening, in desktop coordinates.
    ///
    /// Set once per gesture, from the first centroid the gesture carries, and
    /// the cursor is warped there once — the same rule the two-finger scroll
    /// already follows, and for the same two reasons: a real trackpad does not
    /// drag the cursor while a gesture runs, and moving it mid-gesture would
    /// retarget the gesture halfway through. Nil means "no receiver centroid",
    /// in which case the cursor is used and nothing is warped, which is
    /// correct for an *indirect* pinch (the trackpad pointer already drives
    /// the Mac cursor continuously through `pointer`).
    private var zoomAnchor: CGPoint?

    /// Adopt this gesture's anchor, warping the cursor there exactly once.
    /// Returns the point events should be posted at.
    private func lockedZoomPoint(adopting centroid: CGPoint?) -> CGPoint {
        if let centroid, zoomAnchor == nil {
            zoomAnchor = centroid
            zoomAnchorWasFromWire = true
            // The touch path's warp, reused: the Mac's cursor has to be on the
            // window the fingers are over, or the gesture is delivered to
            // whatever the cursor was left on top of.
            lastPointerPoint = nil
            sink.warpCursor(to: centroid)
        }
        if let zoomAnchor { return zoomAnchor }
        zoomAnchorWasFromWire = false
        return currentCursor()
    }

    // MARK: Zoom — the magnify path

    /// True between a magnify `began` and its `ended`/`cancelled`, so the
    /// stream this injector emits is always balanced: a `reset()` (disconnect,
    /// rebuild, mode switch) mid-pinch closes the gesture rather than leaving
    /// the frontmost app believing two fingers are still on a trackpad.
    private var magnifying = false

    /// Magnify events posted in the gesture that is currently open, and the
    /// product of their deltas.
    ///
    /// Round 5's Mac log contained no line with "zoom" or "magnify" in it for
    /// a whole evening — so "the iPad never sent one" and "the Mac posted a
    /// hundred a second and no application read them" looked identical from
    /// the outside. One line per gesture on each side settles it in one grep.
    private var magnifyEventsPosted = 0
    private var magnifyNetScale = 1.0
    /// The **additive** total this gesture handed to AppKit, i.e. the sum of
    /// the `magnification` fields. This is the number the receiving application
    /// actually accumulates, and it is the one the round-6 log did not have: a
    /// net factor of ×225395 says the arithmetic is wrong somewhere, but only
    /// the sum and the largest single delta say *where*.
    private var magnifyDeltaSum = 0.0
    private var magnifyLargestDelta = 0.0
    /// Messages whose scale had to be clamped to `maxMagnificationPerMessage`.
    /// A real pinch never clamps.
    private var magnifyClamped = 0

    private func lockedHandleZoomByMagnifying(scale: Double, phase: String,
                                              centroid: CGPoint?) {
        switch MagnifyGesture.phase(for: phase) {
        case .began:
            // A `began` while one is already open would nest; close the old one
            // first so every `began` still has exactly one end.
            if magnifying { lockedEndMagnify("a second began arrived") }
            magnifying = true
            resetMagnifyCounters()
            zoomAnchor = nil
            postMagnify(0, phase: .began, at: lockedZoomPoint(adopting: centroid))
        case .changed:
            guard let delta = MagnifyGesture.magnification(fromIncrementalScale: scale) else { return }
            // A gesture that never got its `began` (a message lost, a session
            // adopted mid-pinch) still has to make sense to the app under the
            // cursor: open one rather than emitting a stray `changed`.
            let point = lockedZoomPoint(adopting: centroid)
            if !magnifying {
                magnifying = true
                postMagnify(0, phase: .began, at: point)
            }
            // Zero deltas are still posted: PROTOCOL.md's rule for phased
            // messages, and what keeps an app's own gesture tracking alive
            // through a moment where the fingers did not move.
            postMagnify(delta, phase: .changed, at: point)
            magnifyEventsPosted += 1
            magnifyNetScale *= scale
            magnifyDeltaSum += delta
            if abs(delta) > abs(magnifyLargestDelta) { magnifyLargestDelta = delta }
            if MagnifyGesture.clamps(scale) { magnifyClamped += 1 }
        case .ended:
            guard magnifying else { return }
            lockedEndMagnify("ended")
        case .cancelled:
            guard magnifying else { return }
            // **A cancelled pinch still ends.** The iPad cancels a pinch when
            // another recognizer takes the fingers (round 7's log has two), and
            // round 7 forwarded that as `kIOHIDEventPhaseCancelled`. An
            // application that tracks a gesture series watches for `.ended`;
            // `.cancelled` is the phase it is least likely to have a branch
            // for, and the cost of it not having one is a gesture left open
            // for the rest of the session. So every ending — ended, cancelled,
            // reset, superseded — is posted as `.ended`, and only the log says
            // which it was.
            lockedEndMagnify("cancelled")
        }
    }

    /// Close the open gesture with a single `.ended`, whatever ended it.
    private func lockedEndMagnify(_ how: String) {
        magnifying = false
        postMagnify(0, phase: .ended, at: lockedZoomPoint(adopting: nil))
        zoomAnchor = nil
        logMagnifyEnd(how)
    }

    private func logMagnifyEnd(_ how: String) {
        let mean = magnifyEventsPosted > 0 ? magnifyDeltaSum / Double(magnifyEventsPosted) : 0
        // Both currencies, on one line. `net ×` is the factor the *wire*
        // asked for; `Σmagnification` is what AppKit was actually handed and
        // what the frontmost application accumulates. The two are only
        // comparable at all because a small delta d is a factor of (1+d), so a
        // healthy gesture has `net ×` ≈ e^Σ — and a gesture where they disagree
        // by orders of magnitude is the round-6 defect, visible in one line.
        //
        // `posted at` is the round-8 addition and it is the one the round-7 log
        // needed: "posted at the cursor" was *true* and was the defect. A line
        // that says `at the cursor (no centroid on the wire)` now names it.
        Log.info(String(format: "magnify: %@ — %d NSEventTypeMagnify event%@ posted %@, "
                        + "net ×%.3f, Σmagnification %+.3f "
                        + "(mean %+.4f/event, largest %+.4f)%@",
                        how, magnifyEventsPosted,
                        magnifyEventsPosted == 1 ? "" : "s", magnifyWhere,
                        magnifyNetScale,
                        magnifyDeltaSum, mean, magnifyLargestDelta,
                        magnifyClamped > 0
                            ? ", \(magnifyClamped) CLAMPED at ±\(MagnifyGesture.maxMagnificationPerMessage)"
                              + " — the sender is emitting cumulative scales, not increments"
                            : ""))
        resetMagnifyCounters()
    }

    /// Where this gesture's events went, for the summary line.
    private var magnifyWhere: String {
        guard let point = magnifyLastPoint else { return "at the cursor" }
        return String(format: "at (%d,%d)%@", Int(point.x), Int(point.y),
                      zoomAnchorWasFromWire ? " — the pinch centroid" : " — the cursor (no centroid on the wire)")
    }

    private func resetMagnifyCounters() {
        magnifyEventsPosted = 0
        magnifyNetScale = 1
        magnifyDeltaSum = 0
        magnifyLargestDelta = 0
        magnifyClamped = 0
    }

    /// The last point a gesture event was posted at, and whether the receiver
    /// chose it. Diagnostics only.
    private var magnifyLastPoint: CGPoint?
    private var zoomAnchorWasFromWire = false

    /// Build and post one `kCGEventGesture`.
    ///
    /// Posted **at the gesture's anchor**: gesture events have a location like
    /// any other CGEvent, and AppKit routes a magnify to the window under it.
    /// Round 7 posted at whatever the Mac's cursor happened to be doing, which
    /// is not where the user's fingers are — see `lockedZoomPoint`.
    private func postMagnify(_ magnification: Double, phase: MagnifyGesture.Phase,
                             at point: CGPoint) {
        guard let event = ODCreateGestureEvent(source) else { return }
        ODSetEventIntegerField(event, ODEventFieldGestureType, ODGestureTypeZoom)
        ODSetEventDoubleField(event, ODEventFieldGestureZoomDelta, magnification)
        ODSetEventIntegerField(event, ODEventFieldGesturePhase, phase.rawValue)
        event.location = point
        magnifyLastPoint = point
        if !stickyModifiers.isEmpty { event.flags.insert(stickyModifiers) }
        sink.post(event)
    }

    // MARK: Zoom — the keystroke path (the default)

    /// ⌘= / ⌘- keystrokes this gesture has spent, for the one-line summary —
    /// the keystroke path was the only input path with no per-gesture line, so
    /// a session in the default mode said nothing at all about its pinches.
    private var zoomKeysSent = 0
    private var zoomKeysNet = 1.0

    private func lockedHandleZoomByKeystrokes(scale: Double, phase: String,
                                              centroid: CGPoint?) {
        switch phase {
        case "began":
            zoomAccumulator = 0
            zoomKeysSent = 0
            zoomKeysNet = 1
            zoomAnchor = nil
            // The cursor still matters here, even though a keystroke goes to
            // the focused window rather than to a point: an application that
            // zooms **towards the pointer** (every drawing and map application
            // does) needs the pointer to be where the fingers are, and the
            // window the user pinched has to be the focused one in the first
            // place.
            _ = lockedZoomPoint(adopting: centroid)
            return
        case "ended", "cancelled":
            zoomAccumulator = 0
            zoomAnchor = nil
            if zoomKeysSent > 0 || zoomKeysNet != 1 {
                Log.info(String(format: "zoom keys: %@ — %d ⌘=/⌘- keystroke%@ sent for a "
                                + "net ×%.3f pinch%@",
                                phase, zoomKeysSent, zoomKeysSent == 1 ? "" : "s",
                                zoomKeysNet,
                                magnifyLastPoint.map {
                                    String(format: " at (%d,%d)", Int($0.x), Int($0.y))
                                } ?? ""))
            }
            zoomKeysSent = 0
            zoomKeysNet = 1
            return
        default:
            break
        }
        // A non-finite or non-positive scale has no logarithm; a peer sending
        // one gets nothing rather than a NaN accumulator that never recovers.
        guard scale.isFinite, scale > 0 else { return }
        // A gesture whose `began` was lost still has to land somewhere sane.
        let point = lockedZoomPoint(adopting: centroid)
        magnifyLastPoint = point
        zoomAccumulator += log2(scale)
        zoomKeysNet *= scale

        // Bound the work one message can cause. Without this a single
        // `{"scale": 1e300}` would ask for a thousand keystrokes.
        var steps = 0
        while abs(zoomAccumulator) >= Self.zoomStepLog2, steps < 8 {
            let zoomIn = zoomAccumulator > 0
            zoomAccumulator -= zoomIn ? Self.zoomStepLog2 : -Self.zoomStepLog2
            postZoomKey(zoomIn: zoomIn)
            zoomKeysSent += 1
            steps += 1
        }
        if steps == 8 { zoomAccumulator = 0 }
    }

    /// ⌘= (zoom in) or ⌘- (zoom out). Deliberately only Command — the user's
    /// own held modifiers are not mixed in, or a pinch while Shift is down
    /// would become ⌘⇧= and mean something else.
    private func postZoomKey(zoomIn: Bool) {
        let key: CGKeyCode = zoomIn ? 0x18 : 0x1B   // kVK_ANSI_Equal / kVK_ANSI_Minus
        post(virtualKey: key, down: true, flags: .maskCommand,
             isModifier: false, autorepeat: false)
        post(virtualKey: key, down: false, flags: .maskCommand,
             isModifier: false, autorepeat: false)
    }

    func handleProximity(entering: Bool, x: Double, y: Double) {
        withState { lockedSetProximity(entering: entering, at: screenPoint(nx: x, ny: y)) }
    }

    func handlePencil(phase: String, x: Double, y: Double,
                      pressure: Double, azimuth: Double, altitude: Double,
                      rotation: Double) {
        withState {
            lockedHandlePencil(phase: phase, x: x, y: y, pressure: pressure,
                               azimuth: azimuth, altitude: altitude, rotation: rotation)
        }
    }

    private func lockedHandlePencil(phase: String, x: Double, y: Double,
                                    pressure: Double, azimuth: Double, altitude: Double,
                                    rotation: Double) {
        // TODO: Wire Apple Pencil Pro barrel roll (UIKit rollAngle) once hardware
        // is available for testing. rotation on the wire is always 0 for now.
        _ = rotation
        let p = screenPoint(nx: x, ny: y)
        if phase == "down", !proximity {
            lockedSetProximity(entering: true, at: p)
        }
        let (tiltX, tiltY) = Self.deriveTilt(azimuth: azimuth, altitude: altitude)
        // The pen owns the cursor now; see the same line in the touch path.
        lastPointerPoint = nil

        switch phase {
        case "down":
            postTabletPoint(phase: .down, x: x, y: y, pressure: pressure,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
            penContact = true
        case "move":
            if penContact {
                postTabletPoint(phase: .drag, x: x, y: y, pressure: pressure,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            } else {
                postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
            }
        case "up":
            if penContact {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penContact = false
            }
        case "hover":
            if penContact {
                postTabletPoint(phase: .up, x: x, y: y, pressure: 0,
                                tiltX: tiltX, tiltY: tiltY, rotation: 0)
                penContact = false
            }
            postTabletPoint(phase: .hover, x: x, y: y, pressure: 0,
                            tiltX: tiltX, tiltY: tiltY, rotation: 0)
        default:
            return
        }
    }


    private func lockedSetProximity(entering: Bool, at p: CGPoint) {
        guard entering != proximity else { return }
        proximity = entering
        postProximityEvent(entering: entering, at: p)
    }

    private func postProximityEvent(entering: Bool, at p: CGPoint) {
        guard let ev = CGEvent(source: source) else { return }
        ev.type = .tabletProximity
        ev.location = p
        ev.setIntegerValueField(.tabletProximityEventVendorID, value: tabletVendorID)
        ev.setIntegerValueField(.tabletProximityEventTabletID, value: tabletProductID)
        ev.setIntegerValueField(.tabletProximityEventPointerID, value: pointerID)
        ev.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        ev.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 0)
        ev.setIntegerValueField(.tabletProximityEventPointerType, value: entering ? 1 : 0)
        ev.setIntegerValueField(.tabletProximityEventVendorPointerType, value: vendorPointerType)
        ev.setIntegerValueField(.tabletProximityEventCapabilityMask, value: capabilityMask)
        ev.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        ev.flags = .maskNonCoalesced
        sink.post(ev)
    }

    private enum PointPhase { case down, drag, up, hover }

    /// `clickStateOverride` is the cancellation path: a value of 0 releases the
    /// contact without letting `finishPenClickSession` turn it into a click.
    private func postTabletPoint(phase: PointPhase, x: Double?, y: Double?,
                                 pressure: Double, tiltX: Double, tiltY: Double,
                                 rotation: Double, clickStateOverride: Int? = nil) {
        let p: CGPoint
        if let nx = x, let ny = y { p = screenPoint(nx: nx, ny: ny) }
        else { p = currentCursor() }

        let type: CGEventType
        switch phase {
        case .down:  type = .leftMouseDown
        case .drag:  type = .leftMouseDragged
        case .up:    type = .leftMouseUp
        case .hover: type = .mouseMoved
        }

        guard let ev = CGEvent(mouseEventSource: source, mouseType: type,
                               mouseCursorPosition: p, mouseButton: .left) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: 0)
        ev.setIntegerValueField(.mouseEventDeltaY, value: 0)
        ev.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        ev.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        ev.setDoubleValueField(.mouseEventPressure, value: pressure)
        ev.setIntegerValueField(.tabletEventPointPressure, value: Int64((pressure * 65535.0).rounded()))
        ev.setDoubleValueField(.tabletEventTiltX, value: tiltX)
        ev.setDoubleValueField(.tabletEventTiltY, value: tiltY)
        ev.setDoubleValueField(.tabletEventRotation, value: rotation)
        if let clickStateOverride {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickStateOverride))
        } else {
            switch phase {
            case .down:
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(beginPenClickSession(at: p)))
            case .up:
                ev.setIntegerValueField(.mouseEventClickState, value: Int64(finishPenClickSession(at: p)))
            case .drag, .hover:
                break
            }
        }
        ev.flags = .maskNonCoalesced
        sink.post(ev)
    }

    private func clickStateForMouseDown(at point: CGPoint, lastClick: CompletedClick?,
                                        within slop: CGFloat) -> Int {
        let now = metrics.now
        guard let last = lastClick,
              now - last.upTime <= metrics.doubleClickInterval else {
            return 1
        }
        let dx = point.x - last.downLocation.x
        let dy = point.y - last.downLocation.y
        guard hypot(dx, dy) <= slop else { return 1 }
        return last.clickState + 1
    }

    /// Multi-click history is **per button**: a right click followed quickly by
    /// a left click at the same spot is two single clicks, not a double click.
    private func beginTouchClickSession(at point: CGPoint, button: CGMouseButton) -> Int {
        let state = clickStateForMouseDown(at: point, lastClick: touchLastClick[button],
                                           within: metrics.touchDoubleClickDistance)
        touchClickSession = ClickSession(downLocation: point, clickState: state, button: button)
        return state
    }

    private func finishTouchClickSession(at upLocation: CGPoint, button: CGMouseButton) -> Int {
        guard let session = touchClickSession, session.button == button else {
            touchClickSession = nil
            return 1
        }
        touchClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= metrics.touchDoubleClickDistance {
            touchLastClick[button] = CompletedClick(
                upTime: metrics.now,
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            touchLastClick[button] = nil
        }
        return session.clickState
    }

    private func beginPenClickSession(at point: CGPoint) -> Int {
        let state = clickStateForMouseDown(at: point, lastClick: penLastClick,
                                           within: metrics.doubleClickDistance)
        penClickSession = ClickSession(downLocation: point, clickState: state, button: .left)
        return state
    }

    /// Returns click state for the matching pen mouse-up. Extends the multi-click
    /// chain only when down→up displacement is within the system threshold.
    private func finishPenClickSession(at upLocation: CGPoint) -> Int {
        guard let session = penClickSession else { return 1 }
        penClickSession = nil

        let dx = upLocation.x - session.downLocation.x
        let dy = upLocation.y - session.downLocation.y
        if hypot(dx, dy) <= metrics.doubleClickDistance {
            penLastClick = CompletedClick(
                upTime: metrics.now,
                downLocation: session.downLocation,
                clickState: session.clickState
            )
        } else {
            penLastClick = nil
        }
        return session.clickState
    }


    /// UIKit altitude is radians from the surface (pi/2 = upright); CGEvent tilt
    /// is a unit vector in -1...1, so normalize rather than pass radians through
    /// (unnormalized, a flat pen reads 1.57 and apps that scale tilt by 90 report
    /// impossible angles).
    static func deriveTilt(azimuth: Double, altitude: Double) -> (Double, Double) {
        let mag = min(max(0, Double.pi / 2 - altitude) / (Double.pi / 2), 1)
        return (sin(azimuth) * mag, cos(azimuth) * mag)
    }

    /// Same math, argument-labelled the other way round and with a named
    /// tuple. Two upstream PRs (#216, #247) each promoted `deriveTilt` to a
    /// testable static under a different name; keeping both spellings lets
    /// both PRs' test suites survive the merge unchanged.
    static func tiltVector(altitude: Double, azimuth: Double) -> (x: Double, y: Double) {
        let (x, y) = deriveTilt(azimuth: azimuth, altitude: altitude)
        return (x, y)
    }

    // The keyboard tables moved to KeyboardMap.swift when the fork completed
    // them (full Magic Keyboard coverage, left/right modifiers, the
    // right-Option remap). These two forwarders are the API #247's tests call;
    // keeping them means one table, not two that drift apart.

    /// `UIKeyModifierFlags` bitmask -> `CGEventFlags`.
    static func eventFlags(for rawModifiers: UInt, sticky: CGEventFlags = []) -> CGEventFlags {
        KeyboardMap.eventFlags(for: rawModifiers, sticky: sticky)
    }

    /// USB HID usage page 0x07 code -> macOS virtual keycode, with no remap
    /// applied (right Option stays right Option).
    static func macKeyCode(for hidUsage: UInt16) -> CGKeyCode? {
        KeyboardMap.macKeyCode(for: hidUsage)
    }

    private func screenPoint(nx: Double, ny: Double) -> CGPoint {
        InputGeometry.point(nx: nx, ny: ny, in: CGDisplayBounds(displayID))
    }

    private func currentCursor() -> CGPoint {
        sink.cursorLocation
    }
}
