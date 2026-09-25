import Foundation
import CoreGraphics

/// Wraps the private CGVirtualDisplay API: makes macOS believe a real monitor
/// is attached. Sized in points at HiDPI (@2x), so a phone with native pixels
/// W×H gets a virtual display of (W/2)×(H/2) points backed by a W×H framebuffer.
///
/// **Ownership lives in `VirtualDisplayRegistry`, not here.** The private API has
/// no teardown call — a `CGVirtualDisplay` exists for exactly as long as
/// something holds a reference — so the registry holds the one strong reference
/// and this wrapper holds a weak one. Round 9 ended with two orphaned virtual
/// displays on the operator's desk and the real monitor missing from
/// `CGGetOnlineDisplayList`; the reason was that "release the display" was
/// spread across every exit path in a 3500-line sender, and one of them did not.
/// Now there is exactly one place that owns it and exactly one place that can
/// drop it, including from a signal handler.
final class VirtualDisplay {

    /// What this display's origin is for.
    ///
    /// Two policies, and they are mutually exclusive by construction rather
    /// than by convention — which matters, because in the field they fought:
    /// an external watchdog put the display at `(0,0)` to make it the main
    /// display and `.remembered`'s restore moved it back to its saved spot two
    /// seconds later, every time.
    enum OriginPolicy {
        /// Restore the caller's remembered spot for a few seconds (macOS
        /// asynchronously restores *its* stale arrangement for a fresh
        /// identity), then report every later move so the caller can persist
        /// the user's drag. `SessionLayout.extend`.
        case remembered(restore: CGPoint?, onChange: ((CGPoint, CGSize) -> Void)?)
        /// Hold the display at the desktop origin `(0,0)` — which is what
        /// makes a display the **main** display on macOS — for the whole
        /// session. Nothing is restored and nothing is saved, so there is no
        /// remembered origin left to fight the pin.
        /// `SessionLayout.remote`.
        case pinnedToMain
    }

    private let originPolicy: OriginPolicy
    /// **Weak on purpose.** `VirtualDisplayRegistry` holds the strong reference;
    /// see the type comment. A nil here means the display has been released and
    /// every operation below is a no-op, which is the correct behaviour for a
    /// session that is being torn down underneath an in-flight async frame.
    private weak var display: CGVirtualDisplay?
    /// Cached at creation so the id is still usable in a log line after the
    /// display itself has gone.
    private let id: CGDirectDisplayID
    private let registryToken: VirtualDisplayRegistry.Token
    private var settings: CGVirtualDisplaySettings
    private let maxPointsPerAxis: Int
    private(set) var pointsWide: Int
    private(set) var pointsHigh: Int
    private let targetFPS: Double

    private var restoreTarget: CGPoint?
    private var restoreUntil: Date
    private var lastReportedOrigin: CGPoint?
    private let onOriginChange: ((CGPoint, CGSize) -> Void)?

    /// The enforcement loop's own state machine (`Mac/DisplayLifecycle.swift`).
    /// Main-thread confined, like everything else below.
    private var enforcement = HiDPIEnforcement()
    /// Nested count of "somebody else is reconfiguring this display right now".
    /// While it is non-zero the enforcement tick does nothing at all — no mode
    /// re-apply, no mirror break, no origin pin. See `beginReconfiguration`.
    private var reconfigurationDepth = 0
    private var enforcementTask: Task<Void, Never>?
    private var released = false
    /// Reported at most once, when enforcement gives up. The caller's job is to
    /// rebuild the session around a fresh display — this wrapper deliberately
    /// does not try to heal itself, because trying forever is the defect.
    var onLost: ((String) -> Void)?
    private var lostReported = false

    var displayID: CGDirectDisplayID { id }
    /// False once the display has been released, so a caller can tell a live
    /// wrapper from a corpse without reaching for CoreGraphics.
    var isLive: Bool { !released && display != nil }

