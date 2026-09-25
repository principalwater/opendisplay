import AppKit
import CoreGraphics
import XCTest

/// **Does macOS deliver a synthetic magnify at all?**
///
/// Round 7 left the question open in the worst possible way: the Mac's log said
/// `53 NSEventTypeMagnify events posted at the cursor, net ×5.647,
/// Σmagnification +1.770`, every increment plausible, every event posted — and
/// nothing on the screen zoomed. Two explanations fit that evidence equally
/// well (the events land in the wrong place, or they are not magnify events at
/// all) and no amount of reading the sender's own code can tell them apart,
/// because everything on this side is doing exactly what it says.
///
/// So this file asks macOS instead. It needs no iPad, no session and no
/// display: it builds the fork's own packing and asks AppKit — through
/// `+[NSEvent eventWithCGEvent:]`, which is the same initializer AppKit uses to
/// build the `NSEvent` an application receives — what it makes of it.
///
/// **The answer, measured on macOS 26.0 (Darwin 25.6):**
///
/// | Packing | What AppKit makes of it |
/// |---|---|
/// | `kCGEventGesture` (29) + fields 110/113/132 — *what the fork posts* | `NSEventTypeGesture` (29). **Not** a magnify: an application's `magnify(with:)` is never called for it |
/// | CGEvent type **30** + the same fields | `NSEventTypeMagnify` (30), with the phase decoded exactly — but `NSEvent.magnification` reads **0** |
/// | either, plus the `kCGEventGestureStartEndSeriesType` fields Mac Mouse Fix sets | the series field **overwrites the zoom delta**; the event carries 0 |
///
/// And the reason, which is the part that settles it: `magnification` is not
/// stored in the CGEvent at all. `testNoCGEventFieldCanCarryTheMagnification`
/// writes a marker into every field from 0 to 600, as a double and as a float
/// bit pattern, and none of them reaches `NSEvent.magnification`. For a real
/// trackpad that number comes from the `IOHIDEvent` the window server attaches
/// to the CGEvent, and a posted CGEvent has none.
///
/// A synthesised magnify therefore cannot carry a magnification, which is
/// exactly what the operator saw. `zoomMode` defaults to `keys`.
///
/// What this file deliberately does **not** claim: that it is impossible. The
/// end-to-end proof — post the sequence and watch an application's
/// `magnify(with:)` fire — needs the window server to be delivering events to
/// applications, and it will not while the screen is locked, which is how this
/// machine was when this was written. What is asserted here is what can be
/// measured without one, and it is enough to stop shipping the silent no-op as
/// the default.
final class MagnifySelfTest: XCTestCase {

    /// `NSEventTypeMagnify`, which Swift's `NSEvent.EventType` does name.
    private let nsMagnify = NSEvent.EventType.magnify.rawValue     // 30
    /// `NSEventTypeGesture` — 29, which is also `kCGEventGesture`. The
    /// collision of the two numbering spaces is the whole trap.
    private let nsGesture: UInt = 29

