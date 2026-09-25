import CoreGraphics
import XCTest

/// HID usage -> macOS virtual keycode coverage, and the modifier-flag logic
/// (including the selectable Option-as-Command remap the fork adds).
final class KeyboardMapTests: XCTestCase {

    // MARK: - Keycode table

    func testLettersAndDigitsCoverTheWholeAlphanumericBlock() {
        // Every HID usage from A (0x04) to 0 (0x27) must map: a hole here is a
        // dead key on the user's keyboard.
        for usage in UInt16(0x04)...UInt16(0x27) {
            XCTAssertNotNil(KeyboardMap.macKeyCode(for: usage),
                            "HID usage \(String(usage, radix: 16)) has no keycode")
        }
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x04), 0x00)  // A
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x1D), 0x06)  // Z
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x1E), 0x12)  // 1
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x27), 0x1D)  // 0
    }

    func testPunctuationEditingFunctionRowNavigationAndKeypadAllMap() {
        // 0x28 Return … 0x64 ISO-section, minus 0x65 (Application/menu key,
        // which macOS genuinely has no keycode for) and 0x66 (Power).
        for usage in UInt16(0x28)...UInt16(0x64) {
            XCTAssertNotNil(KeyboardMap.macKeyCode(for: usage),
                            "HID usage \(String(usage, radix: 16)) has no keycode")
        }
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x28), 0x24)  // Return
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x2A), 0x33)  // Backspace
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x2B), 0x30)  // Tab
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x2C), 0x31)  // Space
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x35), 0x32)  // ` ~
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x38), 0x2C)  // / ?
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x3A), 0x7A)  // F1
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x45), 0x6F)  // F12
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x4A), 0x73)  // Home
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x4E), 0x79)  // Page Down
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x4C), 0x75)  // Forward Delete
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x58), 0x4C)  // Keypad Enter
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x62), 0x52)  // Keypad 0
    }

    func testArrowsAndTheTwoIsoOnlyKeys() {
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x4F), 0x7C)  // Right
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x50), 0x7B)  // Left
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x51), 0x7D)  // Down
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x52), 0x7E)  // Up
        // Non-US # (ISO, next to Return) shares backslash's keycode…
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x32), 0x2A)
        // …and Non-US \ (ISO, next to left Shift) is kVK_ISO_Section.
        XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x64), 0x0A)
    }

    func testUnmappableUsagesReturnNil() {
        XCTAssertNil(KeyboardMap.macKeyCode(for: 0x00))    // reserved / no event
        XCTAssertNil(KeyboardMap.macKeyCode(for: 0x01))    // ErrorRollOver
        XCTAssertNil(KeyboardMap.macKeyCode(for: 0x65))    // Application (menu)
        XCTAssertNil(KeyboardMap.macKeyCode(for: 0x80))    // Volume Up
        XCTAssertNil(KeyboardMap.macKeyCode(for: 0xFFFF))
    }

    func testEveryModifierMapsAndIsRecognisedAsOne() {
        let expected: [UInt16: CGKeyCode] = [
            0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37,
            0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36,
        ]
        for (usage, keyCode) in expected {
            XCTAssertEqual(KeyboardMap.macKeyCode(for: usage), keyCode)
            XCTAssertTrue(KeyboardMap.isModifier(usage))
        }
        XCTAssertFalse(KeyboardMap.isModifier(0x04))               // A
        XCTAssertFalse(KeyboardMap.isModifier(KeyboardMap.HID.capsLock))
    }

    // MARK: - Command key remap

    func testRemapRewritesTheKeycodeOfExactlyTheSelectedOptionKeys() {
        // Left Option 0xE2 -> kVK_Command 0x37, right Option 0xE6 ->
        // kVK_RightCommand 0x36 — the side is preserved, so a remapped key is
        // indistinguishable from the real Command key on that side.
        let expected: [CommandKeyRemap: (left: CGKeyCode, right: CGKeyCode)] = [
            CommandKeyRemap.none: (0x3A, 0x3D),   // kVK_Option, kVK_RightOption
            .leftOption:          (0x37, 0x3D),
            .rightOption:         (0x3A, 0x36),
            .bothOptions:         (0x37, 0x36),
        ]
        for (remap, keys) in expected {
            XCTAssertEqual(KeyboardMap.macKeyCode(for: 0xE2, commandKeyRemap: remap), keys.left,
                           "left Option under \(remap.rawValue)")
            XCTAssertEqual(KeyboardMap.macKeyCode(for: 0xE6, commandKeyRemap: remap), keys.right,
                           "right Option under \(remap.rawValue)")
            // Nothing else in the table may move.
            XCTAssertEqual(KeyboardMap.macKeyCode(for: 0x06, commandKeyRemap: remap), 0x08)  // C
            XCTAssertEqual(KeyboardMap.macKeyCode(for: 0xE3, commandKeyRemap: remap), 0x37)  // left ⌘
        }
    }

    func testRemapRewritesTheModifierFlagToo() {
        for remap in CommandKeyRemap.allCases {
            let left = KeyboardMap.flags(forModifier: 0xE2, commandKeyRemap: remap)
            XCTAssertEqual(left.contains(.maskCommand), remap.remapsLeftOption,
                           "left Option flag under \(remap.rawValue)")
            XCTAssertEqual(left.contains(.maskAlternate), !remap.remapsLeftOption)

            let right = KeyboardMap.flags(forModifier: 0xE6, commandKeyRemap: remap)
            XCTAssertEqual(right.contains(.maskCommand), remap.remapsRightOption,
                           "right Option flag under \(remap.rawValue)")
            XCTAssertEqual(right.contains(.maskAlternate), !remap.remapsRightOption)
        }
    }

    func testDeviceDependentBitsDistinguishLeftFromRight() {
        let left = KeyboardMap.flags(forModifier: 0xE1, commandKeyRemap: .rightOption)
        let right = KeyboardMap.flags(forModifier: 0xE5, commandKeyRemap: .rightOption)
        XCTAssertTrue(left.contains(.maskShift))
        XCTAssertTrue(right.contains(.maskShift))
        XCTAssertNotEqual(left, right, "left and right Shift must not be the same flag set")
        // A remapped Option must be byte-identical to the real Command key on
        // its own side, device-dependent bits included.
        XCTAssertEqual(KeyboardMap.flags(forModifier: 0xE6, commandKeyRemap: .rightOption),
                       KeyboardMap.flags(forModifier: 0xE7, commandKeyRemap: CommandKeyRemap.none))
        XCTAssertEqual(KeyboardMap.flags(forModifier: 0xE2, commandKeyRemap: .leftOption),
                       KeyboardMap.flags(forModifier: 0xE3, commandKeyRemap: CommandKeyRemap.none))
        // …and not to the *other* side's Command.
        XCTAssertNotEqual(KeyboardMap.flags(forModifier: 0xE2, commandKeyRemap: .leftOption),
                          KeyboardMap.flags(forModifier: 0xE6, commandKeyRemap: .rightOption))
    }

    // MARK: - Defaults precedence

    func testCommandKeyRemapWinsOverTheLegacyBoolean() {
        for value in CommandKeyRemap.allCases {
            XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: value.rawValue,
                                                   legacyRemapRightOption: nil), value)
            // The legacy key is ignored entirely whenever the new one is set,
            // in both directions.
            XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: value.rawValue,
                                                   legacyRemapRightOption: true), value)
            XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: value.rawValue,
                                                   legacyRemapRightOption: false), value)
        }
    }

    func testLegacyBooleanIsHonouredWhenTheNewKeyIsAbsent() {
        XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: nil,
                                               legacyRemapRightOption: true), .rightOption)
        XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: nil,
                                               legacyRemapRightOption: false), CommandKeyRemap.none)
    }

    func testBothKeysAbsentPreservesTheForksOriginalBehaviour() {
        XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: nil,
                                               legacyRemapRightOption: nil), .rightOption)
        XCTAssertEqual(CommandKeyRemap.fallback, .rightOption)
    }

    func testAnUnrecognizedStringFallsThroughRatherThanDisablingTheRemap() {
        // A typo must not silently take the Command stand-in away: on a
        // keyboard-driven session that is the more surprising failure.
        XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: "LeftOption",
                                               legacyRemapRightOption: nil), .rightOption)
        XCTAssertEqual(CommandKeyRemap.resolve(commandKeyRemap: "",
                                               legacyRemapRightOption: false), CommandKeyRemap.none)
    }

    func testRemapsToCommandOnlyEverAnswersForOptionKeys() {
        XCTAssertTrue(CommandKeyRemap.bothOptions.remapsToCommand(0xE2))
        XCTAssertTrue(CommandKeyRemap.bothOptions.remapsToCommand(0xE6))
        XCTAssertFalse(CommandKeyRemap.bothOptions.remapsToCommand(0xE3))  // real ⌘
        XCTAssertFalse(CommandKeyRemap.bothOptions.remapsToCommand(0x04))  // A
        XCTAssertFalse(CommandKeyRemap.none.remapsToCommand(0xE2))
        XCTAssertFalse(CommandKeyRemap.none.remapsToCommand(0xE6))
    }

    // MARK: - UIKeyModifierFlags translation

    func testEventFlagsTranslatesEveryUIKitBit() {
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiShift).contains(.maskShift))
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiControl).contains(.maskControl))
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiAlternate).contains(.maskAlternate))
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiCommand).contains(.maskCommand))
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiAlphaShift).contains(.maskAlphaShift))
        XCTAssertTrue(KeyboardMap.eventFlags(for: KeyboardMap.uiNumericPad).contains(.maskNumericPad))
        XCTAssertEqual(KeyboardMap.eventFlags(for: 0), [])
    }

    // MARK: - ModifierKeyState

    func testHeldModifiersProduceFlagsAndAreReleasedAgain() {
        var state = ModifierKeyState()
        state.update(hidUsage: 0xE1, down: true)   // left Shift
        var flags = state.flags(reported: 0, includeReported: false,
                                commandKeyRemap: .rightOption)
        XCTAssertTrue(flags.contains(.maskShift))

        state.update(hidUsage: 0xE1, down: false)
        flags = state.flags(reported: 0, includeReported: false,
                            commandKeyRemap: .rightOption)
        XCTAssertFalse(flags.contains(.maskShift))
        XCTAssertTrue(state.held.isEmpty)
    }

    /// The scenario the whole feature exists for: an Option key plus C must
    /// reach the Mac as ⌘C and not as ⌥C (which types a dead-key "ç"). UIKit
    /// reports `.alternate` for *either* Option key, which is the input that
    /// used to leak an Option flag through the remap.
    private func optionComboFlags(option usage: UInt16,
                                  remap: CommandKeyRemap) -> CGEventFlags {
        var state = ModifierKeyState()
        state.update(hidUsage: usage, down: true)
        return state.flags(reported: KeyboardMap.uiAlternate,
                           includeReported: true,
                           commandKeyRemap: remap)
    }

    func testLeftOptionIsCommandUnderLeftOptionAndRightOptionIsNot() {
        let left = optionComboFlags(option: 0xE2, remap: .leftOption)
        XCTAssertTrue(left.contains(.maskCommand))
        XCTAssertFalse(left.contains(.maskAlternate))

        let right = optionComboFlags(option: 0xE6, remap: .leftOption)
        XCTAssertTrue(right.contains(.maskAlternate), "right Option still types ⌥ combos")
        XCTAssertFalse(right.contains(.maskCommand))
    }

    func testRightOptionIsCommandUnderRightOptionAndLeftOptionIsNot() {
        let right = optionComboFlags(option: 0xE6, remap: .rightOption)
        XCTAssertTrue(right.contains(.maskCommand))
        XCTAssertFalse(right.contains(.maskAlternate))

        let left = optionComboFlags(option: 0xE2, remap: .rightOption)
        XCTAssertTrue(left.contains(.maskAlternate), "left Option still types ⌥ combos")
        XCTAssertFalse(left.contains(.maskCommand))
    }

    func testBothOptionKeysAreCommandUnderBothOptions() {
        for usage in [UInt16(0xE2), UInt16(0xE6)] {
            let flags = optionComboFlags(option: usage, remap: .bothOptions)
            XCTAssertTrue(flags.contains(.maskCommand), "usage \(String(usage, radix: 16))")
            XCTAssertFalse(flags.contains(.maskAlternate), "usage \(String(usage, radix: 16))")
        }
    }

    func testNoneLeavesBothOptionKeysAsOption() {
        for usage in [UInt16(0xE2), UInt16(0xE6)] {
            let flags = optionComboFlags(option: usage, remap: CommandKeyRemap.none)
            XCTAssertTrue(flags.contains(.maskAlternate), "usage \(String(usage, radix: 16))")
            XCTAssertFalse(flags.contains(.maskCommand), "usage \(String(usage, radix: 16))")
        }
    }

    func testANonRemappedOptionHeldAlongsideARemappedOneKeepsBothFlags() {
        // Both Option keys down, only one of them remapped: the reported
        // `.alternate` bit is genuinely earned by the other key, so it must
        // survive — and the remapped one still contributes Command.
        for remap in [CommandKeyRemap.leftOption, .rightOption] {
            var state = ModifierKeyState()
            state.update(hidUsage: 0xE2, down: true)
            state.update(hidUsage: 0xE6, down: true)
            let flags = state.flags(reported: KeyboardMap.uiAlternate,
                                    includeReported: true,
                                    commandKeyRemap: remap)
            XCTAssertTrue(flags.contains(.maskAlternate),
                          "the non-remapped Option is genuinely down under \(remap.rawValue)")
            XCTAssertTrue(flags.contains(.maskCommand),
                          "the remapped Option is still Command under \(remap.rawValue)")
        }
    }

    func testTheReportedOptionBitSurvivesWhenNoOptionKeyIsTracked() {
        // An Option pressed while the video view was not first responder is
        // only ever reported, never tracked. Nothing may normalize it away —
        // there is no remapped key to attribute it to.
        var state = ModifierKeyState()
        state.update(hidUsage: 0xE1, down: true)   // left Shift, not an Option
        let flags = state.flags(reported: KeyboardMap.uiAlternate,
                                includeReported: true,
                                commandKeyRemap: .bothOptions)
        XCTAssertTrue(flags.contains(.maskAlternate))
        XCTAssertFalse(flags.contains(.maskCommand))
    }

    func testModifierEventsIgnoreTheReportedFlagsButCapsLockIsAlwaysTaken() {
        var state = ModifierKeyState()
        // A modifier's own event: UIKit may still be reporting the key that is
        // being released, so only the tracked set counts.
        state.update(hidUsage: 0xE3, down: false)
        let flags = state.flags(reported: KeyboardMap.uiCommand | KeyboardMap.uiAlphaShift,
                                includeReported: false,
                                commandKeyRemap: .rightOption)
        XCTAssertFalse(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskAlphaShift), "Caps Lock is a latch, never a held key")
    }

    func testLatchedSidebarOptionSurvivesTheCommandRemap() {
        // Regression (review #8): sticky flags used to be folded in *before*
        // the Option normalization, so with ⌥ latched on screen and a remapped
        // Option physically held, the removal of `.maskAlternate` deleted the
        // user's deliberate virtual Option and left only Command. Still true
        // for whichever side the remap now applies to.
        for (remap, usage) in [(CommandKeyRemap.leftOption, UInt16(0xE2)),
                               (.rightOption, UInt16(0xE6)),
                               (.bothOptions, UInt16(0xE2))] {
            var state = ModifierKeyState()
            state.update(hidUsage: usage, down: true)
            let flags = state.flags(reported: KeyboardMap.uiAlternate,
                                    includeReported: true,
                                    commandKeyRemap: remap,
                                    sticky: [.maskAlternate])
            XCTAssertTrue(flags.contains(.maskCommand),
                          "the remapped Option is still Command under \(remap.rawValue)")
            XCTAssertTrue(flags.contains(.maskAlternate),
                          "the latched Option must survive under \(remap.rawValue)")
        }
    }

    func testStickyModifiersFromTheOnScreenSidebarAreUnioned() {
        var state = ModifierKeyState()
        state.update(hidUsage: 0xE1, down: true)
        let flags = state.flags(reported: 0, includeReported: true,
                                commandKeyRemap: .rightOption,
                                sticky: [.maskCommand])
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertTrue(flags.contains(.maskCommand))
    }
}
