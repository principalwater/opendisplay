import Foundation

// MARK: - Keys this keyboard does not have
//
// The operator's keyboard is a Magic Keyboard for iPad Pro 11" (1st
// generation). It has **no function row and no Escape key**, and the two
// candidates for standing in for Escape are both keys iPadOS has its own
// plans for. What follows is the whole of what is actually true about them,
// because three rounds of this report have guessed:
//
// * **Globe (🌐)** — delivered to `pressesBegan` as `UIKey.keyCode.rawValue`
//   669. See `KeyboardMap.HID.globe` for why that number is not a HID
//   keyboard-page usage and why it has no `UIKeyboardHIDUsage` case. §5 of
//   this report said the Globe key "is not delivered to apps at all"; that
//   was wrong, and this file is the correction.
// * **Caps Lock** — delivered as an ordinary press of HID 0x39. A *tap* is
//   ours; a *hold* is eaten by iPadOS's input-source HUD and never arrives.
// * **`** — delivered as HID 0x35 and already works as a backtick. ⌘` is
//   eaten by iPadOS (window cycling) and never arrives, which is unchanged.
//
// What is *not* available, checked against the iOS 26.5 SDK headers rather
// than from memory: there is no Globe entry in `UIKeyboardHIDUsage`, no Globe
// bit in `UIKeyModifierFlags` (which still has exactly the six cases it had in
// iOS 7), no Globe constant in `GCKeyCode`, and no Info.plist key that makes
// the Globe key ours. `UIKeyCommand.wantsPriorityOverSystemBehavior` (iOS 15)
// is scoped by its own documentation to "focus or text-editing system
// commands" and does not reclaim window-server chords.
//
// **Everything here is Mac-side.** The iPad already sends raw HID usages and
// knows nothing about remapping (`PROTOCOL.md` 6.2), so none of this touches
// the wire, the receiver, or the protocol version.

/// Which key on the device's keyboard produces **Escape**.
enum EscapeKeySource: String, CaseIterable, Sendable {

    /// Upstream behaviour: nothing is remapped, and a keyboard with no Escape
    /// key has no Escape.
    case none

    /// The Globe key. The fork default, because it is the only candidate that
    /// costs no existing character and no existing latch.
    case globe

    /// Caps Lock. A tap arrives as HID 0x39, which the Mac currently throws
    /// away outright, so this costs nothing that was working.
    case capsLock

    /// The backtick key, with its two characters kept reachable — see
    /// `GraveAction`.
    case grave

    /// **⌘` — the fork default from round 7.**
    ///
    /// A *chord*, not a key, and that is the whole point: the backtick keeps
    /// both of its characters unconditionally (a plain `` ` `` types a
    /// backtick, ⇧`` ` `` types a tilde) and Escape costs nothing that was
    /// working. `escapeKey grave` had to take the key away to get Escape;
    /// this does not.
    ///
    /// **Which Command.** The operator asked for left Command, and left
    /// Command is what fires it — but so does anything else this Mac is
    /// currently treating as Command, which is deliberate and is the answer to
    /// the risk this feature carries. iPadOS reserves ⌘` for "cycle the app's
    /// windows" (§5), so the physical left Command key may never deliver the
    /// chord at all. The fork already has a workaround for exactly that class
    /// of loss and the operator already uses it: `commandKeyRemap` makes an
    /// **Option** key arrive as Command, and iPadOS reserves neither Option
    /// key. So ⌥` — with `commandKeyRemap` at its `leftOption` setting — is
    /// the same chord by a route the window server does not intercept, and it
    /// needs no second setting and no rebuild.
    ///
    /// The test is therefore "does this event carry Command by the time we
    /// have finished normalizing it", which is one condition covering the real
    /// Command keys, the remapped Option keys, and the on-screen ⌘ of the
    /// modifier sidebar.
    case leftCommandGrave

    /// Control+` sends Escape while Command+` remains available to macOS.
    case controlGrave

    static let defaultsKey = "escapeKey"
    static let fallback: EscapeKeySource = .leftCommandGrave

