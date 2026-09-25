// Which of several sessions pointing at one physical device should survive.
//
// Pure, and in its own file, for one reason: `SenderController` cannot be
// unit-tested. It is `@MainActor`, it owns `MacSender` (ScreenCaptureKit, a
// private-API virtual display), and `ConnectionTarget.wifi` wraps an
// `NWBrowser.Result`, which has no public initializer — a test cannot even
// construct the duplicate-session fixture the decision operates on. Flattening
// the sessions to the identity facts the decision actually needs moves all of
// that out of the way, and leaves the controller with the effects: log, and
// end.

import Foundation

/// One live session, reduced to what de-duplication has to know about it.
struct SessionSnapshot: Equatable {

    /// Which of the three kinds of session this is.
    ///
    /// The distinction the incident turned on: `.manualEndpoint` and
    /// `.usbDevice` are *both* `ConnectionTarget.usb` on the controller's side
    /// (`usb:first` is `.usb(udid: nil)`), which is exactly why the old
    /// dedupe — written to drop WiFi twins — could not see the pair.
    enum Kind: Equatable {
        /// A usbmuxd session for one attached device: `usb:<udid>`.
        case usbDevice(udid: String)
        /// The `-host`/`-port` escape hatch: `usb:first`. Either a plain TCP
        /// endpoint (an iproxy or SSH tunnel) or usbmuxd's "first device",
        /// depending on whether `host` is set. Both reach a device that may
        /// also have a `usbDevice` session of its own.
        case manualEndpoint
        /// A Bonjour session: `wifi:<service name>`.
        case wifi
    }

    let id: String
    let kind: Kind
    /// A session whose `start()` threw. It holds no pipeline, so it must never
    /// win a "keep the better transport" comparison against a working one.
    let failed: Bool
    /// Whether this session's socket is actually up.
    ///
    /// **The round-6 Bonjour bug, in one field.** A `-host`/`-port` session
    /// that cannot reach its endpoint is not `failed` — `start()` succeeded,
    /// the sender is simply dialing — so it looked, to every rule here, exactly
    /// like a working session. The round-6 Mac log has 1373 consecutive
    /// `connection waiting: Connection refused — will retry` lines from one
    /// such session, and for every one of those seconds it was suppressing the
    /// Bonjour dial of the very same iPad, sitting on the same LAN, advertising
    /// itself. "Whichever is already live keeps the receiver" is the right rule
    /// and it was being applied to something that was not live.
    ///
    /// Defaults to true so every existing caller and test keeps its meaning:
    /// the only thing that changes is that a caller which *knows* a session is
    /// down can now say so.
    let connected: Bool
    /// The receiver's install id, learned from `hello`. Nil until the peer has
    /// spoken — which is the window the ping-pong lives in.
    let installID: String?
    /// Bonjour TXT `id`, for WiFi sessions whose own `hello` has not arrived.
    let txtID: String?
    /// Bonjour service name, the last-resort match for receivers too old to
    /// advertise an install id.
    let serviceName: String?
    /// For a `.manualEndpoint`: whether it is a **tunnel** (`-host`/`-port`
    /// pointing at an SSH tunnel, an iproxy or a tailnet address) rather than
    /// usbmuxd's "first attached device".
    ///
    /// The kind cannot tell them apart — both are `usb:first` — and the
    /// precedence rules need to, because they are opposite things. A
    /// usbmux-first session *is* the cable, and the cable beats everything. A
    /// tunnel is the escape hatch of last resort, and the documented precedence
    /// has always been **cable > Bonjour > manual endpoint**.
    let manualEndpointIsTunnel: Bool

    init(id: String, kind: Kind, failed: Bool = false,
         installID: String? = nil, txtID: String? = nil, serviceName: String? = nil,
         connected: Bool = true, manualEndpointIsTunnel: Bool = false) {
        self.id = id
        self.kind = kind
        self.failed = failed
        self.installID = installID
        self.txtID = txtID
        self.serviceName = serviceName
        self.connected = connected
        self.manualEndpointIsTunnel = manualEndpointIsTunnel
    }

    /// A session that is actually serving its receiver right now.
    var isLive: Bool { !failed && connected }

    var isUSBTarget: Bool {
        switch kind {
        case .usbDevice, .manualEndpoint: return true
        case .wifi: return false
        }
    }

