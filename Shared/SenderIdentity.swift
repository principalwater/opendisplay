// Which Mac is driving this receiver, and what to do when it is the wrong one.
//
// Compiled into BOTH apps (see `project.yml` `sources`), Foundation-only, and
// also into the Mac test bundle — everything here is a decision, and the
// decisions are the part that must not be wrong.
//
// The problem, in the operator's words: two Macs (a Studio and a MacBook Pro),
// both on the same LAN and the same tailnet, both running senders, and "the
// first sender to dial wins instantly". Senders are the dialers — the receiver
// listens — so the receiver is the only party that can arbitrate, and the only
// thing it needs in order to do so is to know who is calling.

import Foundation

/// A sender, as the receiver sees it.
struct SenderIdentity: Equatable, Identifiable, Hashable {
    /// A UUID the sender persists in its own defaults. Stable across restarts,
    /// renames and network changes — which is the point: the user picks a
    /// familiar Mac, not whichever address it happens to have today.
    let id: String
    /// The Mac's computer name, for the user to recognise it by. May change;
    /// the id may not.
    var host: String

    init(id: String, host: String) {
        self.id = id
        self.host = host
    }

    var displayName: String { host.isEmpty ? id : host }
}

/// The sender's own identity, persisted.
enum SenderIdentityStore {
    static let senderIDKey = "senderID"

    /// Read-or-create. A UUID rather than the host name because host names
    /// collide, change, and are localized; and in the sender's own defaults
    /// domain, so the fork and a stock build are different Macs as far as any
    /// receiver is concerned — which is correct, they are different senders.
    static func localSenderID(_ defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: senderIDKey), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: senderIDKey)
        return fresh
    }
}

/// Receiver-side: which Mac the user wants, and what happens to the others.
enum SenderChoice {

    static let preferredKey = "preferredSenderID"
    static let knownSendersKey = "knownSenders"

    /// "Any Mac" — the default, and the behaviour every build before this one
    /// had: whoever dials first gets the screen.
    static let anyMac = ""

    /// A refused sender checks again soon enough to follow a receiver-side
    /// choice change. Rejection happens before display and encoder setup, so
    /// this inexpensive dial also works when Bonjour cannot cross a tailnet.
    static let defaultRetryAfterMs = 2_000

    /// Give the previously connected sender time to yield to the new choice.
    /// It remains refused while the preference names another Mac.
    static let switchRetryAfterMs = 5_000

    /// Whether a sender that has just identified itself should be refused.
    ///
    /// A sender with **no** `senderID` — anything built before this round,
    /// including a stock OpenDisplay — is refused whenever a preference is set.
    /// That is deliberate and it is the only coherent answer: it cannot be the
    /// chosen one (there is nothing to choose), so accepting it would mean the
    /// preference silently does not apply to exactly the Mac the user did not
    /// pick. Selecting "Any Mac" takes every sender back.
    static func shouldReject(preferred: String, senderID: String?) -> Bool {
        guard !preferred.isEmpty else { return false }
        return senderID != preferred
    }

    /// Add or update a sender in the remembered list, newest first.
    ///
    /// Keyed on the id, so a Mac that was renamed updates its label instead of
    /// appearing twice — and stays in the position the user is used to seeing
    /// it in rather than jumping to the top on every reconnect.
    static func merge(_ known: [SenderIdentity], seen: SenderIdentity) -> [SenderIdentity] {
        guard !seen.id.isEmpty else { return known }
        if let index = known.firstIndex(where: { $0.id == seen.id }) {
            var updated = known
            if !seen.host.isEmpty { updated[index].host = seen.host }
            return updated
        }
        return known + [seen]
    }

    /// A preference pointing at a sender that is no longer in the list would be
    /// a receiver that refuses everything with no way back from the UI. Forget
    /// it instead.
    static func validate(preferred: String, against known: [SenderIdentity]) -> String {
        guard !preferred.isEmpty else { return anyMac }
        return known.contains { $0.id == preferred } ? preferred : anyMac
    }

