import XCTest

/// The buffers inside the player node (§38).
///
/// The bug this replaces is silent and cumulative: `AVAudioPlayerNode.stop()`
/// discards every scheduled buffer **and fires each of their completion
/// handlers**, and `AudioPlayer` calls it in four places that then set the
/// count to zero. A counter clamped at zero absorbs those late decrements as
/// "nothing", so the node is believed emptier than it is, the drain loop tops
/// it up past its limit, and the extra buffers are pure latency — audio
/// sliding further behind the picture with every reconnect, and eventually the
/// tail of one session audible under the head of the next.
final class AudioScheduleLedgerTests: XCTestCase {

    func testAFreshLedgerIsEmptyAndHasRoom() {
        let ledger = AudioScheduleLedger(capacity: 3)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(ledger.hasRoom)
        XCTAssertEqual(ledger.outstanding, 0)
        XCTAssertEqual(ledger.strayCompletions, 0)
    }

    func testCapacityIsTheBackpressure() {
        var ledger = AudioScheduleLedger(capacity: 3)
        for expected in 1...3 {
            XCTAssertTrue(ledger.hasRoom)
            _ = ledger.scheduled()
            XCTAssertEqual(ledger.outstanding, expected)
        }
        XCTAssertFalse(ledger.hasRoom, "this is what paces playback at the hardware's rate")
    }

    func testCapacityIsNeverLessThanOne() {
        // A zero-capacity ledger would never schedule anything and audio would
        // be silent with a full buffer, which is the hardest failure to read
        // from outside.
        var ledger = AudioScheduleLedger(capacity: 0)
        XCTAssertTrue(ledger.hasRoom)
        _ = ledger.scheduled()
        XCTAssertFalse(ledger.hasRoom)
    }

    func testAConsumedBufferMakesRoom() {
        var ledger = AudioScheduleLedger(capacity: 3)
        let stamp = ledger.scheduled()
        _ = ledger.scheduled()
        ledger.completed(generation: stamp)
        XCTAssertEqual(ledger.outstanding, 1)
        XCTAssertTrue(ledger.hasRoom)
    }

    func testTheDiscardedBuffersCompletionsDoNotMakeRoomForExtraOnes() {
        // THE BUG. Three buffers in flight; `player.stop()` throws them away;
        // three fresh ones are scheduled; and only then do the old three
        // completion handlers land.
        var ledger = AudioScheduleLedger(capacity: 3)
        let stale = (0..<3).map { _ in ledger.scheduled() }
        ledger.discardAll()
        XCTAssertEqual(ledger.outstanding, 0)

        let fresh = (0..<3).map { _ in ledger.scheduled() }
        XCTAssertFalse(ledger.hasRoom)

        for stamp in stale { ledger.completed(generation: stamp) }
        XCTAssertEqual(ledger.outstanding, 3,
                       "the node still holds three buffers; a clamped counter read zero")
        XCTAssertFalse(ledger.hasRoom,
                       "and would have let three MORE be scheduled — 126 ms of added latency")
        XCTAssertEqual(ledger.strayCompletions, 3)

        for stamp in fresh { ledger.completed(generation: stamp) }
        XCTAssertTrue(ledger.isEmpty)
    }

    func testNoBufferIsEverCountedTwice() {
        // A completion handler that fired twice (or a duplicated stamp) must
        // not open the gate twice: the same buffer can only free one slot.
        var ledger = AudioScheduleLedger(capacity: 3)
        let stamp = ledger.scheduled()
        ledger.completed(generation: stamp)
        ledger.completed(generation: stamp)
        ledger.completed(generation: stamp)
        XCTAssertEqual(ledger.outstanding, 0, "never negative, never a free slot that is not there")
    }

    func testFiveResetsInAnEveningDoNotAccumulateDrift() {
        // The round-5 session: five reconnects, each of them a discard with
        // buffers in flight. The ledger's outstanding count must be exactly
        // right at the end, not "approximately, clamped".
        var ledger = AudioScheduleLedger(capacity: 3)
        for _ in 0..<5 {
            let inFlight = (0..<3).map { _ in ledger.scheduled() }
            ledger.discardAll()
            for stamp in inFlight { ledger.completed(generation: stamp) }
            XCTAssertEqual(ledger.outstanding, 0)
            XCTAssertTrue(ledger.hasRoom)
        }
        let live = (0..<3).map { _ in ledger.scheduled() }
        XCTAssertEqual(ledger.outstanding, 3)
        XCTAssertFalse(ledger.hasRoom)
        for stamp in live { ledger.completed(generation: stamp) }
        XCTAssertTrue(ledger.isEmpty)
    }

    func testEachDiscardInvalidatesOnlyWhatWasOutstanding() {
        var ledger = AudioScheduleLedger(capacity: 3)
        let first = ledger.scheduled()
        ledger.discardAll()
        let second = ledger.scheduled()
        ledger.discardAll()
        let third = ledger.scheduled()
        ledger.completed(generation: first)
        ledger.completed(generation: second)
        XCTAssertEqual(ledger.outstanding, 1)
        XCTAssertEqual(ledger.strayCompletions, 2)
        ledger.completed(generation: third)
        XCTAssertTrue(ledger.isEmpty)
    }

    func testDiscardingAnEmptyLedgerIsHarmless() {
        var ledger = AudioScheduleLedger(capacity: 3)
        ledger.discardAll()
        ledger.discardAll()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertTrue(ledger.hasRoom)
        let stamp = ledger.scheduled()
        ledger.completed(generation: stamp)
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.strayCompletions, 0)
    }

}
