// The Native-mode gesture arbitration, as pure state machines.
//
// Deliberately free of UIKit: `VideoView` owns the recognizers and the socket,
// this file owns the *decisions*, and the Mac test bundle compiles it (see
// `project.yml`, target `OpenSidecarMacTests`) so those decisions have tests.
// The two failures this file exists to prevent were both decisions, not
// plumbing: a hold that moved never became a drag, and a tap that followed a
// scroll was marked spent and swallowed.

import CoreGraphics
import Foundation

/// Which of the Native-mode recognizers is asking.
enum NativeRecognizer: String, CaseIterable {
    case pan, tap, longPress, pinch
}

/// What a finger that interrupted scroll momentum is allowed to do.
///
/// iPadOS's rule, the one `UIScrollView` implements: the touch that stops a
/// coast is a **brake**. It does not activate what is under it — tapping a
/// decelerating list stops it rather than opening the row. But that is a rule
/// about the *tap*, and the previous version applied it to the long press as
/// well, which is what took drag away: a coast runs for up to ~2 s after a
/// flick, and for those two seconds no hold could commit, so no drag could
/// start and no context menu could open. Press-and-hold on a decelerating list
/// in Photos does pick the photo up; the deliberate 0.4 s press is itself the
/// proof that the user is not just braking.
///
/// The pan is untouched in either version: brake, then keep the finger down
/// and drag to scroll, in one motion.
enum MomentumBrake {

    /// How fast the coast must still be going for the brake to cost the user a
    /// click, in points per second.
    ///
    /// Round 4 made the brake unconditional, and the iPad's own log from the
    /// round-4 test says what that cost: **8 sequences braked the coast and 2
    /// taps were refused outright, against 16 taps in the whole session.**
    /// Roughly a third of the operator's taps were swallowed, which reads as
    /// "the iPad ignores me", not as "the list stopped".
    ///
    /// The rule iPadOS actually implements is narrower than "a coast is
    /// running". A `UIScrollView` that has decayed to a crawl is not visibly
    /// moving, and a tap on it does activate the row under the finger — what
    /// the brake protects against is *hitting a moving target*. 80 pt/s is
    /// about a finger-width every half second: below it the content is
    /// effectively parked, the finger lands on what the eye picked, and
    /// swallowing the click is pure loss.
    static let visibleCoastSpeed: CGFloat = 80

    /// Whether a finger landing on a coast at `coastSpeed` spends its click.
    /// Below the threshold the coast is still stopped — silently — and the tap
    /// goes through.
    static func swallowsTap(coastSpeed: CGFloat) -> Bool {
        coastSpeed > visibleCoastSpeed
    }

    /// - Parameters:
    ///   - recognizer: which recognizer wants to begin.
    ///   - braking: whether this finger sequence started by stopping a coast
    ///     that was still visibly moving (see `swallowsTap`).
    static func allows(_ recognizer: NativeRecognizer, braking: Bool) -> Bool {
        guard braking else { return true }
        switch recognizer {
        case .tap: return false
        case .pan, .longPress, .pinch: return true
        }
    }
}

/// The coast itself: how fast it starts, how it decays, and when it is over.
///
/// Pure so the one number the operator feels — *how long a flick keeps
/// moving* — can be asserted rather than estimated. Round 4's stop threshold
/// was 16 pt/s, which at `UIScrollView`'s deceleration rate leaves a hard flick
/// coasting for about two seconds; with the brake armed for every one of those
/// seconds, "tap does nothing" was most of the time somebody was using it.
enum ScrollMomentum {

    /// `UIScrollView.DecelerationRate.normal`, per millisecond. Unchanged:
    /// matching it is what makes a flick feel like the rest of iPadOS.
    static let decelerationPerMs = 0.998

    /// Below this a flick was a scroll, not a throw: no coast at all.
    static let startSpeed: CGFloat = 140

    /// Below this the coast is over.
    ///
    /// 40 pt/s rather than 16. The last stretch of a `0.998/ms` decay is the
    /// slowest and therefore the longest: going from 40 to 16 pt/s takes a
    /// further ~460 ms during which the content moves a total of ~27 points —
    /// invisible motion, and almost half the window in which a tap used to be
    /// refused. Stopping at 40 turns a 1000 pt/s flick's coast from ~2.1 s into
    /// ~1.6 s, and the part that is dropped is the part nobody can see.
    static let stopSpeed: CGFloat = 40

