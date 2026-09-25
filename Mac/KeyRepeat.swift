import AppKit
import Foundation

/// Mac-side key auto-repeat for keys held on the iPad's hardware keyboard.
///
/// iOS does **not** synthesise repeats: `pressesBegan` fires once per physical
/// press and nothing else arrives until `pressesEnded`, no matter how long the
/// key is held. (`UIKey` has no `isARepeat`, and the repeat UIKit does perform
/// for text input happens inside the text system, below the press API.) So a
/// held arrow key or Backspace moved/deleted exactly one step — unusable for a
/// remote desktop. The repeat therefore has to be generated where the events
/// are injected: here.
///
/// Timings come from the Mac's own System Settings → Keyboard sliders, so the
/// remote keyboard feels like the local one.
enum SystemKeyRepeat {
    /// Seconds a key must be held before the first repeat.
    static var delay: TimeInterval { NSEvent.keyRepeatDelay }
    /// Seconds between repeats once they start.
    static var interval: TimeInterval { NSEvent.keyRepeatInterval }
}

/// Which keys repeat. Pure predicate, no state.
enum KeyRepeatPolicy {
    /// Modifiers and Caps Lock never repeat (holding Shift must not machine-gun
    /// `.flagsChanged`), and neither does anything with no virtual keycode —
    /// there would be nothing to re-post.
    static func repeats(hidUsage: UInt16) -> Bool {
        guard !KeyboardMap.isModifier(hidUsage) else { return false }
        guard hidUsage != KeyboardMap.HID.capsLock else { return false }
        guard hidUsage > 0x03 else { return false }   // 0x00…0x03: error rollover
        return KeyboardMap.macKeyCode(for: hidUsage) != nil
    }
}

/// The timer behind an auto-repeat, abstracted so the controller's transitions
/// can be tested without waiting on wall-clock time.
protocol KeyRepeatScheduling: AnyObject {
    func start(delay: TimeInterval, interval: TimeInterval, fire: @escaping () -> Void)
    func cancel()
}

/// Production scheduler: one reusable `DispatchSourceTimer` on its own serial
/// queue, so a repeat never runs on — or blocks — the connection queue that
/// parses control messages.
final class TimerKeyRepeatScheduler: KeyRepeatScheduling {
    private let queue = DispatchQueue(label: "opendisplay.key-repeat")
    private var timer: DispatchSourceTimer?

    func start(delay: TimeInterval, interval: TimeInterval, fire: @escaping () -> Void) {
        cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // `leeway` keeps the timer cheap; a few ms of jitter on a key repeat is
        // imperceptible and lets the scheduler coalesce wakeups.
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .milliseconds(4))
        timer.setEventHandler(handler: fire)
        timer.resume()
        self.timer = timer
    }

    func cancel() {
        timer?.cancel()
        timer = nil
    }
}

/// Tracks which key is currently repeating and drives the scheduler.
///
/// Last key down wins, exactly like a real keyboard: hold `a`, then press `b`,
/// and `b` repeats while `a` goes quiet — and releasing `a` does not stop `b`.
/// Not thread-safe by itself; InputInjector serialises access under its
/// keyboard lock.
final class KeyRepeatController {

    private let scheduler: KeyRepeatScheduling
    private let delay: () -> TimeInterval
    private let interval: () -> TimeInterval

    /// The key currently being repeated, or nil. Also the key that `reset()`
    /// has to release so a held key cannot survive a disconnect.
    private(set) var repeatingUsage: UInt16?

    init(scheduler: KeyRepeatScheduling = TimerKeyRepeatScheduler(),
         delay: @escaping () -> TimeInterval = { SystemKeyRepeat.delay },
         interval: @escaping () -> TimeInterval = { SystemKeyRepeat.interval }) {
        self.scheduler = scheduler
        self.delay = delay
        self.interval = interval
    }

    /// Starts repeating `hidUsage`, cancelling whatever was repeating before.
    /// `fire` is called on the scheduler's queue for every repeat.
    func keyDown(hidUsage: UInt16, fire: @escaping () -> Void) {
        guard KeyRepeatPolicy.repeats(hidUsage: hidUsage) else { return }
        let d = delay(), i = interval()
        // A zero/negative interval would spin the timer queue. macOS clamps its
        // own sliders well above this, but the values are user-writable via
        // `defaults`, so refuse the degenerate case instead of melting a core.
        guard d > 0, i > 0 else {
            repeatingUsage = nil
            scheduler.cancel()
            return
        }
        repeatingUsage = hidUsage
        // Cancel here rather than relying on the scheduler doing it inside
        // start(): "the newest key owns the repeat" is the controller's rule,
        // so the controller is where it is enforced.
        scheduler.cancel()
        scheduler.start(delay: d, interval: i, fire: fire)
    }

    /// Stops the repeat if this is the key that owns it. Releasing a *different*
    /// key leaves the current repeat alone.
    func keyUp(hidUsage: UInt16) {
        guard repeatingUsage == hidUsage else { return }
        repeatingUsage = nil
        scheduler.cancel()
    }

    /// Stops any repeat and reports the key that was held, so the caller can
    /// post its key-up. Used on disconnect / session reset.
    @discardableResult
    func reset() -> UInt16? {
        let held = repeatingUsage
        repeatingUsage = nil
        scheduler.cancel()
        return held
    }
}
