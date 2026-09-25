import Foundation

// MARK: - HiDPI enforcement

/// The *decision* half of `VirtualDisplay`'s HiDPI enforcement, extracted so it
/// can be tested without a display.
///
/// Round 9 ended with thirty
/// `@2x mode vanished from display 185 — re-applying settings` lines in seven
/// seconds, none of which succeeded, after which the display was gone from
/// `SCShareableContent`, the real monitor was gone from `CGGetOnlineDisplayList`
/// and the Mac would not accept a password at its own lock screen. Three
/// separate defects made that possible, and all three are answered here:
///
/// * **One log line covered two different diseases.** `selectHiDPIMode` printed
///   "@2x mode vanished" both when the mode list was present but had no @2x
///   entry *and* when `CGDisplayCopyAllDisplayModes` returned nothing at all.
///   The second is not a mode problem — it means the display is not queryable
///   (asleep, mid-reconfiguration, or gone) — and `applySettings:` is the worst
///   available answer to it. `Observation` keeps them apart and
///   `.displayNotQueryable` never re-applies anything.
/// * **There was no backoff.** The enforcement tick runs every 200 ms for the
///   whole life of a `.pinnedToMain` display, and every tick that failed issued
///   another `applySettings:` — a full WindowServer display-reconfiguration
///   transaction, five a second, for as long as the failure lasted. Attempts
///   are now spaced 0.5, 1, 2, 4, 8 s.
/// * **There was no end.** A re-apply that cannot work never could work, and the
///   loop had no way to say so. After `maxAttempts` it gives up permanently and
///   reports, and the caller rebuilds the display from scratch instead.
///
/// Plus the fourth rule, which is the one that actually broke the operator's
/// session: **never fight a reconfiguration in progress.** `resize()` and
/// `findSCDisplay`'s five-second poll both make the display transiently
/// unqueryable by design; a 200 ms tick that answers that with `applySettings:`
/// knocks the display down faster than it can come up, and the poll can never
/// win. `reconfiguring` suspends every action.
struct HiDPIEnforcement {

    /// What a look at the display's mode list said.
    enum Observation: Equatable {
        /// The @2x mode is published (and selected, or being selected).
        case inHiDPIMode
        /// The list is there and does not contain our @2x mode. macOS can
        /// replace the whole mode list when it restores saved display state;
        /// re-applying our settings republishes it. This is the *only*
        /// observation a re-apply is a valid answer to.
        case modeMissing
        /// `CGDisplayCopyAllDisplayModes` returned nothing, or the display has
        /// no bounds. The display is not answering — asleep, mid-reconfigure,
        /// or gone. Re-applying settings here is what turned a transient
        /// condition into a WindowServer storm.
        case displayNotQueryable
    }

    enum Action: Equatable {
        /// Nothing to do, or nothing that may be done yet.
        case nothing
        /// Re-publish the settings. `attempt` is 1-based, for the log.
        case reapplySettings(attempt: Int)
        /// Backing off from a previous attempt.
        case waitForBackoff(remaining: TimeInterval)
        /// A reconfiguration is in progress and owns the display.
        case waitForReconfiguration
        /// Give up and tell the caller, once. The display is not coming back by
        /// itself and the session has to be rebuilt around a new one.
        case reportLost(reason: String)
    }

    /// Five attempts over ~15 s, against round 9's thirty over seven.
    static let maxAttempts = 5
    static let firstBackoffSeconds: TimeInterval = 0.5
    static let backoffCeilingSeconds: TimeInterval = 8.0
    /// How long the display may stay unqueryable before it counts as lost.
    /// Long enough to cover a `resize()` plus a full `findSCDisplay` poll that
    /// forgot to declare itself, short enough that a dead display is reported
    /// while the session can still be rebuilt around a new one.
    static let notQueryableGraceSeconds: TimeInterval = 8.0

    /// Re-apply attempts since the mode was last seen.
    private(set) var attempts = 0
    /// Absolute time of the earliest permissible next attempt.
    private(set) var nextAttemptAt: TimeInterval = 0
    /// When the display first stopped answering, if it has.
    private(set) var notQueryableSince: TimeInterval?
    /// Set once: after this, the machine takes no further action ever.
    private(set) var gaveUp = false

    /// The backoff before attempt `n` (1-based): 0.5, 1, 2, 4, 8, capped.
    static func backoff(attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let doubled = firstBackoffSeconds * pow(2.0, Double(attempt - 1))
        return min(doubled, backoffCeilingSeconds)
    }