    var usbUDID: String? {
        if case .usbDevice(let udid) = kind { return udid }
        return nil
    }
}

/// The rule, in one sentence: **one session per physical device, and the cable
/// wins.**
enum SessionDedupe {

    /// The ids of the sessions to end, because another session already serves
    /// the same receiver over a better transport.
    ///
    /// - Parameters:
    ///   - sessions: every live session.
    ///   - cabledDeviceNames: lockdown names of attached devices that already
    ///     have a working `usb:<udid>` session. The fallback identity match for
    ///     receivers too old to announce an install id.
    ///   - attachedUDIDs: which devices are on the cable *right now*. A USB
    ///     session whose device has just been unplugged is on its way out and
    ///     must not be allowed to evict the manual endpoint on the way.
    static func duplicateSessionIDs(_ sessions: [SessionSnapshot],
                                    cabledDeviceNames: Set<String>,
                                    attachedUDIDs: Set<String>) -> [String] {
        // For the WiFi rule, every session on a USB *target* counts — including
        // the manual endpoint, which is `.usb(udid: nil)`. That is the
        // behaviour this fork inherited and there is nothing wrong with it: a
        // manual endpoint that has proved which device it reaches is as good a
        // reason to drop a WiFi twin as a cable is.
        //
        // Round 7 narrows it by exactly one case: a manual endpoint that is a
        // **tunnel** no longer evicts a WiFi twin. `usb:first` over usbmuxd is
        // the cable and still does; `-host <tailnet address>` is not, and the
        // precedence this file has documented since round 5 is cable > Bonjour
        // > manual endpoint. Enforcing only the first half of that is what let
        // a tailnet session hold a receiver that was sitting on the same LAN.
        let usbTargetInstallIDs = Set(sessions.compactMap { s -> String? in
            guard s.isUSBTarget, !s.failed else { return nil }
            if case .manualEndpoint = s.kind, s.manualEndpointIsTunnel { return nil }
            return s.installID
        })
        // For the manual rule, only a real, still-attached cable counts.
        let cabledInstallIDs = Set(sessions.compactMap { s -> String? in
            guard !s.failed, let udid = s.usbUDID, attachedUDIDs.contains(udid) else { return nil }
            return s.installID
        })
        // ...and, from round 7, a **connected** Bonjour session that has said
        // hello. The documented precedence has always been cable > Bonjour >
        // manual endpoint, and until now only the first half was enforced: a
        // `-host`/`-port` session and a LAN session could both reach one iPad
        // and take its single connection from each other. Requiring `installID`
        // (i.e. a hello) as well as `isLive` is what keeps this from killing a
        // working tunnel for a LAN session that has not proved anything yet.
        let liveWiFiInstallIDs = Set(sessions.compactMap { s -> String? in
            guard case .wifi = s.kind, s.isLive else { return nil }
            return s.installID
        })

        var doomed: [String] = []
        for s in sessions {
            switch s.kind {
            case .wifi:
                let duplicate = (s.installID.map { usbTargetInstallIDs.contains($0) } ?? false)
                    || (s.txtID.map { usbTargetInstallIDs.contains($0) } ?? false)
                    || (s.serviceName.map { cabledDeviceNames.contains($0) } ?? false)
                if duplicate { doomed.append(s.id) }
            case .manualEndpoint:
                // The incident this was written for: with the iPad cabled, the
                // sender ran `usb:first` *and* `usb:<udid>` against one
                // receiver. The receiver adopts one connection at a time, so
                // the two took it from each other roughly every two seconds,
                // forever. Same rule as WiFi — the cable wins.
                guard !s.failed, let id = s.installID else { continue }
                // A tunnel loses to a live LAN session; a usbmux-first session
                // never does (it *is* the cable). Asymmetric on purpose — a
                // rule where each could evict the other would kill both.
                if cabledInstallIDs.contains(id)
                    || (s.manualEndpointIsTunnel && liveWiFiInstallIDs.contains(id)) {
                    doomed.append(s.id)
                }
            case .usbDevice:
                continue
            }
        }
        return doomed
    }

