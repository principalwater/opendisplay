import CoreGraphics
import Foundation

/// Translation between what an iPad's `UIPress` reports and what macOS wants
/// injected: USB HID Keyboard/Keypad usage page (0x07) codes — which is exactly
/// what `UIKey.keyCode` is — to macOS virtual keycodes, and
/// `UIKeyModifierFlags` bits to `CGEventFlags`.
///
/// **Keycodes, not characters.** A virtual keycode names a *position* on the
/// keyboard; the character it produces is decided by the input source selected
/// on the Mac. Forwarding the keycode is therefore what makes a Russian (or
/// any other non-Latin) layout work: the iPad may have produced "ф", but the
/// Mac's own ЙЦУКЕН layout turns keycode 0x00 into "ф" by itself. Forwarding
/// the character instead would fight the Mac's input source and break dead
/// keys, Caps-Lock handling and every ⌘-shortcut. `UIKey.characters` is only
/// used for usages with no virtual keycode at all (see InputInjector).
///
/// Which physical Option key — if any — the Mac sender turns into Command.
///
/// The Sunshine `key_rightalt_to_key_win` habit, made selectable. iPadOS keeps
/// a long list of ⌘ chords for itself (⌘Tab, ⌘Space, ⌘H, ⌘⇧3/4, Globe combos)
/// and never delivers them to an app, so the operator presses an Option key and
/// means Command. Which Option key is a matter of taste and of which ⌘ chords
/// the iPad eats: **left**-⌘ chords are the ones iPadOS reserves most of, so a
/// user who leans on the left thumb wants left Option to be the stand-in.
///
/// Stored as a string under `commandKeyRemap` in the sender's UserDefaults
/// domain:
///
/// ```sh
/// defaults write com.peetzweg.opensidecar.mac.alfheim commandKeyRemap -string leftOption
/// ```
///
/// **Precedence**, highest first:
///   1. `commandKeyRemap`, when present and one of the four values below;
///   2. the legacy boolean `remapRightOptionToCommand`, when present —
///      `true` → `.rightOption`, `false` → `.none`;
///   3. `.rightOption`, the behaviour this fork shipped before the setting
///      existed.
///
/// A present but *unrecognized* `commandKeyRemap` string is treated as absent
/// and falls through to 2 and then 3: a typo degrades to the previous
/// behaviour rather than silently taking the Command stand-in away, which on a
/// keyboard-driven session would be the more surprising failure.
enum CommandKeyRemap: String, CaseIterable, Sendable {

    /// Pass the keys through natively: Option stays Option, Command stays
    /// Command. Nothing is rewritten.
    case none

    /// Left Option → Command. Right Option stays Option.
    case leftOption

    /// Right Option → Command. Left Option stays Option.
    case rightOption

    /// Both Option keys → Command. No Option key is left on the keyboard.
    case bothOptions

    static let defaultsKey = "commandKeyRemap"
    static let legacyDefaultsKey = "remapRightOptionToCommand"

    /// What an absent (or unreadable) setting means — the fork's original
    /// behaviour, so an upgrade changes nothing for an existing user.
    static let fallback: CommandKeyRemap = .rightOption

    var remapsLeftOption: Bool { self == .leftOption || self == .bothOptions }
    var remapsRightOption: Bool { self == .rightOption || self == .bothOptions }

    /// True when this HID usage is an Option key that now stands in for
    /// Command. False for every non-Option usage.
    func remapsToCommand(_ hidUsage: UInt16) -> Bool {
        switch hidUsage {
        case KeyboardMap.HID.leftOption:  return remapsLeftOption
        case KeyboardMap.HID.rightOption: return remapsRightOption
        default: return false
        }
    }

    /// Label for the Mac app's "Command key" picker.
    var label: String {
        switch self {
        case .none:        return "None"
        case .leftOption:  return "Left Option"
        case .rightOption: return "Right Option"
        case .bothOptions: return "Both Options"
        }
    }

    /// One-line explanation under that picker. Always says when the setting
    /// takes effect: it is read once per session, which is surprising enough
    /// to be worth stating in the UI rather than only in the docs.
    var hint: String {
        switch self {
        case .none:
            return "Option and Command pass through as themselves. Applies to the next session."
        case .leftOption:
            return "Left Option on the device's keyboard arrives as Command; right Option stays Option. Applies to the next session."
        case .rightOption:
            return "Right Option on the device's keyboard arrives as Command; left Option stays Option. Applies to the next session."
        case .bothOptions:
            return "Both Option keys on the device's keyboard arrive as Command; no Option key is left. Applies to the next session."
        }
    }