    /// The whole policy. Pure: same inputs, same output, no clock of its own.
    mutating func decide(_ observation: Observation,
                         reconfiguring: Bool,
                         now: TimeInterval) -> Action {
        // A reconfiguration owns the display. It is *expected* to make it
        // unqueryable, so this is not evidence of anything and nothing here may
        // act on it — including the not-queryable clock, which would otherwise
        // convict a display for being resized.
        if reconfiguring {
            noteSuspended()
            return .waitForReconfiguration
        }
        if gaveUp { return .nothing }

        switch observation {
        case .inHiDPIMode:
            // Success resets everything, including a backoff mid-flight: the
            // next failure is a new failure and deserves a fast first retry.
            attempts = 0
            nextAttemptAt = 0
            notQueryableSince = nil
            return .nothing

        case .displayNotQueryable:
            // Never `applySettings:` here. Time it, and if it does not come
            // back, report it as lost so the caller can rebuild.
            let since = notQueryableSince ?? now
            notQueryableSince = since
            guard now - since >= Self.notQueryableGraceSeconds else { return .nothing }
            gaveUp = true
            return .reportLost(reason: String(
                format: "the display stopped answering %.0fs ago and has not come back",
                now - since))

        case .modeMissing:
            notQueryableSince = nil
            guard attempts < Self.maxAttempts else {
                gaveUp = true
                return .reportLost(reason:
                    "its @2x mode did not come back after \(attempts) re-applied settings")
            }
            guard now >= nextAttemptAt else {
                return .waitForBackoff(remaining: nextAttemptAt - now)
            }
            attempts += 1
            nextAttemptAt = now + Self.backoff(attempt: attempts)
            return .reapplySettings(attempt: attempts)
        }
    }

    /// The display is somebody else's for the moment. Being unqueryable while
    /// that is true is expected, so the clock that would eventually declare it
    /// lost must not run.
    mutating func noteSuspended() {
        notQueryableSince = nil
    }

    /// A deliberate mode change (a rotation) republishes the mode list, so
    /// whatever this machine had concluded about the old one is stale —
    /// including a give-up.
    mutating func reset() {
        attempts = 0
        nextAttemptAt = 0
        notQueryableSince = nil
        gaveUp = false
    }
}

// MARK: - The registry that owns every virtual display

/// Process-wide ownership of the `CGVirtualDisplay`s this app creates.
///
/// Round 9 left two of them behind. When the sender died, CoreGraphics kept
/// reporting displays with empty localized names — `" (AirPlay) (1)"` — while
/// the real monitor had dropped out of `CGGetOnlineDisplayList` entirely, and
/// nothing short of killing and relaunching BetterDisplay recovered it.
///
/// The private API has no teardown call at all: a `CGVirtualDisplay` exists for
/// exactly as long as something holds a reference to it, so "release the
/// display" means "drop the last reference", and **any** surviving reference —
/// a local in an async frame that is still unwinding, a closure, a `Task` — is
/// an orphaned monitor on the user's desk. Relying on every path through a
/// 3500-line sender to drop its reference is exactly the assumption that failed.
///
/// So the registry, and not the `VirtualDisplay` wrapper, is the owner. The
/// wrapper's reference is a convenience; the registry's is the one that counts,
/// and it can be dropped from one place — including from an exit handler, where
/// no amount of correct ARC in the session code is going to run.
final class VirtualDisplayRegistry {

    static let shared = VirtualDisplayRegistry()

    struct Token: Hashable {
        let value: Int
        /// A token that owns nothing. Safe to `release`.
        static let none = Token(value: 0)
    }

    private struct Entry {
        let label: String
        let drop: () -> Void
    }

    private let lock = NSLock()
    private var entries: [Int: Entry] = [:]
    private var nextValue = 1
    private var exitHandlersInstalled = false
    private var signalSources: [DispatchSourceSignal] = []

