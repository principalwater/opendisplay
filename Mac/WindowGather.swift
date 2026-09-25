import Foundation
import CoreGraphics

// MARK: - Why this exists
//
// In `remote` layout the iPad's display becomes the Mac's **main** display: it
// is moved to `(0,0)` and every other display is laid out to its right
// (`OriginPin`, §36). That makes the menu bar and new windows land on the iPad.
// It does **not** move the windows that are already open.
//
// When the operator drove this Mac from an iPad over Sunshine, that problem did
// not exist, and the reason is worth stating precisely because it is the whole
// design constraint here: Sunshine's setup **physically disconnected the
// panel**. macOS relocates every window off a display that goes away — it has
// to, or the windows would be unreachable — so the desktop arrived on the
// remote screen for free.
//
// This fork cannot do that. The session's own display is virtual; the
// BetterDisplay placeholder that makes a headless Mac usable stays connected,
// and so does the physical monitor when there is one. The Mac therefore never
// reaches zero displays, macOS never relocates anything, and the operator is
// left driving a main display with nothing on it while their work sits on a
// screen they cannot see.
//
// So the windows are moved deliberately. The sender already holds Accessibility
// permission — it is what injects every keystroke and every click — and the
// Accessibility API is the only public way to move another application's
// window.
//
// **The rules this is built to, in order of importance:**
//
//  1. *Nothing is destroyed.* A window is moved, never closed, never resized,
//     never un-fullscreened. Everything is remembered and put back at session
//     end.
//  2. *Never block.* All of it runs on a utility queue. A single unresponsive
//     application can otherwise hang an AX call for its full timeout, and this
//     walks every application on the Mac.
//  3. *Every failure is nothing.* An app that refuses, a window that has gone,
//     a coordinate the window server ignores — all are counted and skipped. A
//     display session must never fail because a window would not move.

/// The decisions, without the Accessibility API.
///
/// Pure so the two things that are actually easy to get wrong — which windows
/// are eligible, and where a window that does not fit ends up — can be
/// asserted rather than discovered on the operator's desktop with their
/// windows.
enum WindowGatherPolicy {

    /// `defaults write com.peetzweg.opensidecar.mac.alfheim gatherWindows -bool false`
    static let defaultsKey = "gatherWindows"

