import CoreGraphics
import XCTest

/// The keys an iPad Magic Keyboard does not have (§35).
///
/// Everything here is Mac-side and pure: the iPad sends raw HID usages and
/// knows nothing about any of it, so these tests are the whole specification.
final class KeyRemapPlanTests: XCTestCase {

    // MARK: - Defaults

    /// The round-7 defaults, which the operator asked for by name: ⌘` is
    /// Escape, Globe switches the Mac's input source, and Caps Lock is left
    /// alone so it is an ordinary Caps Lock again.
    ///
    /// The three no longer collide at all — which is the point of moving
    /// Escape onto a *chord*. Round 6's defaults named the Globe key twice and
    /// had to print a conflict note to explain which one won.
    func testTheForkDefaultsAreTheCommandGraveChordAndGlobeForTheInputSource() {
        XCTAssertEqual(EscapeKeySource.fallback, .leftCommandGrave)
        XCTAssertEqual(GlobeKeyAction.fallback, .switchLanguage)
        XCTAssertEqual(LanguageKeySource.fallback, .none)

        let plan = KeyRemapPlan.resolve(escapeKey: .fallback,
                                        globeKey: .fallback,
                                        languageKey: .fallback)
        XCTAssertNil(plan.conflictNote, "the defaults must not collide any more")
        XCTAssertEqual(plan.switchInputSourceFrom, KeyboardMap.HID.globe)
        XCTAssertFalse(plan.claimsCapsLock, "Caps Lock is a normal Caps Lock again")
    }

    func testAnUnrecognisedValueFallsBackRatherThanFailing() {
        XCTAssertEqual(EscapeKeySource.resolve("nonsense"), .leftCommandGrave)
        XCTAssertEqual(EscapeKeySource.resolve(nil), .leftCommandGrave)
        XCTAssertEqual(EscapeKeySource.resolve("globe"), .globe, "every old value still works")
        XCTAssertEqual(EscapeKeySource.resolve("capsLock"), .capsLock)
        XCTAssertEqual(EscapeKeySource.resolve("grave"), .grave)
        XCTAssertEqual(EscapeKeySource.resolve("none"), EscapeKeySource.none)
        XCTAssertEqual(GlobeKeyAction.resolve("Escape"), .switchLanguage, "raw values are case-sensitive")
        XCTAssertEqual(GlobeKeyAction.resolve("escape"), .escape)
        XCTAssertEqual(LanguageKeySource.resolve("capsLock"), .capsLock)
    }

    func testEveryOptionHasALabelAndAHint() {
        for source in EscapeKeySource.allCases {
            XCTAssertFalse(source.label.isEmpty)
            XCTAssertFalse(source.hint.isEmpty)
        }
        for action in GlobeKeyAction.allCases {
            XCTAssertFalse(action.label.isEmpty)
            XCTAssertFalse(action.hint.isEmpty)
        }
        for source in LanguageKeySource.allCases {
            XCTAssertFalse(source.label.isEmpty)
            XCTAssertFalse(source.hint.isEmpty)
        }
    }

    func testTheGlobeUsageIsTheOneMoonlightShips() {
        // 669 == 0x29D, Consumer page "AC Next Keyboard Layout Select". Not a
        // HID keyboard-page usage, which is why `UIKeyboardHIDUsage` has no
        // case for it and why this number has to be written down somewhere.
        XCTAssertEqual(KeyboardMap.HID.globe, 669)
        XCTAssertEqual(KeyboardMap.HID.escape, 0x29)
        XCTAssertEqual(KeyboardMap.HID.grave, 0x35)
        XCTAssertEqual(KeyboardMap.HID.capsLock, 0x39)
    }

    // MARK: - The collision, which is the whole reason this is a pure type