    /// How long a flick at `initialSpeed` keeps emitting deltas, in seconds.
    /// `v(t) = v0 · rate^(t·1000)`, solved for `v(t) = stopSpeed`.
    static func coastDuration(initialSpeed: CGFloat) -> TimeInterval {
        guard initialSpeed > stopSpeed else { return 0 }
        let ratio = Double(stopSpeed / initialSpeed)
        return log(ratio) / log(decelerationPerMs) / 1000
    }
}

/// Which of the pan and the hold owns a finger that has only just landed.
///
/// The arbitration is an *ordering of two thresholds*, and writing it down as
/// values that can be compared in a test is the point: a finger that is really
/// starting a scroll crosses the long press's `allowableMovement` — which fails
/// the hold — before it crosses the pan's own start threshold, so "moved first
/// = scroll" needs no tie-break at all. If those two numbers ever cross, the
/// pan can begin from a finger the hold was still entitled to, and hold-drag
/// silently stops working; `NativeTouchPolicyTests` fails instead.
enum HoldPriority {

    /// iPadOS's own context-menu delay, and `nativeLongPress.minimumPressDuration`.
    static let holdDuration: TimeInterval = 0.4

    /// `nativeLongPress.allowableMovement`: how far the finger may stray before
    /// the press duration elapses without the hold failing.
    static let holdSlop: CGFloat = 8

    /// `UIPanGestureRecognizer`'s undocumented-but-stable start threshold for a
    /// direct touch. Not settable, which is why it is the number the hold's
    /// slop has to be chosen *against*.
    static let panStartThreshold: CGFloat = 10

    /// The invariant the whole arbitration rests on.
    static var holdFailsBeforeThePanCanBegin: Bool { holdSlop < panStartThreshold }

    /// Belt and braces for the ordering above: the pan is also made to wait for
    /// the long press to fail (`nativePan.require(toFail: nativeLongPress)`).
    ///
    /// That edge costs a real scroll nothing, which is the only reason it is
    /// acceptable: a long press fails the *instant* movement exceeds
    /// `holdSlop` (8 pt), and the pan cannot begin before `panStartThreshold`
    /// (10 pt), so by the time the pan is entitled to start the hold has
    /// already failed and the edge is satisfied. A finger that stays inside
    /// 8 pt for the full 0.4 s is not scrolling by anyone's definition.
    static func panMayBegin(movedBy distance: CGFloat) -> Bool {
        distance > holdSlop
    }
}

/// The gate that makes the hold's claim on a still finger structural.
///
/// **Round 5 said the ordering of two thresholds was doing this job.** The
/// long press fails at 8 pt, `UIPanGestureRecognizer` starts at ~10 pt, so a
/// finger that is really scrolling fails the hold before the pan can begin.
/// The iPad's own log then said otherwise, eight times in one session:
///
/// ```
/// gesture: nativePan begins after 4.5 pt (hold slop 8 pt — INSIDE the slop, the hold should have had this finger)
/// ```
///
/// Two things were wrong with the round-5 answer, and they pull in opposite
/// directions:
///
/// 1. **The number in that line is not the distance the finger moved.**
///    `translation(in:)` is the *recognizer's* translation, and UIKit sets its
///    origin at the moment it decides to recognize — so it reads near zero at
///    `.began` by construction, and it is re-based again whenever the touch
///    count changes (which is why the two-finger lines read 0.0 and 0.2 pt).
///    The diagnostic was measuring itself.
/// 2. **`panStartThreshold` is a folk constant.** It is not settable, not
///    documented, and UIKit is free to begin a pan on velocity as well as on
///    distance. An arbitration whose safety depends on a number Apple never
///    promised is an arbitration that will break again.
///
/// So the threshold stops being an observation and becomes a **gate**: the
/// pan recognizer does not see a touch move at all until the finger has
/// travelled `slop` from where it landed. Below that the recognizer cannot
/// begin, because as far as it knows nothing has happened — no delegate
/// refusal, no `require(toFail:)` wait, and crucially no whole-sequence
/// failure, which is what `gestureRecognizerShouldBegin` returning false would
/// have cost (a finger refused at 3 pt and then accelerating into a real
/// scroll would have no pan left to take it).
///
/// The centroid, not one touch, because a two-finger scroll is one gesture:
/// tracking a single `UITouch` would make the gate fire when the *second*
/// finger landed somewhere else entirely.
struct PanSlopGate: Equatable {

    /// How far the centroid must travel before the pan may see anything.
    /// The same 8 pt as the hold's `allowableMovement`, and that identity is
    /// the point: below it the hold owns the finger, above it the pan does,
    /// and there is no band in between where both or neither do.
    static let defaultSlop = HoldPriority.holdSlop

    let slop: CGFloat