    /// Pure resolution of the two defaults keys, per the precedence documented
    /// above. Split out from `fromDefaults()` so the precedence is testable
    /// without writing into any real UserDefaults domain.
    static func resolve(commandKeyRemap raw: String?,
                        legacyRemapRightOption legacy: Bool?) -> CommandKeyRemap {
        if let raw, let explicit = CommandKeyRemap(rawValue: raw) { return explicit }
        if let legacy { return legacy ? .rightOption : .none }
        return fallback
    }

    /// Read when the injector is built, i.e. the setting takes effect on the
    /// **next** session, never mid-stream — the remap has to be constant for
    /// the lifetime of a key's down/up pair or a key could go down as Option
    /// and come up as Command.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> CommandKeyRemap {
        let legacy: Bool? = defaults.object(forKey: legacyDefaultsKey) == nil
            ? nil
            : defaults.bool(forKey: legacyDefaultsKey)
        return resolve(commandKeyRemap: defaults.string(forKey: defaultsKey),
                       legacyRemapRightOption: legacy)
    }
}

/// Pure value code, no CoreGraphics event posting — unit-testable as is.
enum KeyboardMap {

    // MARK: - UIKeyModifierFlags raw bits
    //
    // Hard-coded rather than imported: this file compiles into macOS targets
    // where UIKit does not exist. The values are UIKit's and are wire ABI —
    // they travel inside the `mod` field of the `key` control message.

    static let uiAlphaShift: UInt = 1 << 16
    static let uiShift: UInt = 1 << 17
    static let uiControl: UInt = 1 << 18
    static let uiAlternate: UInt = 1 << 19
    static let uiCommand: UInt = 1 << 20
    static let uiNumericPad: UInt = 1 << 21

    // MARK: - HID usages this code reasons about by name

    enum HID {
        static let escape: UInt16 = 0x29
        static let grave: UInt16 = 0x35
        static let capsLock: UInt16 = 0x39
        static let leftControl: UInt16 = 0xE0
        static let leftShift: UInt16 = 0xE1
        static let leftOption: UInt16 = 0xE2
        static let leftCommand: UInt16 = 0xE3
        static let rightControl: UInt16 = 0xE4
        static let rightShift: UInt16 = 0xE5
        static let rightOption: UInt16 = 0xE6
        static let rightCommand: UInt16 = 0xE7
        static let range = leftControl...rightCommand
        /// The two keys the Command remap can rewrite.
        static let optionKeys: Set<UInt16> = [leftOption, rightOption]

        /// The Globe / 🌐 key on an Apple iPad keyboard.
        ///
        /// **Not a keyboard-page usage at all.** HID page 0x07 has no fn or
        /// Globe usage and `UIKeyboardHIDUsage` therefore has no case for it —
        /// which is what the fork's own §5 concluded from, wrongly. iPadOS
        /// delivers it to `pressesBegan` anyway, with `UIKey.keyCode.rawValue`
        /// == 669 == 0x29D, which is **Consumer page (0x0C) usage 0x29D, "AC
        /// Next Keyboard Layout Select"** (HUTRR56; Linux calls it
        /// `KEY_KBD_LAYOUT_NEXT`). UIKit passes it through raw because it has
        /// no name for it.
        ///
        /// Empirically attested rather than documented by Apple — Moonlight
        /// for iOS has shipped the same constant since PR #610, and found it
        /// the same way, by logging what fell through their switch. Treat a
        /// future iPadOS that stops sending it as possible: everything here
        /// degrades to "the Globe key does nothing", which is what it did
        /// before.
        static let globe: UInt16 = 669
    }

    /// Device-dependent modifier bits (`NX_DEVICE*KEYMASK` from
    /// IOKit/hidsystem/IOLLEvent.h). AppKit's `.maskShift` & friends only say
    /// *a* shift is down; these say *which*. Setting them makes a remapped
    /// right Option indistinguishable from a real right Command for the apps
    /// that look (Karabiner-aware apps, remote-desktop clients, games).
    private enum DeviceBits {
        static let leftControl: UInt64 = 0x00000001
        static let leftShift: UInt64 = 0x00000002
        static let rightShift: UInt64 = 0x00000004
        static let leftCommand: UInt64 = 0x00000008
        static let rightCommand: UInt64 = 0x00000010
        static let leftOption: UInt64 = 0x00000020
        static let rightOption: UInt64 = 0x00000040
        static let rightControl: UInt64 = 0x00002000
    }

