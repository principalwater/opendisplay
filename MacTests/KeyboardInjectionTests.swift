import CoreGraphics
import XCTest

/// End-to-end of the Mac keyboard path: what `InputInjector.handleKey` actually
/// puts on the wire to the Window Server. Everything runs against a
/// `RecordingEventSink`, so no keystroke reaches the real desktop.
final class KeyboardInjectionTests: XCTestCase {

    private var sink: RecordingEventSink!
    private var scheduler: ManualRepeatScheduler!

    /// Manual scheduler so repeats are deterministic (no sleeping in tests).
    final class ManualRepeatScheduler: KeyRepeatScheduling {
        private var fire: (() -> Void)?
        /// Kept after cancelling so a test can fire the tick that was already
        /// in flight when the key was released — `DispatchSourceTimer.cancel()`
        /// does not wait for a running handler either.
        private var cancelledFire: (() -> Void)?
        private(set) var cancels = 0
        var isRunning: Bool { fire != nil }
        func start(delay: TimeInterval, interval: TimeInterval, fire: @escaping () -> Void) {
            self.fire = fire
        }
        func cancel() {
            if fire != nil { cancels += 1; cancelledFire = fire }
            fire = nil
        }
        func tick(_ n: Int = 1) { for _ in 0..<n { fire?() } }
        func tickAfterCancel() { cancelledFire?() }
    }

    private func makeInjector(remap: CommandKeyRemap = .rightOption,
                              escapeKey: EscapeKeySource = .fallback) -> InputInjector {
        sink = RecordingEventSink()
        scheduler = ManualRepeatScheduler()
        return InputInjector(displayID: CGMainDisplayID(), sink: sink,
                             commandKeyRemap: remap,
                             keyRemapPlan: KeyRemapPlan.resolve(escapeKey: escapeKey,
                                                                globeKey: .switchLanguage,
                                                                languageKey: .none),
                             keyRepeat: KeyRepeatController(scheduler: scheduler,
                                                            delay: { 0.4 }, interval: { 0.05 }))
    }

    // MARK: - Ordinary keys

