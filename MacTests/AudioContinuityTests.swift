import XCTest

/// **The echo that is not a duplicate.**
///
/// Round 7 closed the packet-identity question for good — the operator's iPad
/// reported `1572 accepted, 0 duplicate, 0 reordered, 0 too late, 23 lost, 0
/// sender restarts` — and the echo was still there. So it is not a packet being
/// played twice, and the audit in `AudioGraphTests` rules out the graph summing
/// the same audio through two paths. What is left is what happens to the audio
/// *between* those two places, and there is one mechanism there that is
/// invisible to every counter the receiver had:
///
/// > **AAC-LC is an MDCT codec with 50% overlap.** Every decoded frame is the
/// > overlap-add of this packet's second half with the *previous* packet's
/// > second half. That is correct and inaudible while the stream is continuous.
/// > Across a discontinuity — a flush, an interruption, an underrun, a lost
/// > packet — the "previous packet" is from before the gap, and its tail is
/// > mixed under the first frame after it. A ghost of pre-gap audio, at low
/// > level, on every reconnect. Every packet is unique, in order, and played
/// > exactly once.
///
/// The fix is to tell the decoder, which means the buffer has to know when the
/// audio it hands over does not continue what it handed over last. That is what
/// these tests are about.
final class AudioContinuityTests: XCTestCase {

    private func packet(_ ptsMs: Double, seq: UInt32? = nil) -> AudioPacket {
        AudioPacket(codec: .aacLC, hasConfig: false, sampleRate: 48_000,
                    channels: 2, ptsMs: ptsMs, sequence: seq, payload: Data([0x01]))
    }

    private func fill(_ buffer: inout AudioJitterBuffer, count: Int,
                      fromSeq: UInt32 = 0, fromPts: Double = 0) {
        for i in 0..<count {
            buffer.enqueue(packet(fromPts + Double(i) * 21, seq: fromSeq + UInt32(i)))
        }
    }

    // MARK: - When the audio jumps

    func testTheFirstPacketAfterPreRollIsADiscontinuity() {
        // It follows either silence or whatever was playing before the buffer
        // was dropped. Either way it is not adjacent to it.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 3)
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())
    }

    func testAContinuousRunReportsNoDiscontinuityAtAll() {
        // The important half: a healthy session must not re-prime the decoder
        // 47 times a second. Re-priming needlessly would cost the *first* frame
        // of every packet its overlap, which is a click.
        var buffer = AudioJitterBuffer(targetDepth: 2, capacity: 12)
        fill(&buffer, count: 8)
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())      // the pre-roll
        for _ in 0..<7 {
            XCTAssertNotNil(buffer.dequeue())
            XCTAssertFalse(buffer.takeDiscontinuity())
        }
        XCTAssertEqual(buffer.discontinuities, 1)
    }

    func testAnUnderrunIsADiscontinuity() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0, seq: 0))
        XCTAssertNotNil(buffer.dequeue())
        _ = buffer.takeDiscontinuity()
        XCTAssertNil(buffer.dequeue())                // ran dry
        XCTAssertTrue(buffer.takeDiscontinuity(),
                      "whatever plays next follows a hole in the audio")
    }

    func testALostPacketIsADiscontinuity() {
        // 23 lost in one of the operator's windows. Each of those is a place
        // where the decoder must not overlap-add across the hole.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0, seq: 10))
        XCTAssertNotNil(buffer.dequeue())
        _ = buffer.takeDiscontinuity()
        buffer.enqueue(packet(21, seq: 14))           // 11, 12, 13 never arrived
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())
    }

    func testAFlushIsADiscontinuity() {
        // Backgrounding and foregrounding: `flush()` drops the held packets and
        // `player.stop()` throws away what was inside the node. What plays next
        // is from a different moment.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        fill(&buffer, count: 4)
        XCTAssertNotNil(buffer.dequeue())
        _ = buffer.takeDiscontinuity()
        buffer.reset()
        XCTAssertTrue(buffer.takeDiscontinuity())
    }

    func testAnUnsequencedStreamStillGetsItsPreRollAndUnderrunGaps() {
        // A sender too old to stamp packets has no `lost` to detect, but the
        // structural gaps are still structural.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0))
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())
        XCTAssertNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())
    }

    func testTheFlagIsConsumedExactlyOnce() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        buffer.enqueue(packet(0, seq: 0))
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertTrue(buffer.takeDiscontinuity())
        XCTAssertFalse(buffer.takeDiscontinuity(), "one gap, one decoder reset")
    }

    func testOneGapCountsOnceHoweverManyThingsCauseIt() {
        // A flush immediately followed by a pre-roll is one jump in the audio,
        // and the count is meant to read as "how often did the audio jump".
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        fill(&buffer, count: 3)
        XCTAssertNotNil(buffer.dequeue())
        _ = buffer.takeDiscontinuity()
        buffer.reset()
        fill(&buffer, count: 3, fromSeq: 100, fromPts: 1000)
        XCTAssertNotNil(buffer.dequeue())
        XCTAssertEqual(buffer.discontinuities, 2, "the first dequeue, then the flush+pre-roll")
    }

    // MARK: - Standing latency

    func testTrimmingDropsTheOldestPacketsAndSaysSo() {
        // The operator's stats: `aDepth` 9–11 against `aTgt` 3, for minutes.
        // The buffer only empties when the player node has room, so its depth
        // is whatever the worst burst made it and nothing shortens it again.
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        fill(&buffer, count: 11)
        buffer.trim(to: 4)
        XCTAssertEqual(buffer.depth, 4)
        XCTAssertEqual(buffer.trimmed, 7)
        // The oldest go: they are the most late, and dropping the newest would
        // be replaying the past.
        XCTAssertEqual(buffer.dequeue()?.ptsMs, 7 * 21)
    }

    func testATrimIsADiscontinuity() {
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        fill(&buffer, count: 11)
        XCTAssertNotNil(buffer.dequeue())
        _ = buffer.takeDiscontinuity()
        buffer.trim(to: 4)
        XCTAssertTrue(buffer.takeDiscontinuity())
    }

    func testTrimmingBelowTheCurrentDepthDoesNothing() {
        var buffer = AudioJitterBuffer(targetDepth: 3, capacity: 12)
        fill(&buffer, count: 3)
        buffer.trim(to: 8)
        XCTAssertEqual(buffer.depth, 3)
        XCTAssertEqual(buffer.trimmed, 0)
        XCTAssertFalse(buffer.takeDiscontinuity())
    }

    func testTrimmingDoesNotConfuseTheReplayDetector() {
        // The packets dropped by a trim were never played, so nothing that
        // comes after them can look like a replay — `replaysBlocked` must stay
        // at zero, because a non-zero value there is supposed to mean a bug.
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        fill(&buffer, count: 10)
        buffer.trim(to: 2)
        while buffer.dequeue() != nil {}
        XCTAssertEqual(buffer.replaysBlocked, 0)
        XCTAssertEqual(buffer.duplicatesDropped, 0)
    }

    // MARK: - What the counters mean afterwards

    func testTheCountersSurviveAResetAndAreReportedCumulatively() {
        var buffer = AudioJitterBuffer(targetDepth: 1, capacity: 12)
        fill(&buffer, count: 4)
        XCTAssertNotNil(buffer.dequeue())
        buffer.reset()
        XCTAssertGreaterThan(buffer.discontinuities, 0)
        buffer.resetCounters()
        XCTAssertEqual(buffer.discontinuities, 0)
        XCTAssertEqual(buffer.trimmed, 0)
    }
}