    func testTheTwoDefaultsCollideAndEscapeWins() {
        let plan = KeyRemapPlan.resolve(escapeKey: .globe, globeKey: .switchLanguage,
                                        languageKey: .none)
        XCTAssertEqual(plan.escapeFrom, KeyboardMap.HID.globe)
        XCTAssertNil(plan.switchInputSourceFrom,
                     "the Globe key cannot both be Escape and switch the language")
        XCTAssertNotNil(plan.conflictNote, "and the user has to be told which one lost")
        XCTAssertTrue(plan.conflictNote!.contains("languageKey"),
                      "the note has to name the way out")
    }

    func testGlobeSwitchesTheLanguageOnceEscapeIsSomewhereElse() {
        let plan = KeyRemapPlan.resolve(escapeKey: .capsLock, globeKey: .switchLanguage,
                                        languageKey: .none)
        XCTAssertEqual(plan.escapeFrom, KeyboardMap.HID.capsLock)
        XCTAssertEqual(plan.switchInputSourceFrom, KeyboardMap.HID.globe)
        XCTAssertNil(plan.conflictNote)
    }

    func testCapsLockCanSwitchTheLanguageWhenGlobeIsEscape() {
        let plan = KeyRemapPlan.resolve(escapeKey: .globe, globeKey: .switchLanguage,
                                        languageKey: .capsLock)
        XCTAssertEqual(plan.escapeFrom, KeyboardMap.HID.globe)
        XCTAssertEqual(plan.switchInputSourceFrom, KeyboardMap.HID.capsLock,
                       "this is the configuration the two defaults push a user towards")
    }

    func testCapsLockCannotBeBothEscapeAndTheLanguageKey() {
        let plan = KeyRemapPlan.resolve(escapeKey: .capsLock, globeKey: .none,
                                        languageKey: .capsLock)
        XCTAssertEqual(plan.escapeFrom, KeyboardMap.HID.capsLock)
        XCTAssertNil(plan.switchInputSourceFrom)
        XCTAssertNotNil(plan.conflictNote)
    }

    func testTheGlobeKeyWinsTheLanguageSwitchOverCapsLock() {
        // Both asked for; only one can have it, and Globe is the key that says
        // "language" on it.
        let plan = KeyRemapPlan.resolve(escapeKey: .grave, globeKey: .switchLanguage,
                                        languageKey: .capsLock)
        XCTAssertEqual(plan.switchInputSourceFrom, KeyboardMap.HID.globe)
        XCTAssertNotNil(plan.conflictNote)
    }