    /// The HID usage this option claims, if any.
    var hidUsage: UInt16? {
        switch self {
        case .none:     return nil
        case .globe:    return KeyboardMap.HID.globe
        case .capsLock: return KeyboardMap.HID.capsLock
        case .grave, .leftCommandGrave, .controlGrave: return KeyboardMap.HID.grave
        }
    }

    /// What this option does to the backtick key.
    var graveRule: KeyRemapPlan.GraveRule {
        switch self {
        case .none, .globe, .capsLock: return .none
        case .grave:                   return .plainIsEscape
        case .leftCommandGrave:        return .commandChordIsEscape
        case .controlGrave:            return .controlChordIsEscape
        }
    }

    var label: String {
        switch self {
        case .none:             return "None"
        case .globe:            return "Globe (🌐)"
        case .capsLock:         return "Caps Lock"
        case .grave:            return "Backtick (`)"
        case .leftCommandGrave: return "Command + ` "
        case .controlGrave:     return "Control + ` "
        }
    }

    var hint: String {
        switch self {
        case .none:
            return "No key sends Escape. Applies to the next session."
        case .globe:
            return "The Globe key sends Escape. It is the iPad's language-switch key, so \"Globe key\" below has nothing left to do while this is selected. Applies to the next session."
        case .capsLock:
            return "A tap of Caps Lock sends Escape, and never toggles this Mac's own Caps Lock. Holding it still opens the iPad's own keyboard HUD, which this app cannot see. Applies to the next session."
        case .grave:
            return "` sends Escape; Shift+` still types ~ and Option+` still types a literal `. Applies to the next session."
        case .leftCommandGrave:
            return "Command+` sends Escape and never reaches this Mac as ⌘` (no window cycling). A plain ` still types a backtick and Shift+` a tilde. iPadOS may reserve ⌘` for itself — if the chord does nothing, press the Option key that \"Command key\" above turns into Command instead; iPadOS reserves neither Option key. Applies to the next session."
        case .controlGrave:
            return "Control+` sends Escape and does not reach this Mac as Control+`. Command+` remains available for switching Mac windows; plain ` and Shift+` keep their characters. Applies to the next session."
        }
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> EscapeKeySource {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ raw: String?) -> EscapeKeySource {
        raw.flatMap(EscapeKeySource.init(rawValue:)) ?? fallback
    }
}

/// What the Globe key does when Escape is not using it.
enum GlobeKeyAction: String, CaseIterable, Sendable {

    /// Cycle the **Mac's** keyboard input source.
    ///
    /// The iPad's own language switch is meaningless in this fork: every key
    /// travels as a HID usage and the *Mac's* input source decides which
    /// character it becomes (§4). So a Globe key that switched the iPad's
    /// layout would change nothing the user can see, and the thing the key
    /// visibly means — "switch language" — has to be performed at the other
    /// end.
    case switchLanguage

    /// Escape, for someone who wants Escape on Globe and something else on
    /// Caps Lock.
    case escape

    /// Nothing. The pre-round-6 behaviour: the usage has no macOS keycode, so
    /// it falls through to the unicode fallback with no characters and is
    /// dropped.
    case none

    static let defaultsKey = "globeKey"
    static let fallback: GlobeKeyAction = .switchLanguage

    var label: String {
        switch self {
        case .switchLanguage: return "Switch the Mac's input source"
        case .escape:         return "Escape"
        case .none:           return "Nothing"
        }
    }

    var hint: String {
        switch self {
        case .switchLanguage:
            return "Cycles this Mac's enabled keyboard input sources, in the order System Settings lists them. Not the iPad's — the character a key produces is decided here."
        case .escape:
            return "The Globe key sends Escape."
        case .none:
            return "The Globe key is ignored."
        }
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> GlobeKeyAction {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ raw: String?) -> GlobeKeyAction {
        raw.flatMap(GlobeKeyAction.init(rawValue:)) ?? fallback
    }
}

/// Which key switches the Mac's input source, for when Globe is spoken for.
///
/// Exists because the two defaults collide by design: `escapeKey` defaults to
/// Globe and `globeKey` defaults to switching the language, and they name the
/// same physical key. Rather than pick a winner silently, the fork offers the
/// language switch on the other key iPadOS will actually deliver — which is
/// also what a great many Mac users configure natively.
enum LanguageKeySource: String, CaseIterable, Sendable {