    func testLetterProducesAKeyDownAndKeyUpOnTheMappedKeycode() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: 0, characters: "a")
        injector.handleKey(hidUsage: 0x04, down: false, rawModifiers: 0, characters: "a")

        XCTAssertEqual(sink.events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(sink.events.map(\.keyCode), [0x00, 0x00])
    }

    func testNoUnicodeStringIsAttachedToAMappedKey() {
        // The whole point of forwarding keycodes: the Mac's own input source
        // decides the character, so a Russian layout on the Mac produces "ф"
        // from the same key that the iPad called "a". Attaching the iPad's
        // character (as #247 did) pins the output to the iPad's layout.
        let injector = makeInjector()
        // A character no keyboard layout can produce from keycode 0x00, so the
        // assertion holds whatever input source the test machine happens to
        // have selected. CGEvent fills the unicode field from the keycode by
        // itself; what must not happen is us overwriting it with the iPad's.
        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: 0, characters: "☃")
        XCTAssertNotEqual(sink.events.first?.unicode, "☃",
                          "a mapped key must not carry a character override")
    }

    func testUnknownUsageFallsBackToTypingTheCharacters() {
        let injector = makeInjector()
        // 0x65 (Application/menu) has no macOS keycode.
        injector.handleKey(hidUsage: 0x65, down: true, rawModifiers: 0, characters: "≈")
        XCTAssertEqual(sink.events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(sink.events.first?.unicode, "≈")
        // The key-up message adds nothing: the pair was already emitted.
        injector.handleKey(hidUsage: 0x65, down: false, rawModifiers: 0, characters: "≈")
        XCTAssertEqual(sink.events.count, 2)
    }

    func testUnicodeFallbackIsSuppressedUnderCommandOrControl() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE3, down: true)   // left Command
        sink.reset()
        injector.handleKey(hidUsage: 0x65, down: true, rawModifiers: KeyboardMap.uiCommand,
                           characters: "≈")
        XCTAssertTrue(sink.events.isEmpty,
                      "typing on virtual key 0 under ⌘ would fire a bogus ⌘A")
    }

    // MARK: - Modifiers

    func testModifiersAreInjectedAsFlagsChangedNotKeyDown() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE1, down: true)    // left Shift
        XCTAssertEqual(sink.events.first?.type, .flagsChanged)
        XCTAssertEqual(sink.events.first?.keyCode, 0x38)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskShift) ?? false)

        injector.handleKey(hidUsage: 0xE1, down: false)
        XCTAssertEqual(sink.events.last?.type, .flagsChanged)
        XCTAssertFalse(sink.events.last?.flags.contains(.maskShift) ?? true)
    }

    func testHeldShiftStampsTheFollowingKey() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE1, down: true)
        sink.reset()
        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: KeyboardMap.uiShift)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskShift) ?? false)
    }

    func testTouchSnapshotReleasesARemappedCommandWhoseKeyUpWasLost() {
        let injector = makeInjector(remap: .leftOption)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        sink.reset()

        injector.reconcileModifiers(reported: 0)

        XCTAssertEqual(sink.events.map(\.type), [.flagsChanged])
        XCTAssertEqual(sink.events.first?.keyCode, 0x37)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
        sink.reset()
        injector.handleKey(hidUsage: 0x04, down: true)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
    }

    func testTouchSnapshotKeepsAModifierStillHeldForModifiedClick() {
        let injector = makeInjector(remap: .leftOption)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        sink.reset()

        injector.reconcileModifiers(reported: KeyboardMap.uiAlternate)

        XCTAssertTrue(sink.events.isEmpty)
        injector.handleKey(hidUsage: 0x04, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskCommand) ?? false)
    }

    func testTouchSnapshotKeepsReportedCapsLockWhenReleasingLostModifier() {
        let injector = makeInjector(remap: .leftOption)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true)
        sink.reset()

        injector.reconcileModifiers(reported: KeyboardMap.uiAlphaShift)

        XCTAssertEqual(sink.events.map(\.type), [.flagsChanged])
        XCTAssertTrue(sink.events.first?.flags.contains(.maskAlphaShift) ?? false)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
    }

    func testSwappedLeftModifiersProduceCommandOptionArrow() {
        let injector = makeInjector(remap: .swapLeftOptionCommand)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftCommand, down: true,
                           rawModifiers: KeyboardMap.uiAlternate | KeyboardMap.uiCommand)
        sink.reset()

        injector.handleKey(hidUsage: 0x4F, down: true,
                           rawModifiers: KeyboardMap.uiAlternate | KeyboardMap.uiCommand)

        XCTAssertEqual(sink.events.first?.keyCode, 0x7C)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskCommand) ?? false)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskAlternate) ?? false)
    }

    func testControlGraveLeavesCommandGraveForWindowCycling() {
        let injector = makeInjector(remap: .swapLeftOptionCommand, escapeKey: .controlGrave)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        sink.reset()
        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        XCTAssertEqual(sink.events.first?.keyCode, 0x32)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskCommand) ?? false)

        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: false,
                           rawModifiers: KeyboardMap.uiAlternate)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: false)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftControl, down: true,
                           rawModifiers: KeyboardMap.uiControl)
        sink.reset()
        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: true,
                           rawModifiers: KeyboardMap.uiControl)
        XCTAssertEqual(sink.events.map(\.keyCode), [0x35, 0x35])
        XCTAssertTrue(sink.events.allSatisfy { !$0.flags.contains(.maskControl) })
    }

    func testLostEscapeChordReleaseCannotSwallowANewBacktickRelease() {
        let injector = makeInjector(remap: .leftOption, escapeKey: .leftCommandGrave)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: true)
        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: true,
                           rawModifiers: KeyboardMap.uiAlternate)
        injector.handleKey(hidUsage: KeyboardMap.HID.leftOption, down: false)
        sink.reset()

        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: true)
        injector.handleKey(hidUsage: KeyboardMap.HID.grave, down: false)

        XCTAssertEqual(sink.events.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(sink.events.map(\.keyCode), [0x32, 0x32])
    }

    func testCapsLockIsCarriedAsAFlagAndNotInjectedAsAKey() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: KeyboardMap.HID.capsLock, down: true,
                           rawModifiers: KeyboardMap.uiAlphaShift)
        XCTAssertTrue(sink.events.isEmpty, "Caps Lock must not toggle the Mac's own latch")

        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: KeyboardMap.uiAlphaShift)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskAlphaShift) ?? false)
    }

    // MARK: - Command key remap

    /// left Option 0xE2 / right Option 0xE6 -> the Command key on that side,
    /// with the keycode and the device-dependent flag bit of a *real* Command.
    func testARemappedOptionKeyArrivesAsTheCommandKeyOnItsOwnSide() {
        let cases: [(CommandKeyRemap, UInt16, CGKeyCode)] = [
            (.leftOption, 0xE2, 0x37),    // kVK_Command
            (.rightOption, 0xE6, 0x36),   // kVK_RightCommand
            (.bothOptions, 0xE2, 0x37),
            (.bothOptions, 0xE6, 0x36),
        ]
        for (remap, usage, keyCode) in cases {
            let injector = makeInjector(remap: remap)
            injector.handleKey(hidUsage: usage, down: true, rawModifiers: KeyboardMap.uiAlternate)
            let event = sink.events.first
            let label = "usage \(String(usage, radix: 16)) under \(remap.rawValue)"
            XCTAssertEqual(event?.type, .flagsChanged, label)
            XCTAssertEqual(event?.keyCode, keyCode, label)
            XCTAssertTrue(event?.flags.contains(.maskCommand) ?? false, label)
            XCTAssertFalse(event?.flags.contains(.maskAlternate) ?? true, label)
            // The device-dependent bit must be the one a real Command on that
            // side would carry — otherwise apps that look can tell them apart.
            let realCommand = KeyboardMap.flags(forModifier: usage == 0xE2 ? 0xE3 : 0xE7,
                                                commandKeyRemap: CommandKeyRemap.none)
            XCTAssertEqual(event?.flags, realCommand, label)
        }
    }

    func testARemappedOptionPlusCIsACommandCombo() {
        // ⌘C, not ⌥C. The reported `.alternate` bit is the same key seen a
        // second time and must not survive.
        let cases: [(CommandKeyRemap, UInt16)] = [
            (.leftOption, 0xE2), (.rightOption, 0xE6),
            (.bothOptions, 0xE2), (.bothOptions, 0xE6),
        ]
        for (remap, usage) in cases {
            let injector = makeInjector(remap: remap)
            injector.handleKey(hidUsage: usage, down: true, rawModifiers: KeyboardMap.uiAlternate)
            sink.reset()
            injector.handleKey(hidUsage: 0x06, down: true, rawModifiers: KeyboardMap.uiAlternate)
            let event = sink.events.first
            let label = "usage \(String(usage, radix: 16)) under \(remap.rawValue)"
            XCTAssertEqual(event?.keyCode, 0x08, "C — \(label)")
            XCTAssertTrue(event?.flags.contains(.maskCommand) ?? false, "must be ⌘C — \(label)")
            XCTAssertFalse(event?.flags.contains(.maskAlternate) ?? true, "…and not ⌥C — \(label)")
        }
    }

    func testTheNonRemappedOptionStillTypesOptionCombos() {
        // Under a one-sided remap the other Option key is untouched: keycode,
        // flag and the ⌥C it produces.
        let cases: [(CommandKeyRemap, UInt16, CGKeyCode)] = [
            (.leftOption, 0xE6, 0x3D),    // kVK_RightOption
            (.rightOption, 0xE2, 0x3A),   // kVK_Option
        ]
        for (remap, usage, keyCode) in cases {
            let injector = makeInjector(remap: remap)
            injector.handleKey(hidUsage: usage, down: true, rawModifiers: KeyboardMap.uiAlternate)
            let label = "usage \(String(usage, radix: 16)) under \(remap.rawValue)"
            XCTAssertEqual(sink.events.first?.keyCode, keyCode, label)
            XCTAssertTrue(sink.events.first?.flags.contains(.maskAlternate) ?? false, label)
            sink.reset()
            injector.handleKey(hidUsage: 0x06, down: true, rawModifiers: KeyboardMap.uiAlternate)
            XCTAssertTrue(sink.events.first?.flags.contains(.maskAlternate) ?? false, label)
            XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true, label)
        }
    }

    func testNoneLeavesBothOptionKeysAlone() {
        for (usage, keyCode) in [(UInt16(0xE2), CGKeyCode(0x3A)), (UInt16(0xE6), CGKeyCode(0x3D))] {
            let injector = makeInjector(remap: CommandKeyRemap.none)
            injector.handleKey(hidUsage: usage, down: true, rawModifiers: KeyboardMap.uiAlternate)
            let label = "usage \(String(usage, radix: 16))"
            XCTAssertEqual(sink.events.first?.keyCode, keyCode, label)
            XCTAssertTrue(sink.events.first?.flags.contains(.maskAlternate) ?? false, label)
            XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true, label)
        }
    }

    func testHoldingBothOptionsUnderAOneSidedRemapKeepsOptionAndAddsCommand() {
        let injector = makeInjector(remap: .rightOption)
        injector.handleKey(hidUsage: 0xE2, down: true, rawModifiers: KeyboardMap.uiAlternate)
        injector.handleKey(hidUsage: 0xE6, down: true, rawModifiers: KeyboardMap.uiAlternate)
        sink.reset()
        injector.handleKey(hidUsage: 0x06, down: true, rawModifiers: KeyboardMap.uiAlternate)
        let flags = sink.events.first?.flags
        XCTAssertTrue(flags?.contains(.maskAlternate) ?? false, "left Option is genuinely down")
        XCTAssertTrue(flags?.contains(.maskCommand) ?? false, "right Option is Command")
    }

    // MARK: - Auto-repeat

    func testHeldKeyRepeatsUntilReleased() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x2A, down: true)      // Backspace
        XCTAssertTrue(scheduler.isRunning)
        sink.reset()

        scheduler.tick(3)
        XCTAssertEqual(sink.events.count, 3)
        XCTAssertTrue(sink.events.allSatisfy { $0.type == .keyDown && $0.keyCode == 0x33 })
        XCTAssertTrue(sink.events.allSatisfy(\.isAutorepeat),
                      "repeats must be flagged, or apps treat each as a fresh press")

        injector.handleKey(hidUsage: 0x2A, down: false)
        XCTAssertFalse(scheduler.isRunning)
    }

    func testRepeatsPickUpModifiersPressedWhileTheKeyIsHeld() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x04, down: true)
        injector.handleKey(hidUsage: 0xE1, down: true)      // Shift joins mid-hold
        sink.reset()
        scheduler.tick()
        XCTAssertTrue(sink.events.first?.flags.contains(.maskShift) ?? false)
    }

    func testATickAlreadyInFlightCannotLandAfterTheKeyUp() {
        // The race: the timer fires, the handler starts, and the release
        // arrives before the handler reaches the lock. Without the generation
        // token this produced keyDown → keyUp → autorepeat keyDown, i.e. a key
        // the Mac believes is still held, with nothing left to release it.
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x2A, down: true)       // Backspace down
        injector.handleKey(hidUsage: 0x2A, down: false)      // …and up
        sink.reset()

        scheduler.tickAfterCancel()
        XCTAssertTrue(sink.events.isEmpty, "a cancelled tick must not post")
    }

    func testATickAlreadyInFlightCannotLandAfterReset() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x2A, down: true)
        injector.reset()
        sink.reset()

        scheduler.tickAfterCancel()
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testASupersededKeysTickCannotLandEither() {
        // Hold A, press B: B owns the repeat. A tick from A's cancelled timer
        // must not type an A.
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x04, down: true)       // A
        injector.handleKey(hidUsage: 0x05, down: true)       // B takes over
        sink.reset()

        scheduler.tickAfterCancel()
        XCTAssertTrue(sink.events.isEmpty)

        scheduler.tick()
        XCTAssertEqual(sink.events.map(\.keyCode), [0x0B], "only B repeats")
    }

    func testModifiersDoNotRepeat() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE3, down: true)
        XCTAssertFalse(scheduler.isRunning)
    }

    // MARK: - Reset

    func testResetReleasesTheHeldKeyAndEveryHeldModifier() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE3, down: true)      // left Command down
        injector.handleKey(hidUsage: 0xE1, down: true)      // left Shift down
        injector.handleKey(hidUsage: 0x04, down: true)      // A held (repeating)
        sink.reset()

        injector.reset()

        XCTAssertFalse(scheduler.isRunning, "a disconnect must stop the repeat timer")
        let keyUps = sink.events.filter { $0.type == .keyUp }
        XCTAssertEqual(keyUps.map(\.keyCode), [0x00], "the held key is released")
        let flagChanges = sink.events.filter { $0.type == .flagsChanged }
        XCTAssertEqual(flagChanges.count, 2, "both held modifiers are released")
        XCTAssertEqual(flagChanges.last?.flags, [], "nothing is left held")
    }

    func testResetReleasesEveryHeldKeyNotJustTheRepeater() {
        // Hold A, then B, then C. C owns the repeat; A and B are still down as
        // far as the Window Server is concerned. Releasing only the repeater
        // left the other two stuck for the rest of the login session.
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x04, down: true)       // A -> 0x00
        injector.handleKey(hidUsage: 0x05, down: true)       // B -> 0x0B
        injector.handleKey(hidUsage: 0x06, down: true)       // C -> 0x08
        sink.reset()

        injector.reset()

        let keyUps = sink.events.filter { $0.type == .keyUp }.map(\.keyCode)
        XCTAssertEqual(Set(keyUps), [0x00, 0x0B, 0x08])
        XCTAssertFalse(scheduler.isRunning)
    }

    func testReleasingOneOfSeveralHeldKeysLeavesTheOthersHeld() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0x04, down: true)
        injector.handleKey(hidUsage: 0x05, down: true)
        injector.handleKey(hidUsage: 0x04, down: false)      // release A only
        sink.reset()

        injector.reset()
        let keyUps = sink.events.filter { $0.type == .keyUp }.map(\.keyCode)
        XCTAssertEqual(keyUps, [0x0B], "only B was still held")
    }

    func testStateDoesNotLeakAcrossAReset() {
        let injector = makeInjector()
        injector.handleKey(hidUsage: 0xE3, down: true)
        injector.reset()
        sink.reset()
        // Without the reset clearing the tracked modifiers, this plain "a"
        // would arrive as ⌘A and (say) select-all in whatever app has focus.
        injector.handleKey(hidUsage: 0x04, down: true)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
    }

    func testStickyFlagsAreNotStampedOnPhysicalModifierTransitions() {
        // A `.flagsChanged` carrying a modifier the Window Server was never
        // told went down is a lie; the next real modifier release would look
        // like that virtual one going up too.
        let injector = makeInjector()
        injector.setStickyModifiers(KeyboardMap.uiCommand)
        injector.handleKey(hidUsage: 0xE1, down: true)      // physical Shift
        XCTAssertEqual(sink.events.first?.type, .flagsChanged)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskShift) ?? false)

        // …but the key it modifies still gets both.
        sink.reset()
        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: KeyboardMap.uiShift)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskCommand) ?? false)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskShift) ?? false)
    }

    func testStickyModifiersFromTheSidebarApplyAndClearOnReset() {
        let injector = makeInjector()
        injector.setStickyModifiers(KeyboardMap.uiCommand)
        injector.handleKey(hidUsage: 0x06, down: true)
        XCTAssertTrue(sink.events.first?.flags.contains(.maskCommand) ?? false)

        injector.reset()
        sink.reset()
        injector.handleKey(hidUsage: 0x06, down: true)
        XCTAssertFalse(sink.events.first?.flags.contains(.maskCommand) ?? true)
    }
}