    /// Whether a session that has just said `hello` may go on to build its
    /// virtual display and start its encoders — asked **before** either
    /// exists.
    ///
    /// `duplicateSessionIDs` below is a *post-hoc* rule: it compares two
    /// identities that have both already been learned, which by construction
    /// is after both sessions built a display. The 20:25 incident is what that
    /// costs — `usb:first` and `usb:<udid>` created displays 139 and 140 340 ms
    /// apart, both started an audio encoder, and the loser was dropped only
    /// afterwards. The user saw a display appear and vanish, and heard the same
    /// sound twice.
    ///
    /// This rule answers earlier because it does not need the *other* session's
    /// hello: `installIDByUDID` is persisted, so the moment this session names
    /// its receiver we can already say "that receiver is on the cable".
    ///
    /// - Parameters:
    ///   - candidate: the session that just said hello.
    ///   - helloInstallID: the id from *this* hello (the snapshot may predate it).
    ///   - others: every other live session.
    ///   - cabledUDIDs: devices on the cable that this app will actually drive
    ///     — attached, not opted out of auto-connect, and not sitting on a
    ///     session that failed to start. A cable nobody is going to dial must
    ///     not be allowed to veto the only transport that works.
    ///   - installIDByUDID: the persisted udid → receiver install id map.
    static func admits(_ candidate: SessionSnapshot,
                       helloInstallID: String? = nil,
                       others: [SessionSnapshot],
                       cabledUDIDs: Set<String>,
                       installIDByUDID: [String: String]) -> Bool {
        // The cable always wins, so a cabled session never stands down. Two
        // cables are two devices, and each deserves its own display.
        if case .usbDevice = candidate.kind { return true }
        guard let id = helloInstallID ?? candidate.installID else { return true }

        // The receiver is on the cable — that session either exists already or
        // is about to be dialed by `autoConnect()`.
        if cabledUDIDs.contains(where: { installIDByUDID[$0] == id }) { return false }

        // Or a live cable session has already identified itself as this
        // receiver (an id learned in-session, never persisted).
        return !others.contains { s in
            guard s.id != candidate.id, !s.failed,
                  let udid = s.usbUDID, cabledUDIDs.contains(udid) else { return false }
            return s.installID == id
        }
    }

    /// Manual-endpoint sessions to end because the cable already covers the
    /// same receiver.
    ///
    /// Unlike `duplicateSessionIDs` this can answer for a manual session that
    /// has **not said hello yet**, by falling back to the persisted
    /// `manualEndpointInstallID` — which is exactly the window in which the
    /// loser would otherwise get as far as creating a display.
    static func manualEndpointsCoveredByCable(_ sessions: [SessionSnapshot],
                                              cabledUDIDs: Set<String>,
                                              installIDByUDID: [String: String],
                                              knownInstallID: String?) -> [String] {
        sessions.compactMap { s in
            guard case .manualEndpoint = s.kind else { return nil }
            guard let id = s.installID ?? knownInstallID else { return nil }
            guard cabledUDIDs.contains(where: { installIDByUDID[$0] == id }) else { return nil }
            return s.id
        }
    }

    /// Whether `autoConnect()` may dial the manual endpoint.
    ///
    /// Ending the duplicate is only half the fix: `autoConnect()` runs on every
    /// hello, every browse event and every usbmux publish, and re-dialed
    /// `usb:first` the instant it saw no session with that id — which is how a
    /// one-off collision became a loop. So the same identity check gates the
    /// dial.
    ///
    /// The gate is deliberately keyed on the device being **attached**, not on
    /// a session merely existing. That is what re-arms the manual endpoint when
    /// the cable is pulled: the watcher publishes the new device list, the udid
    /// leaves `attachedUDIDs`, and the next `autoConnect()` — which the watcher
    /// calls immediately after `failover` — dials it again with no extra state
    /// to reset.
    static func shouldDialManualEndpoint(sessions: [SessionSnapshot],
                                         attachedUDIDs: Set<String>,
                                         installIDByUDID: [String: String] = [:],
                                         knownInstallID: String?) -> Bool {
        // Already running: the existing one-session-per-id rule.
        if sessions.contains(where: { $0.kind == .manualEndpoint }) { return false }
        // Never connected, so there is nothing to compare — dial and find out.
        guard let knownInstallID else { return true }
        // A Bonjour session already reaches this receiver. **Bonjour beats the
        // manual endpoint**: the manual endpoint is `-host`/`-port`, an
        // explicit debugging escape hatch that usually points at a tunnel, and
        // the direct LAN path is both shorter and self-healing. Without this
        // the two would take the receiver's single connection from each other
        // exactly the way `usb:first` and `usb:<udid>` did in round 4.
        if servesInstallID(knownInstallID, in: sessions, kinds: [.wifi]) { return false }
        // The identity-first gate, and the one that closes the launch race:
        // `installIDByUDID` is persisted, so an attached device is recognized
        // as this receiver **before** anything has dialed it, let alone before
        // its hello. The session-based check below could only answer after the
        // USB session had spoken — by which time both endpoints had a display.
        if attachedUDIDs.contains(where: { installIDByUDID[$0] == knownInstallID }) { return false }
        let covered = sessions.contains { s in
            guard !s.failed, let udid = s.usbUDID, attachedUDIDs.contains(udid) else { return false }
            return s.installID == knownInstallID
        }
        return !covered
    }