    case none

    /// A tap of Caps Lock cycles the Mac's input source.
    case capsLock

    static let defaultsKey = "languageKey"
    static let fallback: LanguageKeySource = .none

    var hidUsage: UInt16? {
        switch self {
        case .none:     return nil
        case .capsLock: return KeyboardMap.HID.capsLock
        }
    }

    var label: String {
        switch self {
        case .none:     return "None"
        case .capsLock: return "Caps Lock"
        }
    }

    var hint: String {
        switch self {
        case .none:
            return "No key switches the input source. Applies to the next session."
        case .capsLock:
            return "A tap of Caps Lock cycles this Mac's enabled input sources, and never toggles this Mac's Caps Lock. Applies to the next session."
        }
    }

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> LanguageKeySource {
        resolve(defaults.string(forKey: defaultsKey))
    }

    static func resolve(_ raw: String?) -> LanguageKeySource {
        raw.flatMap(LanguageKeySource.init(rawValue:)) ?? fallback
    }
}

/// What the backtick key does when `escapeKey` is `grave`.
///
/// A terminal needs both characters the key carries, so taking it for Escape
/// has to leave a way back to each of them.
///
/// **Option, not a double tap.** A double-tap window (300 ms was proposed)
/// would delay *every* backtick by that window before it could be typed, which
/// in a shell — where the character is half of a command substitution and is
/// typed in pairs — is worse than not having the key at all. Option is
/// instantaneous, unambiguous, and already means "the key itself, not what it
/// has been remapped to" on macOS.
enum GraveAction: Equatable {
    /// Plain press: Escape.
    case escape
    /// The key itself, with the modifiers the user actually held. Shift gives
    /// `~`; Option is consumed by this rule and stripped, so ⌥` gives a plain
    /// backtick rather than whatever the layout binds ⌥` to.
    case backtick(stripOption: Bool)

    static func resolve(shift: Bool, option: Bool) -> GraveAction {
        if option { return .backtick(stripOption: true) }
        if shift { return .backtick(stripOption: false) }
        return .escape
    }
}

/// The three settings, resolved into "which usage does what", once.
///
/// Pure, because the interesting part is the **collision**: `escapeKey` and
/// `globeKey` can both name the Globe key, and `escapeKey` and `languageKey`
/// can both name Caps Lock. A rule nobody wrote down would be discovered by a
/// user whose Escape key silently stopped working.
///
/// **`escapeKey` wins.** It is the more specific statement ("this key is my
/// Escape"), it is the one the keyboard is missing, and a Mac with no Escape
/// is less usable than a Mac whose language switch is on a different key.
/// Whatever loses is reported once, at session start, with the way out.
struct KeyRemapPlan: Equatable {

    /// What the backtick key does under this plan.
    enum GraveRule: Equatable {
        /// Not claimed: `` ` `` is a backtick and nothing else.
        case none
        /// `escapeKey grave` — a bare `` ` `` is Escape, and the two characters
        /// are reached with Shift and Option (`GraveAction`).
        case plainIsEscape
        /// `escapeKey leftCommandGrave` — ⌘` is Escape and never reaches the
        /// Mac as ⌘`; a bare `` ` `` and ⇧`` ` `` are completely untouched.
        case commandChordIsEscape
        /// `escapeKey controlGrave` leaves Command+` available to applications.
        case controlChordIsEscape
    }

    /// The usage that produces Escape, if any.
    let escapeFrom: UInt16?
    /// The usage that cycles the Mac's input source, if any.
    let switchInputSourceFrom: UInt16?
    /// Set when a setting was overruled, for the log line. Nil when the three
    /// settings name three different keys (or fewer).
    let conflictNote: String?