    func testNoneMeansNothingIsRemapped() {
        let plan = KeyRemapPlan.resolve(escapeKey: .none, globeKey: .none, languageKey: .none)
        XCTAssertNil(plan.escapeFrom)
        XCTAssertNil(plan.switchInputSourceFrom)
        XCTAssertNil(plan.conflictNote)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.capsLock, shift: false, option: false),
                       .unchanged)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.globe, shift: false, option: false),
                       .unchanged)
    }

    func testTwoEscapeKeysAreNotAConflict() {
        // A keyboard with two Escape keys has one more than this one has.
        let plan = KeyRemapPlan(escapeFrom: KeyboardMap.HID.capsLock,
                                switchInputSourceFrom: nil, conflictNote: nil,
                                alsoEscapeFromGlobe: true)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.capsLock, shift: false, option: false),
                       .escape)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.globe, shift: false, option: false),
                       .escape)
    }

    // MARK: - The grave key keeps both its characters

    func testAPlainBacktickIsEscape() {
        XCTAssertEqual(GraveAction.resolve(shift: false, option: false), .escape)
    }

    func testShiftBacktickStillTypesTilde() {
        XCTAssertEqual(GraveAction.resolve(shift: true, option: false),
                       .backtick(stripOption: false),
                       "the key passes through with Shift, so the Mac's layout produces ~")
    }

    func testOptionBacktickTypesALiteralBacktick() {
        XCTAssertEqual(GraveAction.resolve(shift: false, option: true),
                       .backtick(stripOption: true),
                       "Option is consumed by the rule and must not reach the Mac, "
                       + "or several layouts produce a dead key instead of `")
    }

    func testOptionBeatsShift() {
        // ⇧⌥` keeps Shift, loses Option: the Mac sees ⇧` and types ~.
        XCTAssertEqual(GraveAction.resolve(shift: true, option: true),
                       .backtick(stripOption: true))
    }

    func testTheGravePlanRoutesAllThreeCases() {
        let plan = KeyRemapPlan.resolve(escapeKey: .grave, globeKey: .none, languageKey: .none)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.grave, shift: false, option: false),
                       .escape)
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.grave, shift: true, option: false),
                       .unchanged, "Shift+` is the ordinary key path")
        XCTAssertEqual(plan.action(for: KeyboardMap.HID.grave, shift: false, option: true),
                       .passThroughWithoutOption)
    }

    func testModifiersDoNotChangeTheOtherEscapeSources() {
        // Only the grave key has the dual behaviour: ⇧ Caps Lock is still
        // Escape, because there is no second character to protect.
        let plan = KeyRemapPlan.resolve(escapeKey: .capsLock, globeKey: .none, languageKey: .none)
        for shift in [false, true] {
            for option in [false, true] {
                XCTAssertEqual(plan.action(for: KeyboardMap.HID.capsLock,
                                           shift: shift, option: option), .escape)
            }
        }
    }

    // MARK: - Caps Lock bookkeeping

    func testAPlanThatClaimsCapsLockSaysSo() {
        XCTAssertTrue(KeyRemapPlan.resolve(escapeKey: .capsLock, globeKey: .none,
                                           languageKey: .none).claimsCapsLock)
        XCTAssertTrue(KeyRemapPlan.resolve(escapeKey: .globe, globeKey: .none,
                                           languageKey: .capsLock).claimsCapsLock)
        XCTAssertFalse(KeyRemapPlan.resolve(escapeKey: .globe, globeKey: .switchLanguage,
                                            languageKey: .none).claimsCapsLock)
        XCTAssertFalse(KeyRemapPlan.resolve(escapeKey: .grave, globeKey: .none,
                                            languageKey: .none).claimsCapsLock)
    }

    func testTheSummaryNamesWhatHappenedAndWhatLost() {
        let plan = KeyRemapPlan.resolve(escapeKey: .globe, globeKey: .switchLanguage,
                                        languageKey: .none)
        XCTAssertTrue(plan.summary.hasPrefix("key remap: "))
        XCTAssertTrue(plan.summary.contains("29d"), "the Globe usage, in hex")
        XCTAssertTrue(plan.summary.contains("inert"))
        let quiet = KeyRemapPlan.resolve(escapeKey: .none, globeKey: .none, languageKey: .none)
        XCTAssertTrue(quiet.summary.contains("no Escape key"))
        XCTAssertFalse(quiet.summary.contains("—"))
    }

    // MARK: - Input source cycling

    private let sources = ["com.apple.keylayout.ABC",
                           "com.apple.keylayout.Russian",
                           "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"]

    func testCyclingWalksTheListInOrder() {
        XCTAssertEqual(InputSourceCycle.next(after: sources[0], in: sources), sources[1])
        XCTAssertEqual(InputSourceCycle.next(after: sources[1], in: sources), sources[2])
    }

    func testCyclingWraps() {
        XCTAssertEqual(InputSourceCycle.next(after: sources[2], in: sources), sources[0])
    }

    func testOneSourceHasNothingToSwitchTo() {
        // Otherwise the key would log a line and change nothing on every press.
        XCTAssertNil(InputSourceCycle.next(after: sources[0], in: [sources[0]]))
        XCTAssertNil(InputSourceCycle.next(after: nil, in: []))
    }

    func testAnUnknownCurrentSourceLandsOnTheFirst() {
        // The user disabled the current layout in System Settings, or the
        // current source is a non-keyboard one (the emoji picker). Some
        // keyboard beats staying on one that is not in the list.
        XCTAssertEqual(InputSourceCycle.next(after: "com.apple.CharacterPaletteIM", in: sources),
                       sources[0])
        XCTAssertEqual(InputSourceCycle.next(after: nil, in: sources), sources[0])
    }

    func testCyclingTheWholeListReturnsToWhereItStarted() {
        var current: String? = sources[0]
        for _ in sources.indices {
            current = InputSourceCycle.next(after: current, in: sources)
        }
        XCTAssertEqual(current, sources[0])
    }

    // MARK: - Round 7: ⌘` as Escape

    private var chord: KeyRemapPlan {
        KeyRemapPlan.resolve(escapeKey: .leftCommandGrave,
                             globeKey: .switchLanguage,
                             languageKey: .none)
    }

    func testTheChordSendsEscapeAndStripsTheCommand() {
        // The "crucially" of the brief: ⌘` must NOT reach the Mac, where it
        // cycles an application's windows. The Escape goes out without the
        // Command flag, so no ⌘` is ever delivered.
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.grave, shift: false,
                                    option: false, command: true),
                       .escapeWithoutCommand)
    }

    func testTheBacktickKeepsBothOfItsCharacters() {
        // This is what `escapeKey grave` had to buy with Shift and Option
        // rules, and what a chord gets for nothing.
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.grave, shift: false, option: false),
                       .unchanged, "a bare ` types a backtick")
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.grave, shift: true, option: false),
                       .unchanged, "⇧` types a tilde")
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.grave, shift: false, option: true),
                       .unchanged, "⌥` is whatever the Mac's layout says it is")
    }

    func testTheChordDoesNotClaimCapsLockOrGlobe() {
        XCTAssertFalse(chord.claimsCapsLock, "Caps Lock is a normal Caps Lock again")
        XCTAssertEqual(chord.switchInputSourceFrom, KeyboardMap.HID.globe)
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.globe, shift: false, option: false),
                       .switchInputSource)
        XCTAssertEqual(chord.action(for: KeyboardMap.HID.capsLock, shift: false, option: false),
                       .unchanged)
    }

    func testTheChordAndThePlainGraveRuleAreDifferentPlansForTheSameUsage() {
        // Both claim HID 0x35, so `escapeFrom` alone cannot say which applies —
        // which is what `graveRule` is for.
        let plain = KeyRemapPlan.resolve(escapeKey: .grave, globeKey: .none, languageKey: .none)
        XCTAssertEqual(plain.escapeFrom, chord.escapeFrom)
        XCTAssertEqual(plain.graveRule, .plainIsEscape)
        XCTAssertEqual(chord.graveRule, .commandChordIsEscape)
        XCTAssertEqual(plain.action(for: KeyboardMap.HID.grave, shift: false, option: false),
                       .escape)
        XCTAssertEqual(plain.action(for: KeyboardMap.HID.grave, shift: false,
                                    option: false, command: true),
                       .escape, "the old rule ignores Command, as it always did")
    }

    func testTheOtherEscapeSourcesAreUnaffectedByTheCommandArgument() {
        // `command:` defaults to false and must not change any existing answer.
        for source in [EscapeKeySource.globe, .capsLock] {
            let plan = KeyRemapPlan.resolve(escapeKey: source, globeKey: .none,
                                            languageKey: .none)
            let usage = source.hidUsage!
            XCTAssertEqual(plan.action(for: usage, shift: false, option: false), .escape)
            XCTAssertEqual(plan.action(for: usage, shift: false, option: false, command: true),
                           .escape)
            XCTAssertEqual(plan.graveRule, KeyRemapPlan.GraveRule.none)
        }
    }

    func testTheSummaryNamesTheChordRatherThanARawUsage() {
        // "Escape from HID 0x35" would be a lie: pressing HID 0x35 types a
        // backtick under this plan.
        XCTAssertTrue(chord.summary.contains("Command + HID 0x35"), chord.summary)
        XCTAssertTrue(chord.summary.contains("never reaches this Mac as"), chord.summary)
    }
}