    /// On by default: in `remote` layout a main display with no windows on it
    /// is not a remote desktop, it is an empty screen.
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }

    /// What the Accessibility API says about one window.
    struct WindowFacts: Equatable {
        var frame: CGRect
        /// `AXSubrole`. `AXStandardWindow` is a document/app window; anything
        /// else is a panel, a sheet, a floating inspector or a system window.
        var subrole: String?
        var minimized: Bool
        var fullScreen: Bool
        /// Whether `AXPosition` is settable on this window at all.
        var positionSettable: Bool

        init(frame: CGRect, subrole: String? = "AXStandardWindow",
             minimized: Bool = false, fullScreen: Bool = false,
             positionSettable: Bool = true) {
            self.frame = frame
            self.subrole = subrole
            self.minimized = minimized
            self.fullScreen = fullScreen
            self.positionSettable = positionSettable
        }
    }

    /// The only subrole that is moved.
    ///
    /// Everything else is excluded on purpose rather than by omission:
    /// `AXDialog` and `AXSystemDialog` are modal and belong to whatever they
    /// are modal *for*; `AXFloatingWindow` and `AXSystemFloatingWindow` are
    /// palettes and HUDs that applications position themselves and will move
    /// straight back; and a window with **no** subrole at all is usually not a
    /// window in the user's sense (a status-item host, an offscreen helper).
    static let movableSubrole = "AXStandardWindow"

    /// Why a window was left alone. Logged in aggregate — one count per reason
    /// — because the interesting number is "17 windows moved, 3 skipped as
    /// fullscreen", not 20 lines.
    enum Skip: String, CaseIterable {
        case alreadyThere = "already on the session display"
        case notStandard = "not a standard window (panel, sheet or system window)"
        case minimised = "minimised"
        case fullScreen = "fullscreen"
        case notSettable = "the app does not allow its position to be set"
        case degenerate = "zero-sized"
    }

    /// Whether this window should be moved onto the session display.
    static func skipReason(_ window: WindowFacts, target: CGRect) -> Skip? {
        if window.frame.width <= 0 || window.frame.height <= 0 { return .degenerate }
        if window.subrole != movableSubrole { return .notStandard }
        if window.minimized { return .minimised }
        // A fullscreen window owns its own Space on its own display. Setting
        // its position does nothing, and the one thing that *would* move it is
        // taking it out of fullscreen — which is a change to the user's
        // document, not to their window layout.
        if window.fullScreen { return .fullScreen }
        if !window.positionSettable { return .notSettable }
        // The test is the window's **origin**, not its whole frame: a window
        // wider than the iPad's display is still "on" it, and a window whose
        // origin is on the session display is where we want it even if it
        // spills.
        if target.contains(window.frame.origin) { return .alreadyThere }
        return nil
    }

    /// Where the window goes.
    ///
    /// Relative position is preserved where it can be — a window in the middle
    /// of a 4K monitor lands in the middle of the iPad — because the operator
    /// recognises their desktop by shape. Then it is clamped, and the clamp is
    /// the part that matters:
    ///
    /// * the **title bar stays reachable**. A window dragged off the top of a
    ///   display cannot be dragged back, and moving a 1440 pt-tall window onto
    ///   an 834 pt display by preserving its centre would do exactly that;
    /// * `menuBarInset` keeps the title bar out from under the menu bar, which
    ///   the session display now has (it is main);
    /// * at least `minVisible` points of the window remain on the display
    ///   horizontally, so nothing lands entirely past an edge.
    ///
    /// Note the coordinate space: this is the global *display* space that both
    /// `CGDisplayBounds` and the Accessibility API use — origin at the top-left
    /// of the main display, **y increasing downwards**. AppKit's `NSScreen`
    /// frames are the other way up, which is exactly the sort of detail that
    /// earns a pure function with tests.
    static func destination(for frame: CGRect, from source: CGRect, to target: CGRect,
                            menuBarInset: CGFloat = 25,
                            minVisible: CGFloat = 80) -> CGPoint {
        // The same fraction of the way across the display it came from. A
        // window a third of the way down a 4K monitor lands a third of the way
        // down the iPad — which is what makes the gathered desktop look like
        // the desktop the operator left, rather than a stack in one corner.
        // A degenerate source (a window whose origin is on no display at all)
        // degrades to a straight clamp, which is the right answer for it.
        let usableSource = (source.width > 0 && source.height > 0) ? source : target
        let fx = (frame.origin.x - usableSource.minX) / usableSource.width
        let fy = (frame.origin.y - usableSource.minY) / usableSource.height
        let x = target.minX + fx * target.width
        let y = target.minY + fy * target.height

        let maxX = target.maxX - min(minVisible, frame.width)
        let minX = target.minX - max(0, frame.width - minVisible)
        // Never above the menu bar, and never so low that the title bar is off
        // the bottom: `menuBarInset` doubles as the title-bar allowance, which
        // is the right order of magnitude for every macOS title bar there has
        // ever been.
        let maxY = target.maxY - menuBarInset
        let minY = target.minY + menuBarInset

        return CGPoint(x: min(max(x, minX), maxX),
                       y: min(max(y, minY), maxY))
    }

    /// Whether a remembered window may be put back.
    ///
    /// Only if it is still where we left it: a user who moved a window during
    /// the session meant to move it, and undoing that at session end would be
    /// the app fighting them. A tolerance rather than an equality test, because
    /// window servers round.
    static func shouldRestore(current: CGPoint, weLeftItAt: CGPoint,
                              tolerance: CGFloat = 4) -> Bool {
        abs(current.x - weLeftItAt.x) <= tolerance && abs(current.y - weLeftItAt.y) <= tolerance
    }

    /// The summary line, built from counts so the log never grows with the
    /// number of windows.
    static func summary(moved: Int, skipped: [Skip: Int], failed: Int, apps: Int) -> String {
        var line = "gather windows: moved \(moved) window\(moved == 1 ? "" : "s") "
            + "from \(apps) application\(apps == 1 ? "" : "s") onto the session display"
        let notes = Skip.allCases.compactMap { reason -> String? in
            guard let n = skipped[reason], n > 0 else { return nil }
            return "\(n) \(reason.rawValue)"
        }
        if !notes.isEmpty { line += "; skipped " + notes.joined(separator: ", ") }
        if failed > 0 { line += "; \(failed) would not move" }
        return line
    }
}