    /// What one key does under this plan.
    enum Action: Equatable {
        /// Post Escape.
        case escape
        /// Post Escape with the Command flag removed, and swallow the key's
        /// release. The `⌘`` chord: the Mac must see an Escape, and must never
        /// see ⌘` (which cycles an application's windows).
        case escapeWithoutCommand
        /// Post Escape without Control, swallowing the grave key's release.
        case escapeWithoutControl
        /// Cycle the Mac's input source; post no key.
        case switchInputSource
        /// The key itself, with the Option flag removed (the `⌥`` rule).
        case passThroughWithoutOption
        /// Nothing special — the existing handling applies.
        case unchanged
    }

    static func resolve(escapeKey: EscapeKeySource,
                        globeKey: GlobeKeyAction,
                        languageKey: LanguageKeySource) -> KeyRemapPlan {
        var notes: [String] = []
        let escapeFrom = escapeKey.hidUsage
        let graveRule = escapeKey.graveRule

        var switchFrom: UInt16?
        if globeKey == .switchLanguage {
            if escapeFrom == KeyboardMap.HID.globe {
                notes.append("globeKey=switchLanguage is inert — escapeKey=globe owns the Globe key. "
                    + "Set escapeKey to capsLock (or none), or set languageKey to capsLock.")
            } else {
                switchFrom = KeyboardMap.HID.globe
            }
        }
        if languageKey == .capsLock {
            if escapeFrom == KeyboardMap.HID.capsLock {
                notes.append("languageKey=capsLock is inert — escapeKey=capsLock owns Caps Lock.")
            } else if switchFrom != nil {
                notes.append("languageKey=capsLock is inert — the Globe key is already switching "
                    + "the input source.")
            } else {
                switchFrom = KeyboardMap.HID.capsLock
            }
        }

        // globeKey == .escape with escapeKey naming a different key: both
        // produce Escape, which is not a conflict — it is two Escape keys, and
        // a keyboard with two of them is a keyboard with one more than this
        // one has.
        return KeyRemapPlan(escapeFrom: escapeFrom,
                            switchInputSourceFrom: switchFrom,
                            conflictNote: notes.isEmpty ? nil : notes.joined(separator: " "),
                            graveRule: graveRule)
    }

    /// Convenience for the injector, which also has to honour
    /// `globeKey == .escape`.
    static func resolveFromDefaults(_ defaults: UserDefaults = .standard) -> KeyRemapPlan {
        let escapeKey = EscapeKeySource.fromDefaults(defaults)
        let globeKey = GlobeKeyAction.fromDefaults(defaults)
        let languageKey = LanguageKeySource.fromDefaults(defaults)
        let base = resolve(escapeKey: escapeKey, globeKey: globeKey, languageKey: languageKey)
        guard globeKey == .escape, base.escapeFrom != KeyboardMap.HID.globe else { return base }
        // Two Escape keys. `escapeFrom` holds one; the Globe key is handled by
        // `action(for:)` reading `alsoEscapeFromGlobe`.
        return KeyRemapPlan(escapeFrom: base.escapeFrom,
                            switchInputSourceFrom: base.switchInputSourceFrom,
                            conflictNote: base.conflictNote,
                            alsoEscapeFromGlobe: true,
                            graveRule: base.graveRule)
    }

    /// `globeKey == .escape` while `escapeKey` names some other key.
    let alsoEscapeFromGlobe: Bool
    /// What the backtick key does. The grave escape options claim
    /// the same usage, so `escapeFrom` alone cannot say which rule applies.
    let graveRule: GraveRule

    init(escapeFrom: UInt16?, switchInputSourceFrom: UInt16?,
         conflictNote: String?, alsoEscapeFromGlobe: Bool = false,
         graveRule: GraveRule = .none) {
        self.escapeFrom = escapeFrom
        self.switchInputSourceFrom = switchInputSourceFrom
        self.conflictNote = conflictNote
        self.alsoEscapeFromGlobe = alsoEscapeFromGlobe
        self.graveRule = graveRule
    }