    /// True for the eight modifier keys (0xE0…0xE7). They are injected as
    /// `.flagsChanged`, never as key down/up, and they never auto-repeat.
    static func isModifier(_ hidUsage: UInt16) -> Bool { HID.range.contains(hidUsage) }

    /// The flags one physically-held modifier key contributes.
    ///
    /// The Command remap (see `CommandKeyRemap`) has to move the *flag* as well
    /// as the keycode, or Option+C on a remapped key would arrive as a bare
    /// "c". A remapped Option contributes the device-dependent Command bit for
    /// its own side, so a remapped left Option is byte-identical to a real left
    /// Command and a remapped right Option to a real right Command.
    static func flags(forModifier hidUsage: UInt16,
                      commandKeyRemap: CommandKeyRemap) -> CGEventFlags {
        switch hidUsage {
        case HID.leftShift:    return CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | DeviceBits.leftShift)
        case HID.rightShift:   return CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | DeviceBits.rightShift)
        case HID.leftControl:  return CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | DeviceBits.leftControl)
        case HID.rightControl: return CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | DeviceBits.rightControl)
        case HID.leftOption:
            return commandKeyRemap.remapsLeftOption
                ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceBits.leftCommand)
                : CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | DeviceBits.leftOption)
        case HID.rightOption:
            return commandKeyRemap.remapsRightOption
                ? CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceBits.rightCommand)
                : CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | DeviceBits.rightOption)
        case HID.leftCommand:  return CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceBits.leftCommand)
        case HID.rightCommand: return CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | DeviceBits.rightCommand)
        default: return []
        }
    }

    /// `UIKeyModifierFlags` bitmask (the `mod` wire field) to `CGEventFlags`.
    /// Note what is *not* here: UIKit has one `.alternate` bit for both Option
    /// keys, which is the whole reason InputInjector tracks modifier key
    /// down/up itself instead of trusting this.
    static func eventFlags(for rawModifiers: UInt, sticky: CGEventFlags = []) -> CGEventFlags {
        var flags: CGEventFlags = sticky
        if rawModifiers & uiShift != 0 { flags.insert(.maskShift) }
        if rawModifiers & uiControl != 0 { flags.insert(.maskControl) }
        if rawModifiers & uiAlternate != 0 { flags.insert(.maskAlternate) }
        if rawModifiers & uiCommand != 0 { flags.insert(.maskCommand) }
        if rawModifiers & uiAlphaShift != 0 { flags.insert(.maskAlphaShift) }
        if rawModifiers & uiNumericPad != 0 { flags.insert(.maskNumericPad) }
        return flags
    }

    /// HID usage -> macOS virtual keycode, with the Command remap applied.
    ///
    /// A remapped Option key keeps its *side*: left Option becomes
    /// `kVK_Command`, right Option `kVK_RightCommand`, so apps that look at the
    /// keycode (and at the device-dependent flag bits above) cannot tell the
    /// stand-in from the real key.
    static func macKeyCode(for hidUsage: UInt16,
                           commandKeyRemap: CommandKeyRemap) -> CGKeyCode? {
        switch hidUsage {
        case HID.leftOption where commandKeyRemap.remapsLeftOption:
            return 0x37   // kVK_Command
        case HID.rightOption where commandKeyRemap.remapsRightOption:
            return 0x36   // kVK_RightCommand
        default:
            return macKeyCode(for: hidUsage)
        }
    }

    /// HID Keyboard/Keypad usage page (0x07) -> macOS virtual keycode.
    ///
    /// Covers everything a Magic Keyboard can emit: letters, digits, the whole
    /// punctuation block on ANSI *and* the two extra ISO keys, the function
    /// row, navigation cluster, arrows, the numeric keypad, the modifiers, and
    /// the JIS keys. Values are `kVK_*` from Carbon's HIToolbox/Events.h.
    ///
    /// Returns nil for usages macOS has no virtual keycode for at all
    /// (media/volume keys, which are NX system-defined events, the Application
    /// "menu" key, Power, and the 0x00…0x03 error-rollover codes). Those fall
    /// back to the `char` field on the wire.
    static func macKeyCode(for hidUsage: UInt16) -> CGKeyCode? {
        switch hidUsage {
        // Letters. Positional: the Mac's own input source decides the
        // character, so a Russian layout on the Mac produces Cyrillic.
        case 0x04: return 0x00 // A
        case 0x05: return 0x0B // B
        case 0x06: return 0x08 // C
        case 0x07: return 0x02 // D
        case 0x08: return 0x0E // E
        case 0x09: return 0x03 // F
        case 0x0A: return 0x05 // G
        case 0x0B: return 0x04 // H
        case 0x0C: return 0x22 // I
        case 0x0D: return 0x26 // J
        case 0x0E: return 0x28 // K
        case 0x0F: return 0x25 // L
        case 0x10: return 0x2E // M
        case 0x11: return 0x2D // N
        case 0x12: return 0x1F // O
        case 0x13: return 0x23 // P
        case 0x14: return 0x0C // Q
        case 0x15: return 0x0F // R
        case 0x16: return 0x01 // S
        case 0x17: return 0x11 // T
        case 0x18: return 0x20 // U
        case 0x19: return 0x09 // V
        case 0x1A: return 0x0D // W
        case 0x1B: return 0x07 // X
        case 0x1C: return 0x10 // Y
        case 0x1D: return 0x06 // Z

        // Digit row
        case 0x1E: return 0x12 // 1
        case 0x1F: return 0x13 // 2
        case 0x20: return 0x14 // 3
        case 0x21: return 0x15 // 4
        case 0x22: return 0x17 // 5
        case 0x23: return 0x16 // 6
        case 0x24: return 0x1A // 7
        case 0x25: return 0x1C // 8
        case 0x26: return 0x19 // 9
        case 0x27: return 0x1D // 0

        // Editing + punctuation (ANSI positions)
        case 0x28: return 0x24 // Return
        case 0x29: return 0x35 // Escape
        case 0x2A: return 0x33 // Delete (Backspace)
        case 0x2B: return 0x30 // Tab
        case 0x2C: return 0x31 // Space
        case 0x2D: return 0x1B // - _
        case 0x2E: return 0x18 // = +
        case 0x2F: return 0x21 // [ {
        case 0x30: return 0x1E // ] }
        case 0x31: return 0x2A // \ |
        // 0x32 "Non-US # and ~": the key ISO keyboards put where ANSI has a
        // tall Return. Apple's ISO layouts drive it from the same virtual
        // keycode as backslash.
        case 0x32: return 0x2A
        case 0x33: return 0x29 // ; :
        case 0x34: return 0x27 // ' "
        case 0x35: return 0x32 // ` ~
        case 0x36: return 0x2B // , <
        case 0x37: return 0x2F // . >
        case 0x38: return 0x2C // / ?
        case 0x39: return 0x39 // Caps Lock

        // Function row
        case 0x3A: return 0x7A // F1
        case 0x3B: return 0x78 // F2
        case 0x3C: return 0x63 // F3
        case 0x3D: return 0x76 // F4
        case 0x3E: return 0x60 // F5
        case 0x3F: return 0x61 // F6
        case 0x40: return 0x62 // F7
        case 0x41: return 0x64 // F8
        case 0x42: return 0x65 // F9
        case 0x43: return 0x6D // F10
        case 0x44: return 0x67 // F11
        case 0x45: return 0x6F // F12

        // PrintScreen / ScrollLock / Pause have no Mac key; Apple's own USB
        // keyboard driver folds them onto F13…F15, so do the same.
        case 0x46: return 0x69 // PrintScreen -> F13
        case 0x47: return 0x6B // ScrollLock  -> F14
        case 0x48: return 0x71 // Pause       -> F15

        // Navigation cluster
        case 0x49: return 0x72 // Insert -> Help
        case 0x4A: return 0x73 // Home
        case 0x4B: return 0x74 // Page Up
        case 0x4C: return 0x75 // Delete Forward
        case 0x4D: return 0x77 // End
        case 0x4E: return 0x79 // Page Down

        // Arrows
        case 0x4F: return 0x7C // Right
        case 0x50: return 0x7B // Left
        case 0x51: return 0x7D // Down
        case 0x52: return 0x7E // Up

        // Numeric keypad
        case 0x53: return 0x47 // Num Lock -> Clear
        case 0x54: return 0x4B // Keypad /
        case 0x55: return 0x43 // Keypad *
        case 0x56: return 0x4E // Keypad -
        case 0x57: return 0x45 // Keypad +
        case 0x58: return 0x4C // Keypad Enter
        case 0x59: return 0x53 // Keypad 1
        case 0x5A: return 0x54 // Keypad 2
        case 0x5B: return 0x55 // Keypad 3
        case 0x5C: return 0x56 // Keypad 4
        case 0x5D: return 0x57 // Keypad 5
        case 0x5E: return 0x58 // Keypad 6
        case 0x5F: return 0x59 // Keypad 7
        case 0x60: return 0x5B // Keypad 8
        case 0x61: return 0x5C // Keypad 9
        case 0x62: return 0x52 // Keypad 0
        case 0x63: return 0x41 // Keypad .

        // "Non-US \ and |": the extra key between left Shift and Z on every
        // ISO keyboard, including the ISO Magic Keyboard.
        case 0x64: return 0x0A // kVK_ISO_Section
        case 0x67: return 0x51 // Keypad =

        // F13…F20 (Apple stops at F20)
        case 0x68: return 0x69 // F13
        case 0x69: return 0x6B // F14
        case 0x6A: return 0x71 // F15
        case 0x6B: return 0x6A // F16
        case 0x6C: return 0x40 // F17
        case 0x6D: return 0x4F // F18
        case 0x6E: return 0x50 // F19
        case 0x6F: return 0x5A // F20

        // JIS keys (harmless on ANSI/ISO hardware, which never sends them)
        case 0x85: return 0x5F // Keypad comma
        case 0x87: return 0x5E // kVK_JIS_Underscore
        case 0x88: return 0x68 // Katakana/Hiragana -> kVK_JIS_Kana
        case 0x89: return 0x5D // kVK_JIS_Yen
        case 0x8A: return 0x68 // Henkan   -> kVK_JIS_Kana
        case 0x8B: return 0x66 // Muhenkan -> kVK_JIS_Eisu
        case 0x90: return 0x68 // LANG1 -> kVK_JIS_Kana
        case 0x91: return 0x66 // LANG2 -> kVK_JIS_Eisu

        // Modifiers
        case HID.leftControl:  return 0x3B
        case HID.leftShift:    return 0x38
        case HID.leftOption:   return 0x3A
        case HID.leftCommand:  return 0x37
        case HID.rightControl: return 0x3E
        case HID.rightShift:   return 0x3C
        case HID.rightOption:  return 0x3D
        case HID.rightCommand: return 0x36

        default: return nil
        }
    }
}

