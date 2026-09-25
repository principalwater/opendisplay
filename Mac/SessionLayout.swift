import Foundation
import CoreGraphics

/// Which display the capture pipeline points at.
///
/// Lives here rather than in `MacSender` so `SessionLayout.resolve` below can be
/// unit-tested: the test bundle compiles these two enums, not ScreenCaptureKit.
enum CaptureMode: String {
    case mirror   // main display (Milestone 1)
    case extend   // virtual display (Milestone 2)
}

/// What the session does to this Mac's desktop.
///
/// Upstream has one axis — `CaptureMode`, mirror or extend — and in extend
/// mode the device's display is remembered next to the built-in one
/// (`DisplayArrangement`). That is right for "an iPad as a second monitor"
/// and wrong for the thing this fork exists to do: drive the Mac *from* the
/// iPad, where the iPad's display has to be the **main** display or every
/// newly opened window, every dialog and the menu bar stay on a panel the
/// user is not looking at.
///
/// So the fork splits extend in two and makes the choice explicit:
///
/// * `remote` — extend, and the sender pins its own virtual display at the
///   desktop origin `(0, 0)`, which is how macOS defines the main display.
///   Arrangement memory is **off**: nothing is restored, nothing is saved.
/// * `extend` — upstream's behaviour, byte for byte: the arrangement memory
///   puts the display back where the user last dragged it, and nothing is
///   made main.
/// * `mirror` — upstream's mirror mode: capture the main display, create no
///   virtual display. View-only, as it has always been.
enum SessionLayout: String, CaseIterable, Identifiable {
    case remote, extend, mirror

    var id: String { rawValue }

    /// Which capture pipeline this layout runs. `remote` and `extend` are the
    /// same pipeline; they differ only in what happens to the display's origin.
    var captureMode: CaptureMode {
        self == .mirror ? .mirror : .extend
    }

    /// Whether the sender parks its virtual display at `(0, 0)` and keeps it
    /// there for the life of the session.
    var pinsDisplayToMain: Bool { self == .remote }

    /// Whether `DisplayArrangement` applies. Deliberately false for `remote`:
    /// a remembered origin is exactly what fought the pin in the field (the
    /// restore re-applied 2 s after creation and moved the display off the
    /// origin again), and a layout that owns `(0, 0)` has nothing to remember.
    var remembersArrangement: Bool { self == .extend }

    var label: String {
        switch self {
        case .remote: return "Remote desktop"
        case .extend: return "Extend"
        case .mirror: return "Mirror"
        }
    }

    var hint: String {
        switch self {
        case .remote:
            return "The device becomes this Mac's MAIN display: a new desktop at the origin, so windows, dialogs and the menu bar open where you are looking. The sender holds it there for the whole session and keeps no saved position for it."
        case .extend:
            return "A second desktop next to the Mac's own, returned to wherever you last dragged it in System Settings → Displays. Nothing is made main."
        case .mirror:
            return "Shows a copy of this Mac's main display. View-only: the device's own touches and keys still drive the Mac, but there is no second desktop to put windows on."
        }
    }

    // MARK: - The setting

    /// Which key the resolved layout came from. Logged at capture start so an
    /// external watchdog — and the next bug report — can tell "the operator
    /// chose this" from "nothing was set and the fork defaulted".
    enum Source: String, Equatable {
        /// `sessionLayout` named a layout.
        case sessionLayoutKey = "sessionLayout"
        /// `sessionLayout` was absent (or a typo) and `mode mirror` decided.
        case legacyModeKey = "mode"
        /// Nothing usable was stored: the fork default.
        case forkDefault = "default"

        var explanation: String {
            switch self {
            case .sessionLayoutKey: return "sessionLayout key"
            case .legacyModeKey: return "legacy mode key"
            case .forkDefault: return "fork default, no key set"
            }
        }
    }