    /// Must be called on the main thread. `serialNum` must be unique per
    /// concurrent display AND stable per device — macOS keys saved display
    /// arrangement on vendor/product/serial, so a stable serial means each
    /// device keeps its position in System Settings across sessions.
    /// `originPolicy` decides what happens to the display's position: either
    /// the caller's remembered spot is restored and later drags are reported
    /// back (`.remembered`), or the display is held at the desktop origin so it
    /// is the Mac's main display (`.pinnedToMain`). See `manageOrigin`.
    init?(name: String, pointsWide: Int, pointsHigh: Int, sizeInMillimeters: CGSize,
          targetFPS: Double = 60,
          serialNum: UInt32 = 0x0001, productID: UInt32 = 0x4F53,
          originPolicy: OriginPolicy = .remembered(restore: nil, onChange: nil)) {
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh
        self.targetFPS = targetFPS
        self.originPolicy = originPolicy
        let restoreOrigin: CGPoint?
        let onOriginChange: ((CGPoint, CGSize) -> Void)?
        switch originPolicy {
        case .remembered(let restore, let onChange):
            restoreOrigin = restore
            onOriginChange = onChange
        case .pinnedToMain:
            restoreOrigin = nil
            onOriginChange = nil
        }
        // Reserve the longer orientation on both axes. That lets a phone or
        // tablet change orientation by applying a new mode to this *same*
        // virtual monitor instead of removing it and stranding its windows.
        maxPointsPerAxis = max(pointsWide, pointsHigh)
        self.restoreTarget = restoreOrigin
        self.restoreUntil = restoreOrigin == nil ? .distantPast : Date().addingTimeInterval(6)
        self.onOriginChange = onOriginChange

        // Before anything can be created, make sure something will destroy it
        // even if this process is killed. Idempotent, so the cost is one
        // boolean after the first display.
        VirtualDisplayRegistry.shared.installProcessExitHandlers()

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(maxPointsPerAxis * 2)
        descriptor.maxPixelsHigh = UInt32(maxPointsPerAxis * 2)
        descriptor.sizeInMillimeters = sizeInMillimeters
        descriptor.productID = productID   // base 0x4F53 "OS"; moves with the
                                           // serial when an identity is
                                           // abandoned (see MacSender)
        descriptor.vendorID = 0x5043       // "PC"
        descriptor.serialNum = serialNum
        descriptor.terminationHandler = { _, _ in
            Log.info("virtual display terminated by the system")
        }

        let created = CGVirtualDisplay(descriptor: descriptor)
        self.display = created
        self.id = created.displayID
        // The registry's captured `held` is the only strong reference to this
        // display from here on. `drop` runs at most once, from `release()`,
        // `deinit`, or an exit handler.
        var held: CGVirtualDisplay? = created
        self.registryToken = VirtualDisplayRegistry.shared
            .register("\(name) (display \(created.displayID))") { held = nil }

        settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        // Through `StreamTiming.displayMode` so the initial mode and the one
        // `resize()` builds cannot drift apart — see the note there.
        settings.modes = [Self.mode(pointsWide: pointsWide, pointsHigh: pointsHigh, targetFPS: targetFPS)]
        guard created.apply(settings) else {
            Log.info("CGVirtualDisplay applySettings FAILED")
            // A half-built display is still a registered display. Give it back
            // before the initializer throws the wrapper away.
            VirtualDisplayRegistry.shared.release(registryToken)
            return nil
        }
        Log.info("virtual display created: id=\(created.displayID) \(pointsWide)x\(pointsHigh)pt @2x @\(Int(targetFPS))Hz")

        // macOS defaults the new display to its 1x mode AND can restore a
        // stale saved mode for this serial asynchronously, seconds after the
        // display appears (observed: a display checked as @2x at creation
        // sitting at 1x later, and a rotated rebuild pillarboxed by the
        // previous orientation's mode). So mode selection is enforcement,
        // not a one-shot: keep watching for the lifetime of the display and
        // re-assert the HiDPI mode whenever something else changes it.
        // `.pinnedToMain` keeps the fast tick for the display's whole life.
        // The 2 s tick is fine for enforcing a *mode*, which macOS changes
        // once; the origin is contested continuously — by macOS's own saved
        // arrangement, and by whatever else moves displays on this Mac — and
        // "the main display is somewhere else for up to two seconds" is the
        // symptom this layout exists to remove. The tick costs one
        // `CGDisplayBounds` when the origin is already right.
        //
        // What the tick may *do* is the subject of `HiDPIEnforcement`: round 9
        // fired thirty `applySettings:` in seven seconds from here and wedged
        // WindowServer hard enough that the Mac would not take a password at
        // its own lock screen. The tick rate is unchanged; the actions it is
        // allowed to take are bounded, backed off, suspended during a
        // reconfiguration, and finite.
        let pinned: Bool
        if case .pinnedToMain = originPolicy { pinned = true } else { pinned = false }
        // The initial pin, synchronously. The tick below would reach it within
        // 200 ms, but the window between "the display exists" and "the display
        // is main" is a window in which the first captured frames and the
        // first touches are resolved against the wrong arrangement — and the
        // whole of §27 is about that class of window.
        if pinned { pinToMainOrigin() }
        enforcementTask = Task { @MainActor [weak self, pinned] in
            var settled = false
            while !Task.isCancelled {
                // Scoped strong ref: a rotation rebuild relies on release
                // removing the display — never hold it across the sleep.
                do {
                    guard let self, self.isLive else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.reconfigurationDepth > 0 {
                        // Somebody else owns the display: `resize()`, or a
                        // `findSCDisplay` poll waiting for it to come back.
                        // Both make it transiently unqueryable *by design*, and
                        // a tick that answered that with a re-apply is what
                        // made the round-9 poll unwinnable.
                        self.enforcement.noteSuspended()
                    } else {
                        self.ensureNotMirrored()
                        if self.enforceHiDPIMode(recover: settled, now: now) { settled = true }
                        self.manageOrigin()
                    }
                }
                try? await Task.sleep(for: .milliseconds(settled && !pinned ? 2000 : 200))
            }
        }
    }