/// Which modifier keys are *physically* held, tracked from the key down/up
/// stream rather than read off `UIKeyModifierFlags`.
///
/// Necessary because UIKit reports one `.alternate` bit for both Option keys
/// and one `.command` bit for both Command keys, and the Command remap
/// (`CommandKeyRemap`) needs to know which side is down. Also makes a key's own event carry the
/// right flags: UIKit is not consistent about whether the modifier being
/// pressed or released is already reflected in the `modifierFlags` of that
/// very press.
struct ModifierKeyState {

    private(set) var held: Set<UInt16> = []

    /// Returns true when this usage was a modifier and the state changed.
    @discardableResult
    mutating func update(hidUsage: UInt16, down: Bool) -> Bool {
        guard KeyboardMap.isModifier(hidUsage) else { return false }
        if down { return held.insert(hidUsage).inserted }
        return held.remove(hidUsage) != nil
    }

    mutating func clear() { held.removeAll() }

    /// Flags to stamp on an injected event.
    ///
    /// - `reported`: the `mod` field from the wire (UIKeyModifierFlags bits).
    /// - `includeReported`: false for a modifier key's own event. UIKit may or
    ///   may not have already folded that key into `modifierFlags`, so for the
    ///   event that *is* the transition we trust only our own tracked set,
    ///   which is exact. For every other key the two are unioned, so a
    ///   modifier that went down while the video view was not first responder
    ///   still reaches the Mac.
    /// - `sticky`: the on-screen modifier sidebar's latched flags (#247).
    func flags(reported: UInt,
               includeReported: Bool,
               commandKeyRemap: CommandKeyRemap,
               sticky: CGEventFlags = []) -> CGEventFlags {
        // Physical first, sticky last. The Option normalization below
        // *removes* `.maskAlternate`, and it must only ever remove the one a
        // physical, remapped Option contributed. Folding the sidebar's latched
        // flags in first (as this fork originally did) meant that with ⌥
        // latched on screen and a remapped Option held, the user's deliberate
        // virtual Option was deleted and only Command survived.
        var flags: CGEventFlags = []
        for usage in held {
            flags.formUnion(KeyboardMap.flags(forModifier: usage,
                                              commandKeyRemap: commandKeyRemap))
        }
        let reportedFlags = KeyboardMap.eventFlags(for: reported)
        if includeReported {
            flags.formUnion(reportedFlags)
            // The iPad has one `.alternate` bit for *both* Option keys, so the
            // bit just unioned in is only ever a re-report of an Option key
            // this state already knows about. Drop it precisely when every
            // Option physically held is one that now means Command; if a
            // non-remapped Option is down too, the user really is holding
            // Option and the bit stays (alongside the Command the remapped one
            // contributes). With no Option held at all nothing is removed —
            // the reported bit then comes from a key pressed while the video
            // view was not first responder, and guessing it away would lose it.
            let heldOptions = held.intersection(KeyboardMap.HID.optionKeys)
            if !heldOptions.isEmpty,
               heldOptions.allSatisfy(commandKeyRemap.remapsToCommand) {
                flags.remove(.maskAlternate)
                flags.insert(.maskCommand)
            }
        }
        // Caps Lock is a latch, not a held key: it is only ever reported.
        if reportedFlags.contains(.maskAlphaShift) { flags.insert(.maskAlphaShift) }
        // Virtual modifiers from the on-screen sidebar: unioned after the
        // normalization so nothing above can take them away again. The caller
        // is responsible for not passing them on a physical modifier's own
        // `.flagsChanged` — see InputInjector.lockedHandleKey.
        flags.formUnion(sticky)
        return flags
    }
}