    static let defaultsKey = "sessionLayout"
    /// The legacy key this supersedes. Still read — see `resolve`.
    static let legacyModeKey = "mode"
    /// What this fork uses when nothing is stored. Upstream's answer is
    /// `extend`; this branch drives one Mac from one iPad, and `remote` is
    /// what that means.
    static let forkDefault = SessionLayout.remote

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> SessionLayout {
        resolved(defaults).layout
    }

    static func resolved(_ defaults: UserDefaults = .standard) -> (layout: SessionLayout, source: Source) {
        resolve(sessionLayout: defaults.string(forKey: defaultsKey),
                legacyMode: defaults.string(forKey: legacyModeKey))
    }

    /// Precedence, in one place so it can be tested without UserDefaults:
    ///
    /// 1. `sessionLayout`, when it is present **and** names a layout. It is the
    ///    newer, more specific key, so it wins outright — including over a
    ///    `mode` that disagrees with it.
    /// 2. otherwise `mode`, but **only** `mode mirror`. Mirror is a different
    ///    pipeline (no virtual display at all) and nothing else can ask for it,
    ///    so a stale `mode mirror` still means what it said.
    /// 3. otherwise the fork default, `remote`.
    ///
    /// **Round 5 changed rule 2.** Until `3a739d5`, `mode extend` resolved to
    /// `extend`, on the reasoning that somebody who wrote that key asked for
    /// upstream's extend. In the field that reasoning cost the operator a
    /// session: `mode` is upstream's key, it is also the `-mode` launch
    /// argument, and it was left behind on this machine from before
    /// `sessionLayout` existed. With `sessionLayout` absent it silently demoted
    /// the fork to `extend` — arrangement memory back on — while the external
    /// watchdog went on putting the display at `(0,0)`. The two fought, the
    /// desktop origin moved under the iPad's fingers, and taps landed on the
    /// neighbouring tab. A key nobody set this decade must not be able to turn
    /// the fork's whole reason for existing off.
    ///
    /// So `extend` is now reachable **only** by asking for it by name
    /// (`defaults write … sessionLayout extend`), which is one command and is
    /// documented. `mirror` keeps its legacy route because it selects a
    /// pipeline rather than demoting one.
    ///
    /// An unrecognised value in either key is treated as absent rather than as
    /// an error: a typo in a defaults write should not leave the app unable to
    /// start a session.
    static func resolve(sessionLayout: String?, legacyMode: String?) -> (layout: SessionLayout, source: Source) {
        if let sessionLayout, let layout = SessionLayout(rawValue: sessionLayout) {
            return (layout, .sessionLayoutKey)
        }
        if legacyMode.flatMap(CaptureMode.init(rawValue:)) == .mirror {
            return (.mirror, .legacyModeKey)
        }
        return (forkDefault, .forkDefault)
    }
}

// MARK: - The origin pin, as a decision

/// Whether the `remote` layout has to touch the display configuration at all.
///
/// Split out of `VirtualDisplay` (which drives a private API and can never be
/// unit-tested) because the answer is the whole safety property of the pin:
/// **a display already at the desktop origin must be left completely alone.**
///
/// The enforcement tick runs every 200 ms for the life of the session. If it
/// reconfigured unconditionally it would produce a display-configuration
/// transaction five times a second; every one of those is a moment in which
/// `CGDisplayBounds` for *every* display can change, which is exactly the
/// window in which a touch normalized against one set of bounds lands against
/// another — the neighbouring-tab symptom. Reading the bounds first and
/// returning when they are already right makes the steady state a single
/// `CGDisplayBounds` call and no transaction at all.
enum OriginPin {

    /// The desktop origin. macOS has no "make this the main display" call: the
    /// main display **is** the one whose global origin is `(0, 0)`.
    static let mainOrigin = CGPoint.zero

    /// True only when the display has actually drifted off the origin.
    static func needsRepin(currentOrigin: CGPoint) -> Bool {
        currentOrigin != mainOrigin
    }
}

// MARK: - The origin pin, as a whole-desktop layout

extension OriginPin {