    deinit { release() }

    // MARK: - Release

    /// Give the display back. Idempotent, safe from any thread, and the **only**
    /// way a `CGVirtualDisplay` this process created ever goes away.
    ///
    /// Every exit path calls it: `MacSender.stop()`, a failed `setupExtend`, a
    /// failed `reconfigure`, this object's own `deinit`, and — for the paths no
    /// Swift code gets to run on — `VirtualDisplayRegistry`'s `atexit`, signal
    /// and uncaught-exception handlers.
    func release() {
        guard !released else { return }
        released = true
        enforcementTask?.cancel()
        enforcementTask = nil
        display = nil
        let dropped = VirtualDisplayRegistry.shared.release(registryToken)
        if dropped {
            Log.info("virtual display \(id) released — "
                + "\(VirtualDisplayRegistry.shared.liveCount) still held by this process")
        }
    }

    // MARK: - Reconfiguration gate

    /// Declare that the caller is about to reconfigure this display, and that
    /// the enforcement tick must keep its hands off until `endReconfiguration`.
    ///
    /// This is the fix for the defect that ended round 9. `resize()` republishes
    /// the mode list, and `MacSender.findSCDisplay` then polls
    /// `SCShareableContent` for up to five seconds waiting for the display to
    /// come back. Throughout that window `CGDisplayCopyAllDisplayModes` answers
    /// with nothing — and the 200 ms enforcement tick read that as "the @2x mode
    /// vanished" and re-applied the settings, which restarts the very
    /// bring-up the poll is waiting to observe. Five display-reconfiguration
    /// transactions a second against a display that is trying to come online:
    /// the poll cannot win, the log fills with thirty identical lines, and
    /// WindowServer — which serialises display reconfiguration process-wide —
    /// stops serving everybody else, including loginwindow and the real monitor.
    ///
    /// Nested, because a rebuild can bracket a resize that brackets itself.
    /// Main thread.
    func beginReconfiguration() {
        reconfigurationDepth += 1
    }

