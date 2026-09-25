import CoreGraphics
import XCTest

/// Every case builds its injector on a `RecordingEventSink`: upstream created
/// them on the real HID tap, so running the suite typed and clicked on the
/// tester's live desktop.
///
/// Merged suite: the two upstream InputInjector test suites that landed as an
/// add/add conflict — PR #247 (HID keycode mapping, modifier flags, tilt math)
/// and PR #216 (touch / right-click / pencil state machine, reset). Every case
/// from both PRs is kept; no assertion was dropped.
final class InputInjectorTests: XCTestCase {

    // MARK: - From upstream PR #247 (hardware keyboard passthrough)

    func testHIDUsageToMacKeyCodeMapping() {
        // Letters
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x04), 0x00) // A
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x05), 0x0B) // B
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x06), 0x08) // C
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x07), 0x02) // D
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x1D), 0x06) // Z

        // Numbers
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x1E), 0x12) // 1
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x27), 0x1D) // 0

        // Functional
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x28), 0x24) // Return
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x29), 0x35) // Escape
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x2A), 0x33) // Delete
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x2B), 0x30) // Tab
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x2C), 0x31) // Space

        // Arrows
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x4F), 0x7C) // Right
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x50), 0x7B) // Left
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x51), 0x7D) // Down
        XCTAssertEqual(InputInjector.macKeyCode(for: 0x52), 0x7E) // Up

        // Modifiers
        XCTAssertEqual(InputInjector.macKeyCode(for: 0xE0), 0x3B) // L-Ctrl
        XCTAssertEqual(InputInjector.macKeyCode(for: 0xE1), 0x38) // L-Shift
        XCTAssertEqual(InputInjector.macKeyCode(for: 0xE2), 0x3A) // L-Option
        XCTAssertEqual(InputInjector.macKeyCode(for: 0xE3), 0x37) // L-Cmd

        // Unknown
        XCTAssertNil(InputInjector.macKeyCode(for: 0xFFFF))
    }

    func testEventFlagsTranslation() {
        let shiftRaw: UInt = 1 << 17
        let ctrlRaw: UInt = 1 << 18
        let optRaw: UInt = 1 << 19
        let cmdRaw: UInt = 1 << 20

        XCTAssertTrue(InputInjector.eventFlags(for: shiftRaw).contains(.maskShift))
        XCTAssertTrue(InputInjector.eventFlags(for: ctrlRaw).contains(.maskControl))
        XCTAssertTrue(InputInjector.eventFlags(for: optRaw).contains(.maskAlternate))
        XCTAssertTrue(InputInjector.eventFlags(for: cmdRaw).contains(.maskCommand))

        let combined = InputInjector.eventFlags(for: shiftRaw | cmdRaw)
        XCTAssertTrue(combined.contains(.maskShift))
        XCTAssertTrue(combined.contains(.maskCommand))
        XCTAssertFalse(combined.contains(.maskAlternate))
    }

    func testStickyModifiersCombination() {
        let sticky: CGEventFlags = [.maskCommand]
        let shiftRaw: UInt = 1 << 17
        let result = InputInjector.eventFlags(for: shiftRaw, sticky: sticky)
        XCTAssertTrue(result.contains(.maskShift))
        XCTAssertTrue(result.contains(.maskCommand))
    }

    func testKeyInjectionSmoke() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        injector.handleKey(hidUsage: 0x04, down: true, rawModifiers: 0, characters: "a")
        injector.handleKey(hidUsage: 0x04, down: false, rawModifiers: 0, characters: "a")

        injector.setStickyModifiers(1 << 20) // Command
        injector.handleKey(hidUsage: 0x06, down: true, rawModifiers: 0, characters: "c")
        injector.handleKey(hidUsage: 0x06, down: false, rawModifiers: 0, characters: "c")
    }

    func testTiltMathVector() {
        let upright = InputInjector.tiltVector(altitude: .pi / 2, azimuth: 0)
        XCTAssertEqual(upright.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(upright.y, 0.0, accuracy: 1e-6)

        let flatUp = InputInjector.tiltVector(altitude: 0, azimuth: 0)
        XCTAssertEqual(flatUp.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(flatUp.y, 1.0, accuracy: 1e-6)

        let flatRight = InputInjector.tiltVector(altitude: 0, azimuth: .pi / 2)
        XCTAssertEqual(flatRight.x, 1.0, accuracy: 1e-6)
        XCTAssertEqual(flatRight.y, 0.0, accuracy: 1e-6)

        let overPitched = InputInjector.tiltVector(altitude: 2.0, azimuth: 0)
        XCTAssertEqual(overPitched.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(overPitched.y, 0.0, accuracy: 1e-6)
    }

    func testTouchAndScrollHandling() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        injector.handleTouch(phase: "moved", x: 0.6, y: 0.6)
        injector.handleTouch(phase: "ended", x: 0.6, y: 0.6)
        injector.handleScroll(dx: 10, dy: -20)
    }

    // MARK: - From upstream PR #216 (right click, multi-click timing)

    func testDeriveTiltMath() {
        // Upright pen (altitude = pi/2)
        let (tiltX1, tiltY1) = InputInjector.deriveTilt(azimuth: 0, altitude: Double.pi / 2)
        XCTAssertEqual(tiltX1, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY1, 0, accuracy: 1e-5)

        // Flat pen facing right (azimuth = pi/2, altitude = 0)
        let (tiltX2, tiltY2) = InputInjector.deriveTilt(azimuth: Double.pi / 2, altitude: 0)
        XCTAssertEqual(tiltX2, 1.0, accuracy: 1e-5)
        XCTAssertEqual(tiltY2, 0, accuracy: 1e-5)

        // Flat pen facing up (azimuth = 0, altitude = 0)
        let (tiltX3, tiltY3) = InputInjector.deriveTilt(azimuth: 0, altitude: 0)
        XCTAssertEqual(tiltX3, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY3, 1.0, accuracy: 1e-5)

        // Altitude clamping (> pi/2 or < 0)
        let (tiltX4, tiltY4) = InputInjector.deriveTilt(azimuth: Double.pi / 4, altitude: Double.pi)
        XCTAssertEqual(tiltX4, 0, accuracy: 1e-5)
        XCTAssertEqual(tiltY4, 0, accuracy: 1e-5)
    }

    func testTouchStateMachine() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        XCTAssertFalse(injector.isDown)

        injector.handleTouch(phase: "began", x: 0.5, y: 0.5)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "moved", x: 0.6, y: 0.6)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "ended", x: 0.6, y: 0.6)
        XCTAssertFalse(injector.isDown)
    }

    func testRightClickHandling() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        XCTAssertFalse(injector.isDown)

        injector.handleTouch(phase: "began", x: 0.3, y: 0.3, button: "right")
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "moved", x: 0.35, y: 0.35, button: "right")
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "ended", x: 0.35, y: 0.35, button: "right")
        XCTAssertFalse(injector.isDown)
    }

    func testTouchCancelled() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        injector.handleTouch(phase: "began", x: 0.4, y: 0.4)
        XCTAssertTrue(injector.isDown)

        injector.handleTouch(phase: "cancelled", x: 0.4, y: 0.4)
        XCTAssertFalse(injector.isDown)
    }

    func testPencilStateMachineAndProximity() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        XCTAssertFalse(injector.penDown)
        XCTAssertFalse(injector.inRange)

        injector.handlePencil(phase: "down", x: 0.2, y: 0.2, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handlePencil(phase: "move", x: 0.25, y: 0.25, pressure: 0.8, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.penDown)

        injector.handlePencil(phase: "up", x: 0.25, y: 0.25, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertFalse(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handlePencil(phase: "hover", x: 0.3, y: 0.3, pressure: 0, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertFalse(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.handleProximity(entering: false, x: 0.3, y: 0.3)
        XCTAssertFalse(injector.inRange)
    }

    func testResetCleansUpAllState() {
        let injector = InputInjector(displayID: CGMainDisplayID(), sink: RecordingEventSink())
        injector.handleTouch(phase: "began", x: 0.1, y: 0.1)
        injector.handlePencil(phase: "down", x: 0.1, y: 0.1, pressure: 0.5, azimuth: 0, altitude: 0.5, rotation: 0)
        XCTAssertTrue(injector.isDown)
        XCTAssertTrue(injector.penDown)
        XCTAssertTrue(injector.inRange)

        injector.reset()
        XCTAssertFalse(injector.isDown)
        XCTAssertFalse(injector.penDown)
        XCTAssertFalse(injector.inRange)
    }

    func testAccessibilityPermissionCheck() {
        _ = InputInjector.ensureAccessibilityPermission(prompt: false)
    }
}