    /// Tunnel manual endpoints to retire because a live Bonjour session already
    /// reaches the same receiver.
    ///
    /// `shouldDialManualEndpoint` refuses to *start* one in this state
    /// (Bonjour beats the manual endpoint), but nothing retired one that was
    /// already running — and at launch there always is one: the manual
    /// endpoint is dialed before any browse result has arrived, so the order is
    /// always "tunnel first, Bonjour second". The tunnel then sits in its
    /// redial loop for as long as the app runs.
    ///
    /// On alfheim-home that is the whole of the idle log: a dial to the iPad's
    /// tailnet name stays in `.preparing` while the iPad is on the LAN with
    /// Tailscale idle, so every 5 s deadline fires, logs, and redials, forever.
    /// It is also a session row that never delivers anything, which is the
    /// shape that made a waiting dialer look like a live stream and mute the
    /// Mac (2026-09-22 incident).
    ///
    /// Three conditions, each load-bearing:
    ///
    /// * **tunnel only.** A usbmux `usb:first` *is* the cable, and the cable
    ///   beats Bonjour. Only the `-host`/`-port` flavour loses.
    /// * **not connected.** A tunnel that is actually carrying the session is
    ///   not a duplicate to be swept up here; `duplicateSessionIDs` owns that
    ///   comparison, with the hello it needs.
    /// * **the Bonjour session is connected.** Retiring the fallback because of
    ///   a LAN session that is itself only dialing would leave the receiver
    ///   with nothing — the round-6 mistake, in the other direction.
    ///
    /// Re-arming needs no state: `autoConnect()` runs on every browse event and
    /// every hello, and once the Bonjour session is gone
    /// `shouldDialManualEndpoint` dials the endpoint again.
    static func manualTunnelsCoveredByLAN(_ sessions: [SessionSnapshot],
                                          knownInstallID: String?) -> [String] {
        let lanIsUp = sessions.contains { s in
            guard case .wifi = s.kind, !s.failed, s.connected else { return false }
            guard let knownInstallID else { return false }
            return s.installID == knownInstallID || s.txtID == knownInstallID
        }
        guard lanIsUp else { return [] }
        return sessions.compactMap { s in
            guard s.kind == .manualEndpoint, s.manualEndpointIsTunnel,
                  !s.connected, !s.failed else { return nil }
            return s.id
        }
    }

    // MARK: - Bonjour for receivers we already know

    /// Whether any live session of one of `kinds` already serves `installID`.
    ///
    /// Matches on the id the session *learned* (`hello`) or, for a Bonjour
    /// session, on its TXT id — browse results routinely arrive before the
    /// hello does, and "wait for the hello" is exactly the window in which two
    /// sessions get built.
    private static func servesInstallID(_ installID: String,
                                        in sessions: [SessionSnapshot],
                                        kinds: [SessionSnapshot.Kind]) -> Bool {
        sessions.contains { s in
            guard !s.failed, kinds.contains(s.kind) else { return false }
            return s.installID == installID || s.txtID == installID
        }
    }

    /// A Bonjour service this Mac is allowed to dial on sight.
    struct BonjourCandidate: Equatable {
        /// `wifi:<service name>`, i.e. what the session would be called.
        let sessionID: String
        /// The receiver install id from the service's TXT record.
        ///
        /// **Often nil, and that was half of the round-6 bug.**
        /// `NWBrowser.Result.metadata` is `.bonjour(...)` only once the TXT
        /// record has actually been delivered; a result can — and on this LAN
        /// routinely does — arrive as `.none`, especially the first time a
        /// service appears and after a WiFi roam. Round 5's rule was
        /// `guard let id = candidate.txtID`, so a browse result without its TXT
        /// was not "unknown", it was invisible: no match, no log line, no
        /// decision.
        let txtID: String?
        /// The advertised service name. The fallback identity, and the one
        /// that is always present — `.service(name:…)` is the endpoint itself,
        /// not metadata, so it cannot be missing.
        let serviceName: String?