    /// How many displays this process is currently holding open.
    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// The labels of everything still held, for the log.
    var liveLabels: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries.keys.sorted().compactMap { entries[$0]?.label }
    }

    /// Hand the registry the *only* reference that matters. `drop` must release
    /// whatever holds the `CGVirtualDisplay`, and is called at most once.
    @discardableResult
    func register(_ label: String, drop: @escaping () -> Void) -> Token {
        lock.lock()
        let value = nextValue
        nextValue += 1
        entries[value] = Entry(label: label, drop: drop)
        lock.unlock()
        return Token(value: value)
    }

    /// Idempotent, and safe from any thread: the entry is taken out under the
    /// lock and dropped outside it, so two concurrent releases cannot both run
    /// the closure and a closure that re-enters cannot deadlock.
    @discardableResult
    func release(_ token: Token) -> Bool {
        lock.lock()
        let entry = entries.removeValue(forKey: token.value)
        lock.unlock()
        entry?.drop()
        return entry != nil
    }

    /// The last line of defence. Returns how many were still held.
    @discardableResult
    func releaseAll() -> Int {
        lock.lock()
        let held = entries
        entries.removeAll()
        lock.unlock()
        for (_, entry) in held.sorted(by: { $0.key < $1.key }) { entry.drop() }
        return held.count
    }

    /// Install the process-exit paths, once. Called from `VirtualDisplay.init`,
    /// so the handlers exist whenever a display does and no app wiring can
    /// forget them.
    ///
    /// Three routes out of a process, and all three are covered:
    ///
    /// * **`exit()`** — `atexit`. Runs in an ordinary thread context, so
    ///   dropping an Objective-C object there is fine.
    /// * **A signal** — `SIGTERM`, `SIGINT`, `SIGHUP`. A C signal handler may
    ///   not release Objective-C objects (it may not call `free`), so the
    ///   disposition is set to `SIG_IGN` and the delivery is picked up by a
    ///   `DispatchSourceSignal` instead — the documented pattern, and the one
    ///   where the work runs on an ordinary queue. The process then exits
    ///   itself, because ignoring the signal means nothing else will.
    /// * **An uncaught exception** — `NSSetUncaughtExceptionHandler`, chained so
    ///   an existing handler (a crash reporter) still runs.
    ///
    /// `SIGKILL` cannot be caught by anything, and a display stranded that way
    /// is WindowServer's to reap. The operational recovery for a stranded
    /// display is in REPORT-alfheim.md Part IX.
    @discardableResult
    func installProcessExitHandlers() -> Bool {
        guard claimExitHandlerInstall() else { return false }
        installRealExitHandlers()
        return true
    }

    /// The once-only claim, without the process-wide side effects. Tests use
    /// this to prove the installation happens exactly once without setting
    /// `SIG_IGN` on the test runner or replacing XCTest's exception handler.
    @discardableResult
    func installProcessExitHandlers(using install: () -> Void) -> Bool {
        guard claimExitHandlerInstall() else { return false }
        install()
        return true
    }

    private func claimExitHandlerInstall() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !exitHandlersInstalled else { return false }
        exitHandlersInstalled = true
        return true
    }

    private func installRealExitHandlers() {
        atexit {
            let n = VirtualDisplayRegistry.shared.releaseAll()
            if n > 0 { Log.info("atexit: released \(n) virtual display(s)") }
        }

        let previousExceptionHandler = NSGetUncaughtExceptionHandler()
        Self.previousUncaughtExceptionHandler = previousExceptionHandler
        NSSetUncaughtExceptionHandler { exception in
            let n = VirtualDisplayRegistry.shared.releaseAll()
            Log.info("uncaught exception (\(exception.name.rawValue)) — released \(n) virtual display(s)")
            VirtualDisplayRegistry.previousUncaughtExceptionHandler?(exception)
        }

        var sources: [DispatchSourceSignal] = []
        let queue = DispatchQueue(label: "com.opensidecar.display-exit")
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)   // or the default disposition kills us first
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler {
                let n = VirtualDisplayRegistry.shared.releaseAll()
                Log.info("signal \(sig) — released \(n) virtual display(s), exiting")
                exit(128 &+ sig)
            }
            source.resume()
            sources.append(source)
        }
        lock.lock()
        signalSources = sources
        lock.unlock()
    }

    private nonisolated(unsafe) static var previousUncaughtExceptionHandler:
        (@convention(c) (NSException) -> Void)?
}

// MARK: - The lever cap

/// How deep adaptation is allowed to go.
///
/// Round 9's ladder ended in a capture-scale change, and the scale change is
/// what cost the operator a session and a working desktop. The controller's
/// *arithmetic* was right — it settled at 3.17 Mbps / 30 fps on a link that
/// measured 2.87 — so turning the whole controller off to avoid the lever would
/// throw away the part that worked. This caps the ladder instead.
///
/// `defaults write com.peetzweg.opensidecar.mac.alfheim adaptiveMaxLever scale`
/// puts the scale rungs back. The default is `frameRate` until the scale lever
/// has been proven on a real session.
enum AdaptiveLeverCap: String, CaseIterable {
    /// Bitrate and frame rate only. The ladder stops at its lowest frame rate.
    case frameRate
    /// Everything, including the capture-scale rungs.
    case scale

    static let defaultsKey = "adaptiveMaxLever"

    /// **`frameRate`.** Not because the scale lever is broken as written — the
    /// enforcement loop it tripped over is fixed — but because the evidence
    /// that it is safe is one operator session away, and the failure mode is a
    /// desk with no working monitor on it.
    static let standard = AdaptiveLeverCap.frameRate

    /// Anything unparseable is the default, loudly typed-through rather than
    /// crashing a session on a typo.
    static func resolve(_ stored: Any?) -> AdaptiveLeverCap {
        guard let raw = stored as? String,
              let cap = AdaptiveLeverCap(rawValue:
                raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return standard }
        return cap
    }

    /// What the session-start line says.
    var explanation: String {
        switch self {
        case .frameRate:
            return "bitrate and frame rate only — the capture-scale rungs are capped out "
                + "(adaptiveMaxLever=scale re-enables them)"
        case .scale:
            return "bitrate, frame rate and capture scale (adaptiveMaxLever=scale)"
        }
    }
}