    /// The other half. A deliberate reconfiguration republishes the mode list,
    /// so whatever enforcement had concluded about the old one is stale — the
    /// backoff, the attempt count and even a give-up are cleared.
    func endReconfiguration() {
        reconfigurationDepth = max(0, reconfigurationDepth - 1)
        if reconfigurationDepth == 0 {
            enforcement.reset()
            lostReported = false
        }
    }

    /// Run `body` with the enforcement tick suspended.
    func duringReconfiguration<T>(_ body: () throws -> T) rethrows -> T {
        beginReconfiguration()
        defer { endReconfiguration() }
        return try body()
    }

    // MARK: - Resize

    /// Change orientation without changing the virtual monitor's identity.
    /// Releasing a CGVirtualDisplay makes WindowServer redistribute every
    /// window on it before the replacement appears; with multiple devices,
    /// it may choose a sibling virtual display. Applying a new mode avoids
    /// that reassignment entirely.
    ///
    /// Must be called on the main thread.
    @discardableResult
    func resize(pointsWide: Int, pointsHigh: Int, movingTo origin: CGPoint?) -> Bool {
        guard let display else {
            Log.info("virtual display \(id) cannot resize — it has been released")
            return false
        }
        guard pointsWide <= maxPointsPerAxis, pointsHigh <= maxPointsPerAxis else {
            Log.info("virtual display \(id) cannot resize beyond its descriptor")
            return false
        }

        // The apply and everything it settles are the caller's, not the
        // enforcement tick's.
        beginReconfiguration()
        defer { endReconfiguration() }

        let newSettings = CGVirtualDisplaySettings()
        newSettings.hiDPI = 1
        // Same helper as the initial apply: a rotation must not quietly drop
        // the panel back to 60 Hz.
        newSettings.modes = [Self.mode(pointsWide: pointsWide, pointsHigh: pointsHigh, targetFPS: targetFPS)]
        guard display.apply(newSettings) else {
            Log.info("virtual display \(id) applySettings FAILED during resize")
            return false
        }
        settings = newSettings
        self.pointsWide = pointsWide
        self.pointsHigh = pointsHigh

        if case .pinnedToMain = originPolicy {
            // A mode change is a display reconfiguration, so WindowServer may
            // move this display — and the whole point of the layout is that it
            // does not get to. Re-assert the origin immediately rather than
            // waiting up to 2 s for the next enforcement tick.
            Log.info("virtual display \(id) resized to \(pointsWide)x\(pointsHigh)pt")
            pinToMainOrigin()
            return true
        }
        if let origin {
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success {
                CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
                let err = CGCompleteDisplayConfiguration(config, .permanently)
                // A mode change is a display reconfiguration, so macOS may
                // restore ITS arrangement for this identity a moment later,
                // exactly as it does after creation. Re-arm the same window so
                // that gets overridden, and adopt whatever WindowServer settled
                // on: a snap is system state, and persisting it as if it were a
                // user drag is the ratchet #203 is about.
                let settled = CGDisplayBounds(id).origin
                restoreTarget = settled
                restoreUntil = Date().addingTimeInterval(6)
                lastReportedOrigin = settled
                Log.info("virtual display \(id) resized to \(pointsWide)x\(pointsHigh)pt "
                    + "at (\(Int(origin.x)),\(Int(origin.y))), settled "
                    + "(\(Int(settled.x)),\(Int(settled.y))) (result \(err.rawValue))")
            }
        } else {
            Log.info("virtual display \(id) resized to \(pointsWide)x\(pointsHigh)pt")
        }
        return true
    }