    /// What this usage does, given the modifiers held with it.
    ///
    /// `command` is "this event carries Command *after* `commandKeyRemap` has
    /// been applied" — so a remapped Option satisfies it, which is what makes
    /// the chord reachable on a keyboard whose ⌘` iPadOS eats.
    func action(for hidUsage: UInt16, shift: Bool, option: Bool,
                command: Bool = false, control: Bool = false) -> Action {
        if hidUsage == KeyboardMap.HID.grave {
            switch graveRule {
            case .commandChordIsEscape:
                // Only the chord is claimed. Everything else about this key —
                // the backtick, the tilde, ⌥`, ⌃` — is left exactly as it was,
                // which is why this option costs nothing.
                return command ? .escapeWithoutCommand : .unchanged
            case .controlChordIsEscape:
                return control ? .escapeWithoutControl : .unchanged
            case .plainIsEscape:
                switch GraveAction.resolve(shift: shift, option: option) {
                case .escape: return .escape
                case .backtick(let stripOption):
                    return stripOption ? .passThroughWithoutOption : .unchanged
                }
            case .none:
                break
            }
        }
        if hidUsage == escapeFrom { return .escape }
        if alsoEscapeFromGlobe, hidUsage == KeyboardMap.HID.globe { return .escape }
        if hidUsage == switchInputSourceFrom { return .switchInputSource }
        return .unchanged
    }

    /// Whether this plan takes Caps Lock away from its normal treatment.
    ///
    /// The Mac's own Caps Lock latch must never be toggled by a remapped key,
    /// and the `.maskAlphaShift` the iPad reports has to be dropped from the
    /// keys that follow — otherwise a user who taps Caps Lock for Escape finds
    /// everything they type afterwards in capitals on one side and not the
    /// other.
    var claimsCapsLock: Bool {
        escapeFrom == KeyboardMap.HID.capsLock
            || switchInputSourceFrom == KeyboardMap.HID.capsLock
    }

    /// One line at session start, so a user who set two things that collide
    /// finds out from the log rather than from a key that stopped working.
    var summary: String {
        var parts: [String] = []
        if graveRule == .commandChordIsEscape {
            parts.append("Escape from Command + HID 0x35 (⌘`, which never reaches this Mac as ⌘`)")
        } else if graveRule == .controlChordIsEscape {
            parts.append("Escape from Control + HID 0x35")
        } else {
            parts.append(escapeFrom.map { "Escape from HID 0x\(String($0, radix: 16))" }
                         ?? "no Escape key")
        }
        if alsoEscapeFromGlobe {
            parts.append("Escape also from the Globe key (669)")
        }
        if let switchInputSourceFrom {
            parts.append("input-source switch from HID 0x\(String(switchInputSourceFrom, radix: 16))")
        }
        var line = "key remap: " + parts.joined(separator: ", ")
        if let conflictNote { line += " — \(conflictNote)" }
        return line
    }
}

/// Which input source comes next.
///
/// Split out from the Text Input Source API for the usual reason: the ordering
/// is the part that can be wrong, and it is the part that cannot be exercised
/// without changing the tester's actual keyboard.
enum InputSourceCycle {

    /// The next source after `current`, wrapping. Nil when there is nothing to
    /// switch to.
    ///
    /// * fewer than two sources — nil. Cycling a list of one is a no-op that
    ///   would still log a line every time the key was pressed.
    /// * `current` not in the list (it was just disabled in System Settings,
    ///   or it is a non-keyboard source like the emoji picker) — the first
    ///   entry, because *some* keyboard is better than staying on one the user
    ///   has removed.
    static func next(after current: String?, in sources: [String]) -> String? {
        guard sources.count > 1 else { return nil }
        guard let current, let index = sources.firstIndex(of: current) else {
            return sources.first
        }
        return sources[(index + 1) % sources.count]
    }
}