// MARK: - The Accessibility side

#if canImport(AppKit)
import AppKit
import ApplicationServices

/// Moves other applications' windows onto the session display, and puts them
/// back afterwards.
///
/// Everything here runs on `queue` (utility). The only main-thread work is the
/// snapshot of running applications and the display geometry, both taken before
/// the walk begins — `NSWorkspace` and `CGDisplayBounds` are main-thread-ish,
/// and `AXUIElement` calls are not, so the split falls out naturally.
final class WindowGatherer {

    /// One window we moved, and where it was.
    private struct Moved {
        let window: AXUIElement
        let app: String
        let originalOrigin: CGPoint
        let placedAt: CGPoint
    }

    private let queue = DispatchQueue(label: "sender.windowgather", qos: .utility)
    /// `queue` only.
    private var moved: [Moved] = []
    private var gathering = false

    /// How long one Accessibility call may take before it is abandoned.
    ///
    /// The default is six seconds. This walks every window of every running
    /// application, and a single beachballed app would hold the queue for that
    /// long with nothing to show for it. One second is far longer than a
    /// healthy app needs and short enough that the worst case is bounded.
    private static let messagingTimeout: Float = 1.0

    /// Move every ordinary window onto `displayID`.
    ///
    /// - Parameter settled: called on the caller's queue afterwards, so a
    ///   caller can log or sequence on it. Always called, even when nothing
    ///   moved.
    func gather(onto displayID: CGDirectDisplayID, completion: (() -> Void)? = nil) {
        let target = CGDisplayBounds(displayID)
        let menuBarInset = Self.menuBarInset(of: displayID)
        let others = Self.displayFrames().filter { $0.key != displayID }
        let apps = Self.candidateApplications()
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.gathering else {
                Log.info("gather windows: already running — not starting a second walk")
                completion?()
                return
            }
            self.gathering = true
            defer { self.gathering = false; completion?() }
            guard target.width > 0, target.height > 0 else {
                Log.info("gather windows: the session display has no bounds yet — nothing done")
                return
            }
            self.walk(target: target, menuBarInset: menuBarInset,
                      otherDisplays: Array(others.values), apps: apps)
        }
    }

    private func walk(target: CGRect, menuBarInset: CGFloat,
                      otherDisplays: [CGRect], apps: [(pid: pid_t, name: String)]) {
        var movedCount = 0
        var failed = 0
        var skipped: [WindowGatherPolicy.Skip: Int] = [:]
        var appsTouched = Set<String>()

        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            guard let windows = Self.windows(of: element) else { continue }
            for window in windows {
                guard let facts = Self.facts(of: window) else { continue }
                if let reason = WindowGatherPolicy.skipReason(facts, target: target) {
                    skipped[reason, default: 0] += 1
                    continue
                }
                let source = otherDisplays.first { $0.contains(facts.frame.origin) } ?? .zero
                let destination = WindowGatherPolicy.destination(
                    for: facts.frame, from: source, to: target, menuBarInset: menuBarInset)
                guard Self.setOrigin(destination, of: window) else {
                    failed += 1
                    continue
                }
                moved.append(Moved(window: window, app: app.name,
                                   originalOrigin: facts.frame.origin,
                                   placedAt: destination))
                movedCount += 1
                appsTouched.insert(app.name)
            }
        }
        Log.info(WindowGatherPolicy.summary(moved: movedCount, skipped: skipped,
                                            failed: failed, apps: appsTouched.count))
    }

    /// Put back everything that is still where we left it.
    ///
    /// Best effort by construction: a window that has since been closed, an
    /// application that has quit, a window the user moved themselves — all are
    /// skipped, and the counts say how many of each.
    func restore(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            defer { completion?() }
            let all = self.moved
            self.moved.removeAll()
            guard !all.isEmpty else { return }
            // **Read everything first, then move anything.**
            //
            // The caller is `MacSender.stop()`, which releases the virtual
            // display a few instructions later. Once that display goes, macOS
            // relocates every window that was on it — which is the very
            // behaviour §46 opens by describing, and here it is the enemy: a
            // window the window server has just moved is no longer "where we
            // left it", so a read/write/read/write walk would decide, correctly
            // but uselessly, that the user had moved the later half of the
            // list. Doing all the reads in one tight pass takes a millisecond
            // or so for a whole desktop, which is comfortably ahead of the
            // display teardown, and nothing in it blocks the caller.
            let seen = all.map { ($0, Self.facts(of: $0.window)?.frame.origin) }
            var restored = 0
            var gone = 0
            var userMoved = 0
            for (entry, origin) in seen {
                guard let origin else { gone += 1; continue }
                guard WindowGatherPolicy.shouldRestore(current: origin,
                                                       weLeftItAt: entry.placedAt) else {
                    userMoved += 1
                    continue
                }
                if Self.setOrigin(entry.originalOrigin, of: entry.window) {
                    restored += 1
                } else {
                    gone += 1
                }
            }
            Log.info("gather windows: session over — put \(restored) window(s) back"
                     + (userMoved > 0 ? ", left \(userMoved) the user had moved since" : "")
                     + (gone > 0 ? ", \(gone) no longer exist" : ""))
        }
    }

    // MARK: Accessibility plumbing

    private static func candidateApplications() -> [(pid: pid_t, name: String)] {
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            // `.regular` is "has a Dock icon and a menu bar", i.e. an ordinary
            // application. Agents and UI-element apps (`LSUIElement`, which is
            // what this app itself is) own status items and floating panels,
            // never a desktop window worth relocating.
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier > 0, app.processIdentifier != mine else { return nil }
            return (app.processIdentifier, app.localizedName ?? "pid \(app.processIdentifier)")
        }
    }

    private static func displayFrames() -> [CGDirectDisplayID: CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
        var frames: [CGDirectDisplayID: CGRect] = [:]
        for id in ids.prefix(Int(count)) { frames[id] = CGDisplayBounds(id) }
        return frames
    }

    /// The height of the menu bar on this display, from AppKit — which is the
    /// only thing that knows it, and which reports it upside down relative to
    /// the space everything else here works in.
    private static func menuBarInset(of displayID: CGDirectDisplayID) -> CGFloat {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }) else { return 25 }
        // `frame` and `visibleFrame` are bottom-left origin, y up: the menu bar
        // is the gap at the *top*, i.e. between the two maxY values.
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        return inset > 0 ? inset : 25
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString,
                                            &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func facts(of window: AXUIElement) -> WindowGatherPolicy.WindowFacts? {
        guard let origin: CGPoint = axValue(window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = axValue(window, kAXSizeAttribute, .cgSize) else { return nil }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
        return WindowGatherPolicy.WindowFacts(
            frame: CGRect(origin: origin, size: size),
            subrole: axString(window, kAXSubroleAttribute),
            minimized: axBool(window, kAXMinimizedAttribute) ?? false,
            // "AXFullScreen" has no `kAX…` constant in the public headers; it
            // is the attribute AppKit's own fullscreen sets and every app that
            // supports fullscreen exposes it. Absent = not fullscreen, which is
            // the right reading for an app that has no such concept.
            fullScreen: axBool(window, "AXFullScreen") ?? false,
            positionSettable: settable.boolValue)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func axValue<T>(_ element: AXUIElement, _ attribute: String,
                                   _ type: AXValueType) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString,
                                            &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let out = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { out.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, out) else { return nil }
        return out.pointee
    }

    @discardableResult
    private static func setOrigin(_ origin: CGPoint, of window: AXUIElement) -> Bool {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                            value) == .success
    }
}
#endif