        init(sessionID: String, txtID: String? = nil, serviceName: String? = nil) {
            self.sessionID = sessionID
            self.txtID = txtID
            self.serviceName = serviceName
        }
    }

    /// How a browse result was recognized (or not). Ordered by strength.
    enum BonjourMatch: Equatable {
        case txtRecord
        case serviceName
        case none
    }

    /// What was decided about one browse result, and why — so the log can say
    /// it. Round 6's log had **no line at all** for a browse result that did
    /// not match, which made "the TXT was missing", "the id was not known" and
    /// "something else already serves it" the same observation: silence.
    struct BonjourDecision: Equatable {
        let sessionID: String
        let serviceName: String?
        let txtID: String?
        /// The install id this service was recognized as, if any.
        let matchedID: String?
        let matchedBy: BonjourMatch
        let dial: Bool
        let reason: String

        var logLine: String {
            var line = "bonjour: \(serviceName ?? sessionID)"
            line += " txt=\(txtID ?? "—")"
            switch matchedBy {
            case .txtRecord:  line += " matched by TXT id \(matchedID ?? "?")"
            case .serviceName: line += " matched by remembered name → \(matchedID ?? "?")"
            case .none:       line += " unrecognized"
            }
            line += dial ? " — DIALING" : " — not dialing: \(reason)"
            return line
        }
    }

    /// Bonjour services to auto-connect **at any time**, because they name a
    /// receiver this Mac already knows.
    ///
    /// The rule this replaces was: remember a service *name* in
    /// `wifiRemembered`, and re-dial it only in a 12 s window at launch. Both
    /// halves failed the operator. The name half breaks whenever the device is
    /// renamed or a second receiver shares a name; the 12 s half means that
    /// without Tailscale — i.e. with nothing but Bonjour to find the iPad —
    /// **nothing connects**, because a receiver that appears 13 seconds after
    /// the Mac app launched is never dialed at all. Their words: "without
    /// Tailscale on the LAN nothing connects."
    ///
    /// Identity, not names, and no deadline: a service whose TXT `id` is a
    /// receiver install id this Mac has already talked to (over the cable, over
    /// the manual endpoint, or over Bonjour) is the same physical device, and
    /// dialing it is what the user has already asked for once.
    ///
    /// Precedence is unchanged and total: **cable > Bonjour > manual
    /// endpoint.** An unknown receiver is not dialed at all — `wifiRemembered`
    /// still governs those, with its launch window, because "a device the user
    /// has never connected appeared on the network" is not consent.
    static func knownBonjourToDial(candidates: [BonjourCandidate],
                                   sessions: [SessionSnapshot],
                                   knownInstallIDs: Set<String>,
                                   cabledUDIDs: Set<String>,
                                   installIDByUDID: [String: String],
                                   manualEndpointInstallID: String?,
                                   installIDByServiceName: [String: String] = [:]) -> [String] {
        bonjourDecisions(candidates: candidates,
                         sessions: sessions,
                         knownInstallIDs: knownInstallIDs,
                         cabledUDIDs: cabledUDIDs,
                         installIDByUDID: installIDByUDID,
                         manualEndpointInstallID: manualEndpointInstallID,
                         installIDByServiceName: installIDByServiceName)
            .filter(\.dial).map(\.sessionID)
    }