    private func makeGesture(cgType: UInt32,
                             magnification: Double,
                             phase: MagnifyGesture.Phase) -> CGEvent? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(source: source),
              let type = CGEventType(rawValue: cgType) else { return nil }
        event.type = type
        ODSetEventIntegerField(event, ODEventFieldGestureType, ODGestureTypeZoom)
        ODSetEventDoubleField(event, ODEventFieldGestureZoomDelta, magnification)
        ODSetEventIntegerField(event, ODEventFieldGesturePhase, phase.rawValue)
        return event
    }

    // MARK: - What the fork builds

    func testTheForksPackingRoundTripsThroughTheCGEventFields() {
        // Whatever macOS does with it, the event this fork builds carries what
        // it means to carry. A field that did not stick would be a different
        // bug with the same symptom.
        guard let event = makeGesture(cgType: ODEventTypeGesture,
                                      magnification: 0.0625, phase: .changed) else {
            return XCTFail("could not build a gesture event")
        }
        XCTAssertEqual(ODGetEventTypeRaw(event), 29)
        XCTAssertEqual(ODGetEventIntegerField(event, ODEventFieldGestureType), ODGestureTypeZoom)
        XCTAssertEqual(ODGetEventDoubleField(event, ODEventFieldGestureZoomDelta), 0.0625, accuracy: 1e-9)
        XCTAssertEqual(ODGetEventIntegerField(event, ODEventFieldGesturePhase), 2)
    }

    // MARK: - What AppKit makes of it

    func testAGestureEventIsNotAMagnifyEventToAppKit() {
        // **The finding.** `kCGEventGesture` becomes `NSEventTypeGesture`, so
        // `magnify(with:)` is never called and `NSEvent.magnification` is not
        // even meaningful. This is why 53 correctly-posted events zoomed
        // nothing.
        guard let event = makeGesture(cgType: ODEventTypeGesture,
                                      magnification: 0.0625, phase: .changed),
              let ns = NSEvent(cgEvent: event) else {
            return XCTFail("AppKit refused the event outright")
        }
        XCTAssertEqual(ns.type.rawValue, nsGesture)
        XCTAssertNotEqual(ns.type.rawValue, nsMagnify,
                          "if this ever fails, macOS started delivering synthetic magnifies "
                          + "and `zoomMode magnify` is worth being the default again")
    }

    func testCGEventType30IsTheOneAppKitCallsAMagnify() {
        guard let event = makeGesture(cgType: 30, magnification: 0.0625, phase: .changed),
              let ns = NSEvent(cgEvent: event) else {
            return XCTFail("AppKit refused the event outright")
        }
        XCTAssertEqual(ns.type.rawValue, nsMagnify)
    }

    func testThePhaseFieldDecodesExactlyForThatType() {
        // Field 132 is right, and the IOHID phase bits map onto NSEventPhase
        // one for one. Worth pinning: it is the half of the packing that does
        // work, and it is what a future fix would build on.
        let expected: [(MagnifyGesture.Phase, NSEvent.Phase)] = [
            (.began, .began), (.changed, .changed), (.ended, .ended), (.cancelled, .cancelled),
        ]
        for (hid, appKit) in expected {
            guard let event = makeGesture(cgType: 30, magnification: 0, phase: hid),
                  let ns = NSEvent(cgEvent: event), ns.type.rawValue == nsMagnify else {
                return XCTFail("no magnify for phase \(hid)")
            }
            XCTAssertEqual(ns.phase, appKit, "IOHID phase \(hid.rawValue)")
        }
    }

    func testNoCGEventFieldCanCarryTheMagnification() {
        // The reason the whole path cannot work: `NSEvent.magnification` is not
        // read from the CGEvent. It comes from the IOHIDEvent the window server
        // attaches for real trackpad hardware, and a posted CGEvent carries
        // none — so a synthesised magnify is a magnify with no magnitude.
        //
        // Every field 0…600, as a double and as a float bit pattern. A write
        // that changes the event's own type is skipped rather than converted:
        // `+[NSEvent eventWithCGEvent:]` raises on an out-of-range type.
        let marker = 0.375
        var carriers: [UInt32] = []
        for field in UInt32(0)...UInt32(600) {
            for probe in [marker, Double(Float(marker).bitPattern)] {
                guard let source = CGEventSource(stateID: .hidSystemState),
                      let event = CGEvent(source: source),
                      let type = CGEventType(rawValue: 30) else { continue }
                event.type = type
                if probe == marker {
                    ODSetEventDoubleField(event, field, probe)
                } else {
                    ODSetEventIntegerField(event, field, Int64(probe))
                }
                guard ODGetEventTypeRaw(event) == 30,
                      let ns = NSEvent(cgEvent: event), ns.type.rawValue == nsMagnify else { continue }
                if abs(ns.magnification - marker) < 1e-4 { carriers.append(field) }
            }
        }
        XCTAssertTrue(carriers.isEmpty,
                      "field(s) \(carriers) now carry the magnification — macOS changed, and "
                      + "`zoomMode magnify` can be made to work; see ZoomMode's note")
    }

    func testTheStartEndSeriesVariantDestroysTheZoomDelta() {
        // The other packing the round-8 brief asked about: Mac Mouse Fix also
        // sets `kCGEventGestureStartEndSeriesType`. On this macOS that field
        // shares storage with the zoom delta, so adding it does not add
        // information — it erases the only number that mattered. Worth a test
        // so nobody adds it back as a hopeful experiment.
        guard let event = makeGesture(cgType: ODEventTypeGesture,
                                      magnification: 0.0625, phase: .began) else {
            return XCTFail("could not build a gesture event")
        }
        XCTAssertEqual(ODGetEventDoubleField(event, ODEventFieldGestureZoomDelta), 0.0625, accuracy: 1e-9)
        ODSetEventIntegerField(event, 115, 1)     // kCGEventGestureStartEndSeriesType
        XCTAssertNotEqual(ODGetEventDoubleField(event, ODEventFieldGestureZoomDelta), 0.0625,
                          "field 115 overlaps the zoom delta — the variant sends zeroes")
    }

    // MARK: - Delivery

    /// Posts the fork's own sequence and watches it come back through a session
    /// event tap — i.e. proves the events really do enter the system's event
    /// stream with their fields intact, which is the half of the question that
    /// *is* answerable without an unlocked screen.
    ///
    /// Net zero magnification (+0.01 then −0.01) and four events, so running
    /// the suite cannot change the size of anything on the tester's desktop.
    /// Skipped, loudly, when the test runner has no Accessibility permission —
    /// an event tap needs it, and a CI machine has none.
    func testThePostedSequenceEntersTheEventStreamWithItsFieldsIntact() throws {
        try XCTSkipUnless(AXIsProcessTrusted(),
                          "no Accessibility permission for the test runner — an event tap "
                          + "cannot be created, so delivery cannot be observed from here")
        final class Box: @unchecked Sendable { var seen: [(Double, Int64)] = [] }
        let box = Box()
        let mask = CGEventMask(1) << UInt64(ODEventTypeGesture)
        let callback: CGEventTapCallBack = { _, _, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            if ODGetEventIntegerField(event, ODEventFieldGestureType) == ODGestureTypeZoom {
                let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                box.seen.append((ODGetEventDoubleField(event, ODEventFieldGestureZoomDelta),
                                 ODGetEventIntegerField(event, ODEventFieldGesturePhase)))
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap,
                                          place: .tailAppendEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(box).toOpaque()) else {
            throw XCTSkip("the session event tap was refused")
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        let steps: [(Double, MagnifyGesture.Phase)] =
            [(0, .began), (0.01, .changed), (-0.01, .changed), (0, .ended)]
        for (delta, phase) in steps {
            makeGesture(cgType: ODEventTypeGesture, magnification: delta, phase: phase)?
                .post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(box.seen.count, steps.count,
                       "the posted gesture events did not come back through the session tap")
        for (index, step) in steps.enumerated() where index < box.seen.count {
            XCTAssertEqual(box.seen[index].0, step.0, accuracy: 1e-6)
            XCTAssertEqual(box.seen[index].1, step.1.rawValue)
        }
        // Net zero: nothing on the tester's desktop changed size.
        XCTAssertEqual(box.seen.reduce(0) { $0 + $1.0 }, 0, accuracy: 1e-9)
    }
}