/// Range checks for the peer-supplied numbers on the input control path.
///
/// The wire is unauthenticated: anything that can reach the sender's port can
/// put any JSON number in a `key` or `modSidebar` message, and Swift's
/// `UInt16(someInt)` **traps** rather than failing — one negative value is a
/// remote crash of the sender, i.e. of the Mac's only display. Nothing on this
/// path converts a peer's number without coming through here.
enum WireInput {

    /// A HID usage is a 16-bit unsigned value. Out of range means "ignore the
    /// message" — there is no key it could mean.
    static func hidUsage(_ value: Int) -> UInt16? { UInt16(exactly: value) }

    /// A `UIKeyModifierFlags` bitmask. A nonsensical value degrades to "no
    /// modifiers" rather than dropping the keystroke: losing the shift is
    /// recoverable, losing the letter is not. Only the defined bits are kept,
    /// so a peer cannot smuggle anything else into the flag set.
    static func modifierMask(_ value: Int?) -> UInt {
        guard let value, let raw = UInt(exactly: value) else { return 0 }
        return raw & definedModifierBits
    }

    /// Latched sidebar flags. Out of range means "ignore": unlike a keystroke
    /// this is *state*, and guessing at state is worse than leaving it alone.
    static func stickyFlags(_ value: Int) -> UInt? {
        guard let raw = UInt(exactly: value) else { return nil }
        return raw & definedModifierBits
    }