    /// The same rule, with its reasoning attached — one decision per browse
    /// result, in the order they were offered.
    ///
    /// - Parameter installIDByServiceName: service name → install id, learned
    ///   and persisted every time a WiFi session says hello. The fallback for a
    ///   browse result whose TXT record has not been delivered. It is a
    ///   *weaker* claim than the TXT id — a renamed device is a different name,
    ///   and two devices could in principle share one — so it is only ever used
    ///   when the TXT is absent, and only for a name this Mac has itself seen
    ///   paired with an id.
    static func bonjourDecisions(candidates: [BonjourCandidate],
                                 sessions: [SessionSnapshot],
                                 knownInstallIDs: Set<String>,
                                 cabledUDIDs: Set<String>,
                                 installIDByUDID: [String: String],
                                 manualEndpointInstallID: String?,
                                 installIDByServiceName: [String: String] = [:])
        -> [BonjourDecision] {
        var dialing = Set<String>()
        var decisions: [BonjourDecision] = []

        func decide(_ c: BonjourCandidate, _ id: String?, _ how: BonjourMatch,
                    _ dial: Bool, _ reason: String) -> BonjourDecision {
            BonjourDecision(sessionID: c.sessionID, serviceName: c.serviceName,
                            txtID: c.txtID, matchedID: id, matchedBy: how,
                            dial: dial, reason: reason)
        }

        for candidate in candidates {
            // Identity, strongest first.
            var matchedBy = BonjourMatch.none
            var id: String?
            if let txt = candidate.txtID, knownInstallIDs.contains(txt) {
                id = txt
                matchedBy = .txtRecord
            } else if candidate.txtID == nil, let name = candidate.serviceName,
                      let remembered = installIDByServiceName[name],
                      knownInstallIDs.contains(remembered) {
                id = remembered
                matchedBy = .serviceName
            }

            guard let id else {
                decisions.append(decide(candidate, nil, .none, false,
                                        candidate.txtID == nil
                                        ? "no TXT id, and this service name has never been paired with a receiver this Mac knows"
                                        : "TXT id is not a receiver this Mac has connected to before"))
                continue
            }
            // One dial per receiver per pass, even if it advertises twice.
            if dialing.contains(id) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "the same receiver is already being dialed on another interface"))
                continue
            }
            // Already running, or already being retried by its own session.
            if sessions.contains(where: { $0.id == candidate.sessionID && !$0.failed }) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "this service already has a session"))
                continue
            }
            // Another Bonjour session already reaches this receiver.
            if servesInstallID(id, in: sessions, kinds: [.wifi]) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "another Bonjour session already serves this receiver"))
                continue
            }
            // A manual endpoint reaches it — but only a **connected** one
            // counts. See `SessionSnapshot.connected`: a `-host`/`-port`
            // session stuck on "Connection refused — will retry" is not
            // serving anybody, and letting it veto the LAN path is what made
            // "press Connect by hand" the only way onto the LAN.
            if sessions.contains(where: { s in
                s.kind == .manualEndpoint && s.isLive
                    && (s.installID == id || s.txtID == id)
            }) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "a connected -host/-port session already serves this receiver"))
                continue
            }
            // A cable session serves it — but only while the cable is still
            // attached. This is the round-6 rule ("whichever is already live
            // keeps the receiver" must not be applied to something that is not
            // live) on the USB side, where it was never applied: the gate below
            // for `-host`/`-port` requires `isLive`, this one asked only that a
            // session object exist. A USB session outlives the detach — it goes
            // to "Waiting for a USB device — plug in the iPhone or iPad…" and
            // waits for a replug — so after 2026-09-22 17:54, when the operator
            // unplugged the iPad, every Bonjour result was refused with "a cable
            // session already serves this receiver" while the iPad sat on the
            // same LAN advertising itself, until the sender was restarted.
            //
            // `cabledUDIDs` is the attachment fact and was already a parameter
            // here, used by the three neighbouring gates; only this one ignored
            // it. Matching still allows the id the session learned from `hello`,
            // for a cable whose udid is not in `installIDByUDID` yet.
            if sessions.contains(where: { s in
                guard !s.failed, let udid = s.usbUDID,
                      cabledUDIDs.contains(udid) else { return false }
                return s.installID == id || installIDByUDID[udid] == id
            }) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "a cable session already serves this receiver"))
                continue
            }
            // The cable covers it (or is about to): the cable always wins.
            if cabledUDIDs.contains(where: { installIDByUDID[$0] == id }) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "this receiver is on the cable"))
                continue
            }
            // A manual endpoint that has not said hello yet still counts, via
            // the id it reached last time — same pre-emptive trick as
            // `manualEndpointsCoveredByCable`. Again, only while it is actually
            // connected.
            if manualEndpointInstallID == id,
               sessions.contains(where: { $0.kind == .manualEndpoint && $0.isLive }) {
                decisions.append(decide(candidate, id, matchedBy, false,
                                        "a connected -host/-port session last reached this receiver"))
                continue
            }
            dialing.insert(id)
            decisions.append(decide(candidate, id, matchedBy, true, ""))
        }
        return decisions
    }
}