    /// The one place a `CGVirtualDisplayMode` is built. The numbers come from
    /// `StreamTiming.displayMode`, which is pure and unit-tested; this wrapper
    /// is only the private-API constructor around them.
    private static func mode(pointsWide: Int, pointsHigh: Int, targetFPS: Double) -> CGVirtualDisplayMode {
        let spec = StreamTiming.displayMode(pointsWide: pointsWide, pointsHigh: pointsHigh,
                                            targetFPS: targetFPS)
        return CGVirtualDisplayMode(width: UInt(spec.pointsWide),
                                    height: UInt(spec.pointsHigh),
                                    refreshRate: spec.refreshRate)
    }

    // MARK: - HiDPI enforcement

    /// Consecutive mode-*selection* transactions that completed without putting
    /// the display in its HiDPI mode. Same three-then-quiet shape as
    /// `pinFailures`: a selection that cannot work has to say so once.
    private var modeSelectFailures = 0

    /// Look at the display's published modes, and select the @2x one if it is
    /// there and not current.
    ///
    /// The three answers are kept apart deliberately. Round 9's version printed
    /// `@2x mode vanished` for both "the list has no @2x entry" and "there is no
    /// list", and answered both with `applySettings:`. They are different
    /// diseases: the first is macOS having replaced our mode list from saved
    /// state, which republishing fixes; the second is the display not answering
    /// at all, which republishing makes worse.
    private func observeHiDPIMode() -> HiDPIEnforcement.Observation {
        guard let display else { return .displayNotQueryable }
        // A display with no bounds is not online. `isEmpty`, not `isNull`:
        // `CGDisplayBounds` returns `.zero` for an unknown id and `.null` only
        // for the special case, so `isNull` reads a dead display as live.
        guard !CGDisplayBounds(id).isEmpty else { return .displayNotQueryable }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
              !modes.isEmpty else {
            return .displayNotQueryable
        }
        guard let hidpi = modes.first(where: {
                  $0.width == pointsWide && $0.pixelWidth == pointsWide * 2 &&
                  (abs($0.refreshRate - targetFPS) < 1.0 || $0.refreshRate == 0)
              }) ?? modes.first(where: {
                  $0.width == pointsWide && $0.pixelWidth == pointsWide * 2
              }) else {
            return .modeMissing
        }
        if let current = CGDisplayCopyDisplayMode(id),
           current.width == hidpi.width, current.pixelWidth == hidpi.pixelWidth,
           (abs(current.refreshRate - hidpi.refreshRate) < 1.0 || hidpi.refreshRate == 0) {
            modeSelectFailures = 0
            return .inHiDPIMode
        }
        // The mode exists, it is simply not the current one: a cheap, targeted
        // mode switch — NOT a settings re-apply, which is the heavy transaction
        // that has to be rationed. `display` is captured above so a release
        // racing this cannot reconfigure a dead id.
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return .inHiDPIMode }
        CGConfigureDisplayWithDisplayMode(config, id, hidpi, nil)
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        if err == .success {
            modeSelectFailures = 0
            Log.info("HiDPI mode (re)selected: \(hidpi.width)x\(hidpi.height)@2x "
                + "@\(Int(hidpi.refreshRate))Hz (result \(err.rawValue))")
        } else {
            modeSelectFailures += 1
            if modeSelectFailures <= 3 {
                Log.info("HiDPI mode selection failed on display \(id): "
                    + "\(hidpi.width)x\(hidpi.height)@2x (result \(err.rawValue), "
                    + "attempt \(modeSelectFailures) of 3)"
                    + (modeSelectFailures == 3 ? " — staying quiet about it from here" : ""))
            }
        }
        // Either way the mode is published, which is what enforcement is about.
        // A selection that will not take is a different problem from a mode
        // that is not there, and re-publishing the list cannot help it.
        return .inHiDPIMode
    }

    /// One enforcement tick. Returns true when the display is (now) in its
    /// HiDPI mode — the caller uses that to slow the tick down.
    ///
    /// Silent when nothing needed doing: this runs every 200 ms (or 2 s) for the
    /// life of the display. With `recover`, a *missing* @2x mode re-applies our
    /// settings to publish it again — bounded to
    /// `HiDPIEnforcement.maxAttempts` with exponential backoff, and then it
    /// gives up and reports rather than spinning.
    @discardableResult
    private func enforceHiDPIMode(recover: Bool, now: TimeInterval) -> Bool {
        let observation = observeHiDPIMode()
        // Before the first success there is nothing to recover *to* — the
        // display is still coming up. Treat it as "not settled yet" and keep
        // the loop quiet, exactly as the pre-round-9 behaviour did.
        guard recover else { return observation == .inHiDPIMode }

        switch enforcement.decide(observation, reconfiguring: false, now: now) {
        case .nothing, .waitForReconfiguration:
            return observation == .inHiDPIMode
        case .waitForBackoff(let remaining):
            // Silent: this is the steady state of a failure being rationed, and
            // logging it would reproduce the thirty-lines-in-seven-seconds the
            // backoff exists to remove. The attempt that follows says so.
            _ = remaining
            return false
        case .reapplySettings(let attempt):
            guard let display else { return false }
            Log.info("@2x mode missing from display \(id) — re-applying settings "
                + "(attempt \(attempt) of \(HiDPIEnforcement.maxAttempts), "
                + "next in \(String(format: "%.1f", HiDPIEnforcement.backoff(attempt: attempt)))s)")
            _ = display.apply(settings)
            return false
        case .reportLost(let reason):
            reportLost(reason)
            return false
        }
    }

    /// Enforcement has given up. Say so once, and hand it to the caller, whose
    /// job is to rebuild the session around a fresh display. Deliberately not
    /// self-healing: a wrapper that keeps trying forever is the defect.
    private func reportLost(_ reason: String) {
        guard !lostReported else { return }
        lostReported = true
        Log.info("virtual display \(id) is lost — \(reason); "
            + "giving up on enforcement and asking for a rebuild")
        onLost?(reason)
    }

    // MARK: - Origin

    /// Arrangement restore + observation (#116). For the first few seconds,
    /// assert `restoreTarget`: macOS restores ITS saved arrangement for this
    /// display identity asynchronously, seconds after creation, and that
    /// record is stale or default whenever the identity is fresh (rotation
    /// swaps the serial, transport switches change it) — the caller's
    /// device-keyed record must win. Afterwards, origin changes are the user
    /// rearranging: report them so the caller can persist the new spot.
    private func manageOrigin() {
        if case .pinnedToMain = originPolicy {
            pinToMainOrigin()
            return
        }
        guard display != nil else { return }
        let origin = CGDisplayBounds(id).origin
        if let target = restoreTarget, Date() < restoreUntil {
            // Initial arrangement is system state, not a user drag. Mark it
            // observed so it cannot overwrite the saved device placement
            // when the restore window expires (#203).
            guard origin != target else {
                lastReportedOrigin = origin
                return
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success else { return }
            CGConfigureDisplayOrigin(config, id, Int32(target.x), Int32(target.y))
            let err = CGCompleteDisplayConfiguration(config, .permanently)
            // WindowServer snaps the requested origin to the nearest valid
            // arrangement — adopt what it settled on, or every remaining
            // tick of the window would re-apply against the snap.
            restoreTarget = CGDisplayBounds(id).origin
            // A snap is also system state. Keep observing from the settled
            // point, but only a later origin change may be a user drag.
            lastReportedOrigin = restoreTarget
            Log.info("display \(id) origin (\(Int(origin.x)),\(Int(origin.y))) → restored "
                + "(\(Int(target.x)),\(Int(target.y))), settled "
                + "(\(Int(restoreTarget!.x)),\(Int(restoreTarget!.y))) (result \(err.rawValue))")
            return
        }
        if origin != lastReportedOrigin {
            lastReportedOrigin = origin
            onOriginChange?(origin, CGSize(width: pointsWide, height: pointsHigh))
        }
    }

    /// Hold the display at the desktop origin.
    ///
    /// macOS has no "make this the main display" call: the main display *is*
    /// the one whose global origin is `(0,0)`, so moving this one there moves
    /// the others out of the way and hands it the menu bar. That is the
    /// `SessionLayout.remote` contract.
    ///
    /// Enforcement, not a one-shot, for the same reason as the HiDPI mode and
    /// the mirror set above: macOS restores its own saved arrangement for a
    /// display identity asynchronously — in the field, ~2 s after creation —
    /// and would otherwise silently take the origin back.
    ///
    /// `.forSession`, never `.permanently`: this layout keeps no memory of
    /// where the display sits, and writing `(0,0)` into the system's saved
    /// arrangement would change what the *other* layouts see the next time
    /// they build a display for this identity.
    /// Every actual re-pin, so "the display moved N times this session" is a
    /// number in the log rather than a count of lines somebody has to make.
    private var repins = 0
    /// Consecutive transactions that completed and left the display somewhere
    /// other than the origin. Round 5 shipped without this and logged the same
    /// failed pin 1105 times in one session; a pin that cannot work has to say
    /// so once and then stop shouting.
    private var pinFailures = 0
    private var pinRetryAfter = Date.distantPast

    private func pinToMainOrigin() {
        guard display != nil else { return }
        let origin = CGDisplayBounds(id).origin
        // **Read first, reconfigure only on drift.** This tick runs every
        // 200 ms for the whole session; a `CGBeginDisplayConfiguration` /
        // `CGCompleteDisplayConfiguration` pair five times a second would be
        // five display-reconfiguration transactions a second, and every one of
        // those is a window in which `CGDisplayBounds` can change under a
        // touch that was normalized a millisecond earlier. The steady state
        // therefore has to cost exactly one `CGDisplayBounds` read and nothing
        // else — which is what `OriginPin.needsRepin` (pure, tested) says.
        //
        // Round 6: the cheap check stays the target's own origin, because that
        // is the one fact the layout exists to guarantee and the one that can
        // be had for a single call. Where the *other* displays sit is only
        // read once that check has already failed.
        guard OriginPin.needsRepin(currentOrigin: origin) else {
            if pinFailures > 0 {
                Log.info("remote layout: display \(id) is at the origin again after "
                    + "\(pinFailures) failed transaction(s) — it is the main display")
            }
            pinFailures = 0
            pinRetryAfter = .distantPast
            return
        }
        // A pin that has already failed several times is failing for a reason
        // outside this process (in the field: an external watchdog moving
        // displays back). Keep trying — the watchdog may stop — but every
        // 30 s, not five times a second, and silently.
        guard Date() >= pinRetryAfter else { return }

        // **The whole desktop, in one transaction.** See `OriginPin.layout`:
        // asking for this display alone is a request for an overlapping
        // arrangement, which WindowServer resolves by snapping the display
        // straight back and reporting success.
        let screens = Self.arrangement()
        let moves = OriginPin.layout(target: UInt32(id), screens: screens)
        guard !moves.isEmpty else {
            // The display is not in the active arrangement — mid-rebuild, or
            // asleep. Reshuffling the desktop around a display that has gone
            // would be worse than waiting for the next tick.
            return
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for move in moves {
            CGConfigureDisplayOrigin(config, CGDirectDisplayID(move.id),
                                     Int32(move.origin.x), Int32(move.origin.y))
        }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        let settled = CGDisplayBounds(id).origin
        repins += 1
        let others = moves.count - 1
        if settled == OriginPin.mainOrigin {
            pinFailures = 0
            pinRetryAfter = .distantPast
            Log.info("remote layout: display \(id) origin "
                + "(\(Int(origin.x)),\(Int(origin.y))) → (0,0) so it is the main display; "
                + "\(others) other display\(others == 1 ? "" : "s") moved aside in the same "
                + "transaction (\(Self.describe(moves, excluding: UInt32(id)))); "
                + "settled (0,0) (result \(err.rawValue), re-pin #\(repins))")
            return
        }
        pinFailures += 1
        pinRetryAfter = Date().addingTimeInterval(pinFailures >= 3 ? 30 : 1)
        if pinFailures <= 3 {
            Log.info("remote layout: display \(id) origin "
                + "(\(Int(origin.x)),\(Int(origin.y))) → (0,0) FAILED — settled "
                + "(\(Int(settled.x)),\(Int(settled.y))) (result \(err.rawValue), "
                + "attempt \(pinFailures) of 3, \(others) other display"
                + "\(others == 1 ? "" : "s") in the transaction)"
                + (pinFailures == 3
                   ? " — something outside this app is moving displays; retrying every 30 s from here"
                   : ""))
        }
    }

    private static func describe(_ moves: [OriginPin.Placement], excluding target: UInt32) -> String {
        let others = moves.filter { $0.id != target }
        guard !others.isEmpty else { return "none" }
        return others.map { "\($0.id)→(\(Int($0.origin.x)),\(Int($0.origin.y)))" }
            .joined(separator: " ")
    }

    /// The Mac's desktop arrangement right now.
    ///
    /// The **active** list, not the online one: a display that is mirroring
    /// another has no independent origin, occupies no desktop space, and
    /// putting it in the transaction would describe an arrangement macOS
    /// cannot satisfy.
    private static func arrangement() -> [OriginPin.Screen] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).compactMap { id in
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return OriginPin.Screen(id: UInt32(id), size: bounds.size, origin: bounds.origin)
        }
    }

    /// An extend-mode virtual display must never sit in a system mirror set.
    /// macOS can drop it there on its own — e.g. when it misclassifies the
    /// display as a TV, whose arrangement default is "Mirror Entire Screen"
    /// (issue #100) — and that arrangement is saved per vendor/product/serial,
    /// so a stable serial means it's restored every session and the device is
    /// stuck mirroring. Detaching is enforcement, not a one-shot: like the
    /// HiDPI mode, re-break it whenever macOS re-mirrors it. Mirror mode never
    /// builds a VirtualDisplay (it captures the main display instead), so a
    /// VirtualDisplay in a mirror set is always wrong — safe to always undo.
    private func ensureNotMirrored() {
        guard display != nil else { return }
        // boolean_t is Int32: CoreGraphics returns 1 for mirrored, 0 for not mirrored,
        // and -1 for unknown/unregistered display IDs. Checking `!= 0` treats missing
        // displays as mirrored (issue #142) — compare explicitly against 1.
        guard CGDisplayIsInMirrorSet(id) == 1 else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        // Detach the virtual display itself (covers "macOS mirrors the VD onto
        // the main display")...
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        // ...and any display currently mirroring the VD (covers the reporter's
        // arrangement: the device set as Main, with the built-in mirroring it).
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &list, &n)
        for other in list where other != id && CGDisplayMirrorsDisplay(other) == id {
            CGConfigureDisplayMirrorOfDisplay(config, other, kCGNullDirectDisplay)
        }
        // Session scope, NOT permanent: permanent mirror reconfiguration of the
        // private virtual display is rejected (kCGErrorIllegalArgument) and
        // silently leaves it mirrored despite a "success" from the mirror call.
        // Session scope actually dissolves the set, and this runs every ~2s for
        // the display's lifetime, so it re-overrides whatever mirror arrangement
        // macOS restores — continuous enforcement, like the HiDPI mode above.
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        Log.info("virtual display \(id) was in a mirror set — detached to extend (result \(err.rawValue))")
    }
}