    /// One display in the Mac's desktop arrangement, reduced to the three
    /// facts the layout needs. `CGDirectDisplayID` is not used here so the
    /// test bundle can build placements without CoreGraphics ever having to
    /// have a display attached.
    struct Screen: Equatable {
        var id: UInt32
        var size: CGSize
        var origin: CGPoint

        init(id: UInt32, size: CGSize, origin: CGPoint = .zero) {
            self.id = id
            self.size = size
            self.origin = origin
        }
    }

    /// Where one display has to end up.
    struct Placement: Equatable {
        var id: UInt32
        var origin: CGPoint
    }

    /// **Why a single display cannot be pinned on its own.**
    ///
    /// Round 5 logged this 1105 times in one headless session, 200 ms apart:
    ///
    /// ```
    /// remote layout: display 159 origin (1194,0) → (0,0) …; settled (1194,0) (result 0, re-pin #N)
    /// ```
    ///
    /// `result 0` is `kCGErrorSuccess`: CoreGraphics accepted the
    /// transaction and then did nothing, because the transaction was
    /// impossible. Two displays cannot share an origin, and a
    /// `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` pair
    /// that moves display *A* to `(0,0)` while display *B* is already there
    /// describes an overlapping arrangement. WindowServer does not fail it —
    /// it resolves it, by snapping the requested display back to a free spot,
    /// which is exactly where it came from. The call is a no-op that reports
    /// success, forever.
    ///
    /// The fix is to stop asking for half an arrangement. macOS has no "make
    /// this the main display" call; the main display **is** the one at
    /// `(0,0)`, so making one display main is by definition a statement about
    /// *every* display, and it has to be made in **one** transaction —
    /// `CGCompleteDisplayConfiguration` is the commit, and any intermediate
    /// state inside the pair is never evaluated.
    ///
    /// The arrangement produced: the target at the origin, every other
    /// display in a row to its right in display-id order, x accumulating each
    /// display's width, all at `y = 0`.
    ///
    /// * **A row, not a rectangle**, because macOS requires the arrangement to
    ///   be contiguous — no gaps, no overlaps — and a row is the only layout
    ///   that is guaranteed to satisfy that for any set of sizes without
    ///   solving a packing problem five times a second.
    /// * **To the right, never above or below**, because a display at negative
    ///   y would put the menu bar's screen below something and macOS would
    ///   snap it; and because the operator drives the Mac *from* the iPad, so
    ///   the other panels are scenery.
    /// * **Display-id order**, because it is stable for the life of a session
    ///   and free of ties. Sorting by current origin would make the layout a
    ///   function of the state it is trying to overwrite, so a display that
    ///   drifted would drag the whole row after it.
    ///
    /// Returns an empty array when `target` is not in `screens` — a display
    /// that is not in the arrangement cannot be made main, and a caller that
    /// is mid-rebuild should do nothing rather than reshuffle the desktop
    /// around a display that has gone.
    static func layout(target: UInt32, screens: [Screen]) -> [Placement] {
        guard let targetScreen = screens.first(where: { $0.id == target }) else { return [] }
        var placements = [Placement(id: target, origin: mainOrigin)]
        var x = targetScreen.size.width
        for screen in screens.filter({ $0.id != target }).sorted(by: { $0.id < $1.id }) {
            placements.append(Placement(id: screen.id, origin: CGPoint(x: x, y: 0)))
            x += screen.size.width
        }
        return placements
    }

    /// The subset of `layout` that is not already true.
    ///
    /// The steady state of a pinned session is "nothing to do", and that has
    /// to cost no display-configuration transaction at all: every
    /// `CGCompleteDisplayConfiguration` is a window in which `CGDisplayBounds`
    /// for every display changes under a touch that was normalized a
    /// millisecond earlier, which is the neighbouring-tab symptom of §27.
    static func drift(target: UInt32, screens: [Screen]) -> [Placement] {
        let wanted = layout(target: target, screens: screens)
        let current = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0.origin) })
        return wanted.filter { current[$0.id] != $0.origin }
    }
}