    private var origin: CGPoint?
    /// How far the centroid had actually travelled when the gate opened — the
    /// honest version of round 5's log line.
    private(set) var openedAfter: CGFloat = 0
    private(set) var isOpen = false
    /// Moves withheld from the recognizer, for the log: "the hold got this
    /// finger, and here is how many samples that took".
    private(set) var withheld = 0

    init(slop: CGFloat = PanSlopGate.defaultSlop) {
        self.slop = slop
    }

    /// A touch went down or came up: re-base the centroid. UIKit does exactly
    /// this internally, and without it adding a second finger reads as an
    /// instant jump of half the distance between the two.
    mutating func touchCountChanged(centroid: CGPoint) {
        guard !isOpen else { return }
        origin = centroid
    }

    /// Whether this move may be forwarded to the recognizer.
    mutating func shouldForward(centroid: CGPoint) -> Bool {
        if isOpen { return true }
        guard let origin else {
            self.origin = centroid
            withheld += 1
            return false
        }
        let moved = hypot(centroid.x - origin.x, centroid.y - origin.y)
        guard moved >= slop else {
            withheld += 1
            return false
        }
        isOpen = true
        openedAfter = moved
        return true
    }

    /// End of the sequence.
    mutating func reset() {
        origin = nil
        isOpen = false
        openedAfter = 0
        withheld = 0
    }

    /// The centroid of a set of points. Empty is `nil` rather than `.zero`:
    /// `.zero` is a real corner of the view and would read as an enormous jump.
    static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }
}

/// Who owns two fingers: the pinch, or the two-finger pan.
///
/// Round 5 concluded that the finger pinch was never recognized. The round-5
/// iPad log says the opposite — 21 of 34 `nativePinch` sessions report
/// `touches=2` — but it also shows the contention that produced the
/// impression, at 01:53:07 in the middle of a run of pinches:
///
/// ```
/// gesture: nativePinch .ended touches=1
/// gesture: nativePan begins after 0.2 pt …
/// gesture: nativePan .began touches=2
/// ```
///
/// The pan took two fingers that were mid-pinch. UIKit's default is
/// winner-takes-all, `nativePan.maximumNumberOfTouches` is 2, and whichever
/// recognizer happens to reach `.began` first kills the other for the whole
/// sequence.
///
/// The fix is the one a trackpad already implements: **both**, arbitrated by
/// what the fingers are doing. `PanSlopGate` does most of it for free — a pure
/// pinch moves the centroid almost not at all, so the pan never opens its gate
/// — and this adds the other half: a pan that has not begun yields outright
/// once the fingers have changed their separation by more than `spreadSlop`.
enum PinchArbiter {

    /// How much the distance between two fingers must change before the
    /// gesture is unambiguously a pinch.
    ///
    /// 12 pt, a little above `PanSlopGate.defaultSlop` (8): the two tests are
    /// racing, and a pinch that also drifts should not be able to satisfy both
    /// on the same sample. At 12 pt a deliberate pinch has already won and a
    /// two-finger scroll — where the fingers hold their spacing to within a
    /// few points — never will.
    static let spreadSlop: CGFloat = 12

    /// True when a not-yet-begun two-finger pan should fail and leave the
    /// fingers to the pinch.
    static func panYieldsToPinch(initialSpread: CGFloat, currentSpread: CGFloat) -> Bool {
        abs(currentSpread - initialSpread) > spreadSlop
    }

    static func spread(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// The pinch and the pan may run together once both have begun — the same
    /// thing a Mac trackpad does, and what makes "zoom a map and move it" one
    /// gesture instead of two. Everything else in the Native set stays
    /// exclusive: a hold that has committed must not also be scrolling.
    static func mayRunTogether(_ a: NativeRecognizer, _ b: NativeRecognizer) -> Bool {
        let pair = Set([a, b])
        return pair == Set([NativeRecognizer.pan, .pinch])
    }
}

/// Touch-and-hold, and what it becomes.
///
/// The gesture has two endings and the machine is what picks between them:
/// lifted inside the slop it is a **right click** at the hold point (the
/// context menu); moved past the slop it is **drag and drop**, whose `began`
/// is sent at the point the finger was *held*, because on iPadOS the thing you
/// pick up is the thing you were pressing.
///
/// The invariant every path is checked against: **every `dragBegan` is
/// followed by exactly one `dragEnded`.** A mouse button left down on the Mac
/// is the one failure this code can cause that the user cannot undo from the
/// iPad.
struct HoldDragMachine: Equatable {

