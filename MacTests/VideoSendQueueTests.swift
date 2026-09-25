import XCTest

/// The latency-first send queue, and the IDR that follows a burst drop.
///
/// Round 8 kept the three *oldest* frames and threw away every newer capture,
/// which is why the operator's receiver reported `fps 1` against a `capFps` of
/// 28: what finally arrived was the picture from the start of the stall. The
/// queue here is the opposite rule, and these are the properties that make it
/// one.
final class VideoSendQueueTests: XCTestCase {

    private func queue() -> VideoSendQueue<Int> {
        VideoSendQueue<Int>()
    }

    // MARK: - Shape

    func testTheDefaultsAreTwoWaitingAndOneInFlight() {
        XCTAssertEqual(SendQueuePolicy.maxQueuedFrames, 2)
        XCTAssertEqual(SendQueuePolicy.maxInFlight, 1)
        XCTAssertEqual(SendQueuePolicy.capacity, 3)
        XCTAssertEqual(queue().capacity, 3)
    }

    func testDepthCountsWhatIsWaitingAndWhatIsBeingWritten() {
        var q = queue()
        XCTAssertEqual(q.depth, 0)
        q.enqueue(1)
        XCTAssertEqual(q.depth, 1)
        _ = q.dequeue()
        XCTAssertEqual(q.depth, 1, "a frame handed to the socket is still in the pipe")
        q.enqueue(2)
        XCTAssertEqual(q.depth, 2)
        q.completed()
        XCTAssertEqual(q.depth, 1)
    }

    // MARK: - Newest wins

    func testNothingIsEvictedWhileThereIsRoom() {
        var q = queue()
        XCTAssertTrue(q.enqueue(1).isEmpty)
        XCTAssertTrue(q.enqueue(2).isEmpty)
        XCTAssertEqual(q.waiting, [1, 2])
    }

    func testTheThirdWaitingFrameEvictsTheOldestNotTheNewest() {
        // The whole point. The picture the receiver decodes must be the most
        // recent one the encoder produced.
        var q = queue()
        q.enqueue(1)
        q.enqueue(2)
        let evicted = q.enqueue(3)
        XCTAssertEqual(evicted, [1])
        XCTAssertEqual(q.waiting, [2, 3])
    }

    func testABurstEvictsInOrderOldestFirst() {
        var q = queue()
        for frame in 1...5 { q.enqueue(frame) }
        XCTAssertEqual(q.waiting, [4, 5])
        XCTAssertEqual(q.evictedTotal, 3)
    }

    func testAFrameInFlightDoesNotOccupyAWaitingSlot() {
        var q = queue()
        q.enqueue(1)
        XCTAssertEqual(q.dequeue(), 1)
        q.enqueue(2)
        q.enqueue(3)
        XCTAssertTrue(q.waiting == [2, 3])
        XCTAssertEqual(q.depth, 3)
        XCTAssertTrue(q.isFull)
    }

    // MARK: - Writing

    func testOnlyOneWriteMayBeOutstanding() {
        var q = queue()
        q.enqueue(1)
        q.enqueue(2)
        XCTAssertEqual(q.dequeue(), 1)
        XCTAssertNil(q.dequeue(), "the socket already has a frame")
        q.completed()
        XCTAssertEqual(q.dequeue(), 2)
    }

    func testDequeuingAnEmptyQueueIsNotAnError() {
        var q = queue()
        XCTAssertNil(q.dequeue())
        q.completed()
        XCTAssertEqual(q.inFlight, 0, "a stray completion must not go negative")
    }

    // MARK: - Accounting

    func testEvictionsAreDrainedExactlyOncePerTick() {
        var q = queue()
        for frame in 1...5 { q.enqueue(frame) }
        XCTAssertEqual(q.drainEvictions(), 3)
        XCTAssertEqual(q.drainEvictions(), 0, "a tick must not count the last tick's drops")
        XCTAssertEqual(q.evictedTotal, 3, "the session total keeps counting")
    }

    func testThePeakDepthIsRememberedForThePanelLine() {
        var q = queue()
        q.enqueue(1)
        _ = q.dequeue()
        q.enqueue(2)
        q.enqueue(3)
        XCTAssertEqual(q.peakDepth, 3)
        q.completed()
        XCTAssertEqual(q.peakDepth, 3, "an average of 1 hides a link that spends every other second at 3")
        q.resetPeak()
        XCTAssertEqual(q.peakDepth, q.depth)
    }

    func testANewConnectionInheritsNothing() {
        var q = queue()
        q.enqueue(1)
        _ = q.dequeue()
        q.enqueue(2)
        q.enqueue(3)
        q.enqueue(4)
        q.reset()
        XCTAssertEqual(q.depth, 0)
        XCTAssertTrue(q.waiting.isEmpty)
        XCTAssertEqual(q.inFlight, 0)
        XCTAssertEqual(q.peakDepth, 0)
        XCTAssertEqual(q.drainEvictions(), 0)
    }

    // MARK: - The keyframe that follows a drop

    func testAnEvictionEarnsAnImmediateKeyframe() {
        // An evicted frame breaks the reference chain: everything after it
        // predicts from something the decoder never saw.
        var policy = KeyframeAfterDropPolicy()
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 1, at: 0))
        XCTAssertEqual(policy.requested, 1)
    }

    func testNoEvictionNoKeyframe() {
        var policy = KeyframeAfterDropPolicy()
        XCTAssertFalse(policy.shouldRequestIdr(evictedFrames: 0, at: 0))
        XCTAssertEqual(policy.requested, 0)
        XCTAssertEqual(policy.suppressed, 0)
    }

    func testASustainedOverloadDoesNotBecomeAKeyframeStorm() {
        // An IDR is a bitrate spike of several times a P-frame. One per evicted
        // frame on a congested link would deepen the very queue it is
        // recovering from.
        var policy = KeyframeAfterDropPolicy()
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 4, at: 0))
        XCTAssertFalse(policy.shouldRequestIdr(evictedFrames: 4, at: 0.2))
        XCTAssertFalse(policy.shouldRequestIdr(evictedFrames: 4, at: 0.9))
        XCTAssertEqual(policy.suppressed, 2)
    }

    func testTheThrottleReleasesAfterASecond() {
        var policy = KeyframeAfterDropPolicy()
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 1, at: 0))
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 1, at: 1.0))
        XCTAssertEqual(policy.requested, 2)
    }

    func testANewConnectionMayHaveItsKeyframeStraightAway() {
        var policy = KeyframeAfterDropPolicy()
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 1, at: 100))
        policy.reset()
        XCTAssertTrue(policy.shouldRequestIdr(evictedFrames: 1, at: 100.1),
                      "the throttle must not suppress the keyframe a fresh peer needs")
    }

    // MARK: - The latency bound, stated as a property

    func testTheQueueCanNeverHoldMoreThanThreeFrames() {
        var q = queue()
        for frame in 1...500 {
            q.enqueue(frame)
            if frame % 3 == 0, q.dequeue() != nil { }
            if frame % 7 == 0 { q.completed() }
            XCTAssertLessThanOrEqual(q.depth, 3, "at frame \(frame)")
        }
    }
}
