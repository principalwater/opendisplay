import CoreGraphics
import Foundation

/// Test double for `InputEventSink`.
///
/// The injector's whole job is to synthesise events at the HID event tap, i.e.
/// to type and click on the real desktop. A test run must never do that — on a
/// developer machine it would click through whatever is on screen — so every
/// InputInjector test drives an injector built on this sink and then asserts on
/// what was recorded.
///
/// Thread-safe: auto-repeat fires from the injector's own timer queue.
final class RecordingEventSink: InputEventSink {

    /// The fields of a CGEvent this project actually cares about, snapshotted
    /// at post time (a CGEvent is a mutable reference, so keeping the object
    /// would let later mutations rewrite history).
    struct Recorded {
        let type: CGEventType
        let location: CGPoint
        let flags: CGEventFlags
        let keyCode: CGKeyCode
        let isAutorepeat: Bool
        let clickState: Int64
        let mouseButton: Int64
        let scrollAxis1: Int64
        let scrollAxis2: Int64
        /// kCGScrollWheelEventScrollPhase / ...MomentumPhase — the two fields
        /// that turn a scroll into a trackpad gesture on macOS.
        let scrollPhase: Int64
        let momentumPhase: Int64
        let unicode: String
        /// `CGEventGetType` as an integer, so a `kCGEventGesture` (29) — which
        /// Swift's `CGEventType` cannot name — is still assertable.
        let rawType: UInt32
        /// The three private gesture fields (see the bridging header).
        let gestureType: Int64
        let gesturePhase: Int64
        let gestureZoom: Double
    }

    private let lock = NSLock()
    private var recorded: [Recorded] = []
    private var warped: [CGPoint] = []
    private var cursor = CGPoint.zero

    var events: [Recorded] { lock.withLock { recorded } }
    var warps: [CGPoint] { lock.withLock { warped } }

    var cursorLocation: CGPoint {
        get { lock.withLock { cursor } }
        set { lock.withLock { cursor = newValue } }
    }

    func reset() {
        lock.withLock {
            recorded.removeAll()
            warped.removeAll()
        }
    }

    // MARK: InputEventSink

    func post(_ event: CGEvent) {
        var buffer = [UniChar](repeating: 0, count: 8)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length,
                                       unicodeString: &buffer)
        let snapshot = Recorded(
            type: event.type,
            location: event.location,
            flags: event.flags,
            keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
            isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            clickState: event.getIntegerValueField(.mouseEventClickState),
            mouseButton: event.getIntegerValueField(.mouseEventButtonNumber),
            scrollAxis1: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            scrollAxis2: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
            scrollPhase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
            unicode: String(utf16CodeUnits: buffer, count: max(0, min(length, 8))),
            rawType: ODGetEventTypeRaw(event),
            gestureType: ODGetEventIntegerField(event, ODEventFieldGestureType),
            gesturePhase: ODGetEventIntegerField(event, ODEventFieldGesturePhase),
            gestureZoom: ODGetEventDoubleField(event, ODEventFieldGestureZoomDelta))
        lock.withLock { recorded.append(snapshot) }
    }

    func warpCursor(to point: CGPoint) {
        lock.withLock { warped.append(point) }
    }
}

/// `NSLock.withLock` is macOS 13+; the test bundle targets 14, but spelling it
/// out keeps the helper independent of the deployment floor moving.
private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