    /// Movement after the hold has committed that turns it into a drag.
    ///
    /// Kept separate from the long press's `allowableMovement`, which governs
    /// the window *before* commit and which UIKit stops applying the moment the
    /// recognizer reaches `.began` — after that every movement is reported as
    /// `.changed`, unclamped. Two rules, two constants, even where the numbers
    /// agree: `commitSlop` may be retuned for the feel of a drag without
    /// silently changing what counts as a hold.
    static let defaultCommitSlop: CGFloat = 8

    let commitSlop: CGFloat

    private(set) var isActive = false
    private(set) var isDragging = false
    private(set) var holdPoint = CGPoint.zero
    /// Where the finger was last seen. A cancellation (mode switch, the view
    /// leaving the window) has no point of its own, and releasing a drag at
    /// the *hold* point would fling whatever is being dragged back to where it
    /// was picked up.
    private(set) var lastPoint = CGPoint.zero

    init(commitSlop: CGFloat = HoldDragMachine.defaultCommitSlop) {
        self.commitSlop = commitSlop
    }

    /// What the caller has to put on the wire.
    enum Emission: Equatable {
        case nothing
        /// Left button down at the hold point, immediately followed by a move
        /// to where the finger has actually got to. Both, in this order, from
        /// one `.changed`: the press belongs to what was under the finger when
        /// it was held.
        case dragBegan(at: CGPoint, movedTo: CGPoint)
        case dragMoved(to: CGPoint)
        /// Left button up (or cancelled) — the drag is over.
        case dragEnded(at: CGPoint, cancelled: Bool)
        /// The context menu: a right click down+up at the hold point.
        case rightClick(at: CGPoint)
    }

    /// The hold committed. Sends **nothing** — that is the whole point of the
    /// redesign in `c92eb1b`: a hold that pressed the left button on commit
    /// could never open a context menu, it selected whatever was underneath
    /// and dragged it.
    mutating func begin(at point: CGPoint) -> Emission {
        isActive = true
        isDragging = false
        holdPoint = point
        lastPoint = point
        return .nothing
    }

    /// The held finger moved. Below the slop it is still deciding.
    mutating func move(to point: CGPoint) -> Emission {
        guard isActive else { return .nothing }
        lastPoint = point
        if isDragging { return .dragMoved(to: point) }
        guard hypot(point.x - holdPoint.x, point.y - holdPoint.y) > commitSlop else {
            return .nothing
        }
        isDragging = true
        return .dragBegan(at: holdPoint, movedTo: point)
    }

    /// The finger lifted, or the gesture was interrupted.
    ///
    /// Three outcomes, and only one of them releases a button:
    /// * a drag was running → the release it is owed;
    /// * released in place → the right click it stands for, decided here rather
    ///   than at `begin` so a finger that moves can still become a drag;
    /// * **cancelled** in place → nothing at all. No button was ever pressed,
    ///   and a context menu nobody asked for is worse than no menu.
    mutating func end(at point: CGPoint? = nil, cancelled: Bool) -> Emission {
        guard isActive else { return .nothing }
        let release = point ?? lastPoint
        let wasDragging = isDragging
        let origin = holdPoint
        isActive = false
        isDragging = false
        holdPoint = .zero
        lastPoint = .zero
        if wasDragging { return .dragEnded(at: release, cancelled: cancelled) }
        return cancelled ? .nothing : .rightClick(at: origin)
    }
}

// MARK: - Where the video actually is on the glass

/// The aspect-fit rect the decoded video occupies inside the view, and the
/// normalization that is its exact inverse.
///
/// This is the one piece of the touch path that can put a finger in the wrong
/// place without anything looking wrong: the video is letterboxed (the iPad's
/// 4:3-ish glass against the Mac desktop's own aspect), so view coordinates and
/// video coordinates differ by an offset *and* a scale, and every one of the
/// six senders of a normalized pair has to apply both. Pulling the arithmetic
/// out of `VideoView` gives it tests and guarantees the cursor sprite, the
/// touches and the hover all use the same rect.
///
/// The view passes its **own bounds**, which is the whole of the glass:
/// `ReceiverScreen` renders the video with `.ignoresSafeArea()` and
/// `UIRequiresFullScreen`, so there is no safe-area inset between the layer and
/// the touches — the layer frame and the touch coordinate space are the same
/// rectangle. (Upstream #238 proposes a safe-area fit *setting*; it is not in
/// this branch, and if it is ever merged it changes exactly this function and
/// its tests, which is the reason the seam exists.)
enum VideoGeometry {

