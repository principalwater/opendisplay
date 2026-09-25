import XCTest

/// Audio identity: the sequence number, the duplicate detector, and the rule
/// the whole thing exists for — **each packet is played exactly once** (§44).
///
/// Round 6 closed the scheduling half of the echo (`AudioScheduleLedger`) and
/// left the enqueue half open, because there was nothing on the wire that could
/// answer "have I already queued this packet?". `ptsMs` cannot: it is
/// wall-clock milliseconds as a `Double`, two packets in the same millisecond
/// compare equal, and a reconnecting sender keeps counting time.
final class AudioSequenceTests: XCTestCase {

    private func packet(_ seq: UInt32?, ptsMs: Double, byte: UInt8 = 0) -> AudioPacket {
        AudioPacket(sampleRate: 48000, channels: 2, ptsMs: ptsMs,
                    sequence: seq, payload: Data([byte]))
    }

    // MARK: - The wire

    func testAPacketWithoutASequenceIsByteForByteWhatItAlwaysWas() {
        // The compatibility promise: a receiver that never asked for the field
        // must receive the exact bytes it received before.
        let p = AudioPacket(hasConfig: true, sampleRate: 48000, channels: 2,
                            ptsMs: 1234.5, payload: Data([1, 2, 3]))
        let encoded = p.encoded()
        XCTAssertEqual(encoded.count, AudioPacket.headerSize + 3)
        XCTAssertEqual(encoded[1] & AudioPacket.flagHasSequence, 0)
        let decoded = AudioPacket.decode(encoded)
        XCTAssertNil(decoded?.sequence)
        XCTAssertEqual(decoded?.payload, Data([1, 2, 3]))
        XCTAssertEqual(decoded?.hasConfig, true)
    }

    func testASequencedPacketRoundTrips() {
        let p = AudioPacket(sampleRate: 44100, channels: 1, ptsMs: -7.5,
                            sequence: 0xDEADBEEF, payload: Data([9, 8]))
        let decoded = AudioPacket.decode(p.encoded())
        XCTAssertEqual(decoded?.sequence, 0xDEADBEEF)
        XCTAssertEqual(decoded?.payload, Data([9, 8]))
        XCTAssertEqual(decoded?.sampleRate, 44100)
        XCTAssertEqual(decoded?.channels, 1)
        XCTAssertEqual(decoded?.ptsMs, -7.5)
    }

    func testTheTwoFlagsAreIndependent() {
        let both = AudioPacket(hasConfig: true, sampleRate: 48000, channels: 2,
                               ptsMs: 0, sequence: 7, payload: Data([1]))
        let decoded = AudioPacket.decode(both.encoded())
        XCTAssertEqual(decoded?.hasConfig, true)
        XCTAssertEqual(decoded?.sequence, 7)
    }

    func testAPacketThatClaimsASequenceButIsTooShortIsRefused() {
        // Refused rather than read as unsequenced: four bytes of integer handed
        // to an AAC decoder as audio is silent corruption, which is the whole
        // reason the field is flagged rather than always present.
        var bytes = AudioPacket(sampleRate: 48000, channels: 2, ptsMs: 0,
                                payload: Data()).encoded()
        bytes[1] |= AudioPacket.flagHasSequence
        XCTAssertNil(AudioPacket.decode(bytes))
    }

    func testDecodingSurvivesASliceThatDoesNotStartAtZero() {
        let p = AudioPacket(sampleRate: 48000, channels: 2, ptsMs: 11,
                            sequence: 42, payload: Data([5, 5, 5]))
        let padded = Data([0xFF, 0xFF]) + p.encoded()
        let decoded = AudioPacket.decode(padded.suffix(from: padded.startIndex + 2))
        XCTAssertEqual(decoded?.sequence, 42)
        XCTAssertEqual(decoded?.payload, Data([5, 5, 5]))
    }

    // MARK: - The tracker

    func testAnOrderedRunIsAllFresh() {
        var tracker = AudioSequenceTracker()
        for seq in UInt32(0)..<100 {
            XCTAssertEqual(tracker.observe(seq), .fresh(gap: 0))
        }
        XCTAssertEqual(tracker.accepted, 100)
        XCTAssertEqual(tracker.duplicates, 0)
        XCTAssertEqual(tracker.lost, 0)
        XCTAssertFalse(tracker.hasAnythingToReport)
    }

    func testARepeatedPacketIsADuplicate() {
        var tracker = AudioSequenceTracker()
        _ = tracker.observe(1)
        _ = tracker.observe(2)
        XCTAssertEqual(tracker.observe(2), .duplicate)
        XCTAssertEqual(tracker.observe(1), .duplicate)
        XCTAssertEqual(tracker.duplicates, 2)
    }

    func testAReorderIsAcceptedAndCancelsTheLoss() {
        var tracker = AudioSequenceTracker()
        _ = tracker.observe(1)
        XCTAssertEqual(tracker.observe(4), .fresh(gap: 2))
        XCTAssertEqual(tracker.lost, 2)
        XCTAssertEqual(tracker.observe(2), .reordered)
        XCTAssertEqual(tracker.observe(3), .reordered)
        XCTAssertEqual(tracker.lost, 0, "they were late, not lost")
        XCTAssertEqual(tracker.reordered, 2)
    }

    func testAPacketOlderThanTheWindowIsRefusedRatherThanReplayed() {
        var tracker = AudioSequenceTracker(window: 8)
        for seq in UInt32(0)..<40 { _ = tracker.observe(seq) }
        // 0 left the window long ago: the tracker cannot know whether it was
        // played, and "play it again" is worse than "lose one".
        XCTAssertEqual(tracker.observe(0), .stale)
        XCTAssertEqual(tracker.stale, 1)
    }

