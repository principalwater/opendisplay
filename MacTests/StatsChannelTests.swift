import XCTest

/// The `stats` report's second channel.
///
/// Every report is now sent twice — once over TCP, once as a datagram on the
/// UDP cursor flow — because on the operator's LTE/DERP session the TCP copy
/// queued behind the video and arrived every 7 to 54 seconds instead of every
/// 5. What is tested here is the rule that turns two copies of one report back
/// into one report.
final class StatsChannelTests: XCTestCase {

    func testTheWireKeysAreTheOnesDocumented() {
        XCTAssertEqual(StatsChannel.capabilityKey, "statsUdp")
        XCTAssertEqual(StatsChannel.sequenceKey, "sq")
        XCTAssertEqual(StatsChannel.Path.udp.rawValue, "udp")
        XCTAssertEqual(StatsChannel.Path.tcp.rawValue, "tcp")
    }

    func testTheFirstCopyToArriveWins() {
        var dedupe = StatsDedupe()
        XCTAssertTrue(dedupe.accept(sequence: 1, path: .udp))
        XCTAssertFalse(dedupe.accept(sequence: 1, path: .tcp),
                       "the TCP copy of a report already applied is a duplicate")
        XCTAssertEqual(dedupe.acceptedViaUDP, 1)
        XCTAssertEqual(dedupe.acceptedViaTCP, 0)
        XCTAssertEqual(dedupe.duplicates, 1)
    }

    func testEitherChannelMayWin() {
        var dedupe = StatsDedupe()
        XCTAssertTrue(dedupe.accept(sequence: 1, path: .tcp))
        XCTAssertFalse(dedupe.accept(sequence: 1, path: .udp))
        XCTAssertTrue(dedupe.accept(sequence: 2, path: .udp))
        XCTAssertEqual(dedupe.acceptedViaTCP, 1)
        XCTAssertEqual(dedupe.acceptedViaUDP, 1)
    }

    func testAReorderedDatagramIsNotAppliedAfterANewerReport() {
        // UDP reorders. A stale report applied after a fresh one would hand the
        // congestion controller last minute's link.
        var dedupe = StatsDedupe()
        XCTAssertTrue(dedupe.accept(sequence: 7, path: .udp))
        XCTAssertFalse(dedupe.accept(sequence: 6, path: .udp))
        XCTAssertEqual(dedupe.lastSequence, 7)
    }

    func testALostDatagramCostsNothingBecauseTheSequenceOnlyHasToIncrease() {
        var dedupe = StatsDedupe()
        XCTAssertTrue(dedupe.accept(sequence: 1, path: .udp))
        XCTAssertTrue(dedupe.accept(sequence: 5, path: .udp), "reports 2–4 never arrived")
        XCTAssertEqual(dedupe.acceptedViaUDP, 2)
    }

    func testAReceiverTooOldToStampItsReportsIsStillHeard() {
        // Every build before this one sends `stats` with no `sq`, over TCP
        // only. There is nothing to deduplicate against, so every one applies.
        var dedupe = StatsDedupe()
        XCTAssertTrue(dedupe.accept(sequence: nil, path: .tcp))
        XCTAssertTrue(dedupe.accept(sequence: nil, path: .tcp))
        XCTAssertEqual(dedupe.unsequenced, 2)
        XCTAssertEqual(dedupe.duplicates, 0)
        XCTAssertEqual(dedupe.acceptedViaTCP, 2)
    }

    func testTheSummarySaysHowTheReportsAreArriving() {
        var dedupe = StatsDedupe()
        XCTAssertEqual(dedupe.pathSummary, "no reports yet")
        _ = dedupe.accept(sequence: 1, path: .udp)
        _ = dedupe.accept(sequence: 1, path: .tcp)
        _ = dedupe.accept(sequence: 2, path: .udp)
        _ = dedupe.accept(sequence: 2, path: .tcp)
        XCTAssertEqual(dedupe.pathSummary, "2/2 via udp, 2 duplicate(s) discarded")
    }

    func testANewConnectionRewindsTheTracker() {
        // The sequence restarts with the TCP connection (PROTOCOL.md 6.3). A
        // tracker that did not rewind with it would read the whole of the next
        // session's telemetry as duplicate, and the controller would go blind.
        var dedupe = StatsDedupe()
        for sequence in UInt64(1)...20 { _ = dedupe.accept(sequence: sequence, path: .udp) }
        dedupe.reset()
        XCTAssertEqual(dedupe.lastSequence, 0)
        XCTAssertTrue(dedupe.accept(sequence: 1, path: .tcp))
        XCTAssertEqual(dedupe.acceptedViaUDP, 0)
        XCTAssertEqual(dedupe.duplicates, 0)
    }
}