    /// Aspect-fit rect of `videoSize` inside `bounds`, in view coordinates.
    /// Nil when either is degenerate — before the first frame's format
    /// description arrives, `videoSize` is zero and there is nothing to map to.
    static func videoRect(bounds: CGSize, videoSize: CGSize) -> CGRect? {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A point in view coordinates → `[0,1]` in video space, origin top-left.
    ///
    /// Clamped, deliberately: a touch that starts inside the video and is
    /// dragged into the letterbox must keep driving the Mac's cursor along the
    /// edge rather than reporting a coordinate off the desktop. The clamp is
    /// also what makes a touch at the very top of the glass land on the very
    /// top of the Mac's display instead of one letterbox-height below it.
    static func normalize(_ point: CGPoint, bounds: CGSize, videoSize: CGSize) -> (x: Double, y: Double)? {
        guard let rect = videoRect(bounds: bounds, videoSize: videoSize) else { return nil }
        let x = (point.x - rect.minX) / rect.width
        let y = (point.y - rect.minY) / rect.height
        return (Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1)))
    }

    /// The inverse, for the cursor sprite: `[0,1]` in video space → the point
    /// on the glass. Round-trips with `normalize` for anything inside the rect.
    static func point(x: Double, y: Double, bounds: CGSize, videoSize: CGSize) -> CGPoint? {
        guard let rect = videoRect(bounds: bounds, videoSize: videoSize) else { return nil }
        return CGPoint(x: rect.minX + CGFloat(x) * rect.width,
                       y: rect.minY + CGFloat(y) * rect.height)
    }
}

/// Turning `UIPinchGestureRecognizer.scale` into something the Mac can post.
///
/// **This is the round-6 bug, and it was on both sides of the wire.** The Mac's
/// log reported one pinch as `net ×225395.704` over 24 events, another as
/// `×86932.074`, and several as `×0.000`; the iPad's log agreed exactly, which
/// is what ruled out the network and the Mac's arithmetic and left the value
/// the iPad put on the wire.
///
/// `recognizer.scale` is **cumulative since the gesture began**. The documented
/// way to get an increment out of it is to write `recognizer.scale = 1` after
/// reading it, and that is what round 5 shipped. It works for a *direct* pinch
/// — the round-6 log's two-finger sessions report sane factors (×3.5, ×0.94) —
/// and it does **not** work for an *indirect* one. Every absurd number in the
/// log came from a session logged `(0 touches, i.e. the trackpad)`, and the
/// shape of the numbers says why: `1.04^(1+2+…+24)` is about 2·10^5, which is
/// the product you get when each report is the running total and every one of
/// them is multiplied in as if it were a step. A trackpad pinch is delivered as
/// a gesture rather than as touches, there is no finger separation to re-base
/// against, and the setter has nothing to act on.
///
/// So the setter is not used at all any more. The increment is computed the way
/// that is true whatever UIKit does with the property: **divide by the previous
/// reading.** If a future iPadOS does honour the setter, the previous reading
/// is 1 and the division is the identity — the same answer, by a route that
/// cannot be wrong.
enum PinchScale {

    /// The largest incremental factor one message may carry.
    ///
    /// A 120 Hz pinch reports steps in the 1.001–1.05 range. 1.25 is five times
    /// the top of that and still nothing a user could produce by moving their
    /// fingers, so it bounds a re-base artefact (a finger landing or leaving
    /// re-bases `scale`, exactly as it re-bases a pan's translation) without
    /// touching any real gesture. The Mac clamps again on arrival — the wire is
    /// unauthenticated and the far end must not trust this — but clamping here
    /// is what keeps the *log* honest about what the fingers did.
    static let maxStep = 1.25
    static let minStep = 1 / maxStep

    /// The incremental factor to send, given this callback's cumulative scale
    /// and the previous one. Nil when the reading has no meaning and the
    /// message must be skipped rather than sent as a NaN.
    static func step(cumulative: Double, previous: Double) -> Double? {
        guard cumulative.isFinite, cumulative > 0,
              previous.isFinite, previous > 0 else { return nil }
        let raw = cumulative / previous
        guard raw.isFinite, raw > 0 else { return nil }
        return min(max(raw, minStep), maxStep)
    }

    /// Whether a step was clamped, i.e. whether the recognizer re-based under
    /// us. Counted per gesture and reported in the summary line, because a
    /// pinch full of clamped steps is a diagnosis and not just a number.
    static func wasClamped(cumulative: Double, previous: Double) -> Bool {
        guard cumulative.isFinite, cumulative > 0,
              previous.isFinite, previous > 0 else { return false }
        let raw = cumulative / previous
        return !(raw.isFinite) || raw > maxStep || raw < minStep
    }
}