    func testANewSenderRunIsRecognizedRatherThanReadAsAFloodOfDuplicates() {
        var tracker = AudioSequenceTracker()
        for seq in UInt32(5000)..<5100 { _ = tracker.observe(seq) }
        XCTAssertEqual(tracker.observe(0), .restart)
        XCTAssertEqual(tracker.restarts, 1)
        XCTAssertEqual(tracker.observe(1), .fresh(gap: 0))
    }

    func testTheCounterWrapsWithoutAHiccup() {
        var tracker = AudioSequenceTracker()
        _ = tracker.observe(UInt32.max - 2)
        XCTAssertEqual(tracker.observe(UInt32.max - 1), .fresh(gap: 0))
        XCTAssertEqual(tracker.observe(UInt32.max), .fresh(gap: 0))
        XCTAssertEqual(tracker.observe(0), .fresh(gap: 0), "0 follows UInt32.max")
        XCTAssertEqual(tracker.observe(1), .fresh(gap: 0))
        XCTAssertEqual(tracker.restarts, 0)
        XCTAssertEqual(tracker.duplicates, 0)
    }

    // MARK: - The buffer: exactly once

    /// The test the brief asked for: replay a packet stream with duplicates and
    /// reorders in it, and every sample must come out exactly once.
    func testReplayingAStreamWithDuplicatesAndReordersPlaysEachSampleOnce() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 64)
        // 0..19 in order, then: 5 duplicated three times (the echo), 12 and 13
        // swapped, 17 arriving again after its neighbours (a retransmit above
        // TCP after a reconnect), and 9 sent a second time from the old path.
        var arrivals: [UInt32] = Array(0...11)
        arrivals += [13, 12]
        arrivals += [14, 15, 16, 17, 18, 19]
        arrivals += [5, 5, 5, 17, 9]
        for seq in arrivals {
            buffer.enqueue(packet(seq, ptsMs: Double(seq) * 21.3, byte: UInt8(seq)))
        }

        var played: [UInt8] = []
        while let p = buffer.dequeue() { played.append(p.payload.first!) }

        XCTAssertEqual(played.count, 20, "20 distinct packets arrived")
        XCTAssertEqual(Set(played).count, 20, "and each was played exactly once")
        XCTAssertEqual(played, played.sorted(), "and in timestamp order")
        XCTAssertEqual(buffer.duplicatesDropped, 5, "3×seq 5, 1×seq 17, 1×seq 9")
        XCTAssertEqual(buffer.replaysBlocked, 0,
                       "nothing should ever have to be stopped on the way out")
    }

    func testTheEchoIsRefusedAtTheDoorRatherThanPlayedQuietlyUnderTheSession() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 16)
        buffer.enqueue(packet(1, ptsMs: 100, byte: 1))
        XCTAssertTrue(buffer.enqueue(packet(2, ptsMs: 121, byte: 2)))
        XCTAssertFalse(buffer.enqueue(packet(2, ptsMs: 121, byte: 2)))
        XCTAssertEqual(buffer.depth, 2)
    }

    func testAFlushDoesNotForgetWhatIsAlreadyInsideThePlayerNode() {
        // The exact echo shape: packets are handed to the node, the buffer is
        // flushed on a reconnect, and the sender replays the same packets. If
        // `reset()` forgot the run, they would be queued and played a second
        // time — 100–300 ms under the new session, which is what an echo is.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 16)
        for seq in UInt32(0)..<5 { buffer.enqueue(packet(seq, ptsMs: Double(seq) * 21)) }
        while buffer.dequeue() != nil {}
        buffer.reset()
        for seq in UInt32(0)..<5 {
            XCTAssertFalse(buffer.enqueue(packet(seq, ptsMs: Double(seq) * 21)),
                           "seq \(seq) has already been played")
        }
        XCTAssertEqual(buffer.depth, 0)
    }

    func testANewSessionDoesForgetTheRunSoTheNextSenderIsNotSilenced() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 16)
        for seq in UInt32(0)..<5 { buffer.enqueue(packet(seq, ptsMs: Double(seq) * 21)) }
        buffer.resetForNewSession()
        XCTAssertTrue(buffer.enqueue(packet(0, ptsMs: 0)),
                      "a different Mac numbers from scratch and must still be heard")
    }

    func testAnUnsequencedSenderIsUnaffected() {
        // Every packet from a sender too old to stamp them is queued, exactly
        // as before. The counters simply stay at zero — and the player says so
        // out loud rather than letting a zero read as proof.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 16)
        for i in 0..<5 { XCTAssertTrue(buffer.enqueue(packet(nil, ptsMs: Double(i) * 21))) }
        XCTAssertEqual(buffer.depth, 5)
        XCTAssertEqual(buffer.duplicatesDropped, 0)
    }

    func testTheDepartureTrackerAgreesWithTheArrivalOneOnAHealthyRun() {
        // The belt to the arrival tracker's braces. It is not expected to ever
        // fire — "the same PCM reached the node twice" is the symptom rather
        // than a cause — so what is asserted is that it stays silent and that
        // its count of what left equals the count of what was let in.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 32)
        // 0–6 in order, then 9 ahead of 8 and 7, then 9 again.
        let arrivals: [UInt32] = [0, 1, 2, 3, 4, 5, 6, 9, 8, 7, 9]
        for seq in arrivals { buffer.enqueue(packet(seq, ptsMs: Double(seq) * 21.3)) }
        var played = 0
        while buffer.dequeue() != nil { played += 1 }
        XCTAssertEqual(played, 10)
        XCTAssertEqual(buffer.replaysBlocked, 0)
        XCTAssertEqual(buffer.departures.accepted, 10)
        XCTAssertEqual(buffer.arrivals.accepted, 10)
    }
}
