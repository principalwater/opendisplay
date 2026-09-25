import Foundation
import Carbon.HIToolbox

/// Cycling this Mac's keyboard input sources, with the public Text Input
/// Source API.
///
/// **Why not the user's ⌃Space shortcut.** Synthesising the system shortcut
/// would mean guessing what it is bound to (it is user-configurable and often
/// rebound or disabled), posting it into whatever application is frontmost,
/// and hoping that application does not consume it first. `TISSelectInputSource`
/// is the operation the shortcut performs, is public, is documented, and
/// reports whether it worked.
enum InputSourceSwitcher {

    /// The enabled keyboard layouts and input methods, in the order the Text
    /// Input Sources list (and therefore System Settings) gives them.
    ///
    /// Filtered the way the menu-bar item is: *selectable* sources on the
    /// keyboard category only. Without that filter the list includes the
    /// character viewer, the emoji picker and every layout the system ships
    /// but the user has not enabled — which would make "next language" step
    /// through a hundred entries.
    static func enabledKeyboardSourceIDs() -> [String] {
        sources().compactMap(id(of:))
    }

    static func currentSourceID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return id(of: current)
    }

    /// Select the next enabled keyboard source. Returns the id that was
    /// selected, or nil when there was nothing to do.
    @discardableResult
    static func selectNext() -> String? {
        let all = sources()
        let ids = all.compactMap(id(of:))
        guard let wanted = InputSourceCycle.next(after: currentSourceID(), in: ids),
              let index = ids.firstIndex(of: wanted) else {
            Log.info("input source: nothing to switch to (\(ids.count) enabled)")
            return nil
        }
        let status = TISSelectInputSource(all[index])
        guard status == noErr else {
            Log.info("input source: TISSelectInputSource(\(wanted)) failed (\(status))")
            return nil
        }
        Log.info("input source: switched to \(wanted)")
        return wanted
    }

    /// Run `selectNext()` on the main queue, from whatever queue the key
    /// arrived on.
    ///
    /// `TISCreateInputSourceList` is main-queue-only. HIToolbox's
    /// `islGetInputSourceListWithAdditions` calls `dispatch_assert_queue(main)`
    /// when it has to rebuild the cached list, and a call from any other queue
    /// dies right there with `EXC_BREAKPOINT` — which is what killed the sender
    /// on alfheim-home three times (2026-09-18 11:53, 2026-09-18 15:30,
    /// 2026-09-22 13:48), always on the `sender.video` queue, always at the
    /// `TISCreateInputSourceList` line below. The watchdog then restarted the
    /// app, the session came back on a brand-new virtual display, and the iPad
    /// had to be reconnected. The cache is why it looked intermittent: a warm
    /// list answers from any thread, so most Globe presses switch the layout
    /// and only the presses that miss the cache take the process down.
    ///
    /// The hop is asynchronous on purpose. The caller holds `InputInjector`'s
    /// state lock, and `DispatchQueue.main.sync` from under that lock would
    /// deadlock against any main-thread work waiting for the same lock.
    ///
    /// The three seams exist for the tests: the real TIS call must never run
    /// inside a unit test, because it would switch the layout of the Mac
    /// running the suite.
    static func selectNextOnMain(onMainThread: Bool = Thread.isMainThread,
                                 hopToMain: (@escaping () -> Void) -> Void
                                     = { DispatchQueue.main.async(execute: $0) },
                                 switchNow: @escaping () -> Void = { _ = selectNext() }) {
        if onMainThread {
            switchNow()
        } else {
            hopToMain(switchNow)
        }
    }

    private static func sources() -> [TISInputSource] {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable: kCFBooleanTrue as Any,
            kTISPropertyInputSourceIsEnabled: kCFBooleanTrue as Any,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return list
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