    /// `scroll.phase`, the additive field a Native-mode receiver sends.
    ///
    /// An unknown or absent phase is nil, which makes `handleScroll` post the
    /// phase-less event it always posted — so a future phase name degrades to
    /// "a scroll happened" rather than being dropped.
    static func scrollPhase(_ value: Any?) -> ScrollPhase? {
        guard let name = value as? String else { return nil }
        return ScrollPhase(rawValue: name)
    }

    /// A pinch's incremental scale factor. Must be finite and positive to have
    /// a logarithm; anything else is ignored rather than turned into a NaN the
    /// injector would carry for the rest of the session.
    static func zoomScale(_ value: Any?) -> Double? {
        guard let scale = value as? Double, scale.isFinite, scale > 0 else { return nil }
        return scale
    }

    /// A normalized `[0,1]` coordinate off the wire — `zoom.x` / `zoom.y`, the
    /// pinch centroid.
    ///
    /// Clamped rather than rejected when it is slightly outside the unit
    /// square: a receiver whose letterbox arithmetic is a pixel out on the last
    /// row should still zoom at the edge of the display rather than have the
    /// gesture silently fall back to the cursor. A value that is not a finite
    /// number at all *is* rejected — it is not a coordinate, and warping the
    /// cursor to a NaN is how a Mac loses its pointer.
    static func normalizedCoordinate(_ value: Any?) -> Double? {
        guard let n = value as? Double, n.isFinite else { return nil }
        return min(max(n, 0), 1)
    }

    private static let definedModifierBits: UInt =
        KeyboardMap.uiAlphaShift | KeyboardMap.uiShift | KeyboardMap.uiControl
        | KeyboardMap.uiAlternate | KeyboardMap.uiCommand | KeyboardMap.uiNumericPad
}