    // MARK: Persistence

    static func decode(_ stored: Any?) -> [SenderIdentity] {
        guard let array = stored as? [[String: String]] else { return [] }
        return array.compactMap { dict in
            guard let id = dict["id"], !id.isEmpty else { return nil }
            return SenderIdentity(id: id, host: dict["host"] ?? "")
        }
    }

    static func encode(_ list: [SenderIdentity]) -> [[String: String]] {
        list.map { ["id": $0.id, "host": $0.host] }
    }
}

/// The `rejected` control message (PROTOCOL.md 6.6): receiver → sender,
/// "not you, try again later".
///
/// Additive, like everything else this fork put on the wire: a sender that does
/// not know the type ignores it, and the receiver closing the connection
/// afterwards is something every sender already handles as an ordinary
/// disconnect. The type is what turns "dropped for no reason, redial at once"
/// into "refused on purpose, wait".
enum RejectionMessage {
    static let type = "rejected"
    static let reasonOtherMacSelected = "otherMacSelected"

    /// Bounds on the backoff a *peer* asks for. The wire is unauthenticated, so
    /// this is a peer-supplied number that decides how long this Mac stops
    /// working: one second at the least (a zero would be a redial storm), ten
    /// minutes at the most (nothing legitimate asks for longer, and a session
    /// the user can only fix by quitting the app is not acceptable).
    static let minRetryAfterMs = 1_000
    static let maxRetryAfterMs = 600_000

    static func clampRetryAfterMs(_ raw: Any?) -> Int {
        let requested = (raw as? Int) ?? (raw as? Double).map(Int.init) ?? SenderChoice.defaultRetryAfterMs
        return min(max(requested, minRetryAfterMs), maxRetryAfterMs)
    }

    static func payload(retryAfterMs: Int, reason: String) -> [String: Any] {
        ["type": type, "retryAfterMs": retryAfterMs, "reason": reason]
    }

    /// The machine-readable marker the external watchdog greps for. One token
    /// per line, epoch seconds, so `grep -o 'rejected-by-receiver until=[0-9]*'`
    /// is the whole parser.
    static func markerLine(until: Date, receiver: String, reason: String) -> String {
        "rejected-by-receiver until=\(Int(until.timeIntervalSince1970)) "
            + "receiver=\(receiver) reason=\(reason)"
    }
}

/// Sender-side: which dial targets are currently serving out a refusal.
///
/// Pure and separate from `SenderController` for the usual reason — the
/// controller is `@MainActor` and owns `NWBrowser.Result`, which has no public
/// initializer. What matters here is only that a refused target is not dialed
/// again for exactly as long as it asked, and that it *is* dialed again after.
struct RejectionBackoff: Equatable {

    private var until: [String: Date] = [:]

    init() {}

    mutating func note(_ sessionID: String, until deadline: Date) {
        self.until[sessionID] = deadline
    }

    func isSuppressed(_ sessionID: String, at now: Date) -> Bool {
        guard let deadline = until[sessionID] else { return false }
        return now < deadline
    }

    func remaining(_ sessionID: String, at now: Date) -> TimeInterval {
        guard let deadline = until[sessionID] else { return 0 }
        return max(0, deadline.timeIntervalSince(now))
    }

    func deadline(_ sessionID: String) -> Date? { until[sessionID] }

    /// The user asked for this one explicitly: a refusal is not something to
    /// hold against a deliberate click.
    mutating func clear(_ sessionID: String) {
        until.removeValue(forKey: sessionID)
    }

    /// Drop deadlines that have passed, so the map does not grow for the life
    /// of the process.
    mutating func prune(at now: Date) {
        until = until.filter { $0.value > now }
    }

    var suppressedIDs: [String] { Array(until.keys) }
}
