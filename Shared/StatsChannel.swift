// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.
//
// The receiver's `stats` report is the sender's only view of the far end, and
// round 8 put it on the one channel that cannot deliver it when it matters.
//
// `stats` rides the TCP control connection — the same connection as the video.
// On a healthy link it arrives every 5 s. On the operator's LTE/DERP session it
// arrived at 15:31:00, 15:31:54, 15:32:01, 15:32:21 and 15:33:04: gaps of 54,
// 7, 20 and 43 seconds, because a report queued behind a few hundred KB of
// video on a 1 Mbps path waits for the video. The adaptive controller was
// therefore blind exactly when the link was worst, and several of its
// step-downs carry `e2e95=0ms rtt=0ms` in the log for that reason.
//
// The fix is one line of routing: send the same report as a **datagram on the
// UDP cursor channel** (PROTOCOL.md 6.3) that already exists between these two
// processes, in addition to the TCP copy. UDP has no head-of-line blocking, so
// the report overtakes the video queue; a datagram that is lost costs nothing
// because another one follows in five seconds; and the TCP copy still goes out
// so a sender that has never heard of this is unaffected.
//
// What lives here is only the part both ends must agree on: the capability
// flag, the sequence number, and the rule that decides which copy wins.

import Foundation

enum StatsChannel {

    /// `welcome.statsUdp` — the sender telling the receiver it will read stats
    /// datagrams off the cursor flow. Additive at pv 4: a receiver that does
    /// not see it simply keeps sending TCP only.
    static let capabilityKey = "statsUdp"

    /// `stats.sq` — a per-connection sequence, starting at 1, so the two
    /// copies of one report can be told apart from two reports.
    static let sequenceKey = "sq"

    /// Which copy arrived.
    enum Path: String, Equatable {
        case tcp
        case udp
    }
}

/// Which copy of a `stats` report to believe.
///
/// Both copies are always sent, and that is deliberate: suppressing the TCP
/// copy would save a few hundred bytes every five seconds and would lose the
/// report entirely whenever a datagram is dropped, which on a mobile link is
/// not rare. So both go out, the first to arrive is applied, and the second is
/// counted and discarded.
struct StatsDedupe: Equatable {

    private(set) var lastSequence: UInt64 = 0
    private(set) var acceptedViaUDP = 0
    private(set) var acceptedViaTCP = 0
    private(set) var duplicates = 0
    /// Reports from a receiver too old to stamp them. Not an error — they are
    /// applied unconditionally, exactly as before this existed.
    private(set) var unsequenced = 0

    init() {}

    /// - Returns: whether this copy is the one to act on.
    mutating func accept(sequence: UInt64?, path: StatsChannel.Path) -> Bool {
        guard let sequence else {
            // No sequence: an older receiver, which by definition sends only
            // the TCP copy, so there is nothing to deduplicate against.
            unsequenced += 1
            switch path {
            case .tcp: acceptedViaTCP += 1
            case .udp: acceptedViaUDP += 1
            }
            return true
        }
        guard sequence > lastSequence else {
            duplicates += 1
            return false
        }
        lastSequence = sequence
        switch path {
        case .tcp: acceptedViaTCP += 1
        case .udp: acceptedViaUDP += 1
        }
        return true
    }

    /// How the reports have been arriving, for the log. The interesting number
    /// is the UDP share: on a congested link it should be close to all of them,
    /// and if it is not, the datagrams are being dropped and the controller is
    /// back to steering on sender-local signals alone.
    var pathSummary: String {
        let total = acceptedViaUDP + acceptedViaTCP
        guard total > 0 else { return "no reports yet" }
        return "\(acceptedViaUDP)/\(total) via udp, \(duplicates) duplicate(s) discarded"
    }

    /// A new connection restarts the sequence, so the tracker has to as well.
    mutating func reset() {
        lastSequence = 0
        acceptedViaUDP = 0
        acceptedViaTCP = 0
        duplicates = 0
        unsequenced = 0
    }
}
