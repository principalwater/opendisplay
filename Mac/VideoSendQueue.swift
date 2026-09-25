// The send queue, and the rule that keeps it short.
//
// Round 8 had no queue. Encoded frames went straight to `NWConnection.send`
// and a counter (`pendingSends`, cap 3) decided whether the *next capture* was
// worth encoding. That has two defects, and the operator's LTE session shows
// both:
//
// * **It drops the newest frame.** Once three writes were outstanding every
//   subsequent capture was discarded before encode, so what eventually reached
//   the receiver was three frames from the *start* of the stall. On a relayed
//   TCP path a stall lasts seconds; `fps` 1 against `capFps` 28 is that, and
//   the picture the user finally sees is seconds out of date.
// * **It has no latency bound.** A "frame" here is up to a few hundred KB and
//   `contentProcessed` fires when the transport takes the bytes, not when they
//   arrive. Three of those on a 1 Mbps path is several seconds of standing
//   queue, which is precisely the head-of-line blocking that made `e2e95`
//   reach 1902 ms.
//
// The replacement is a bounded queue that keeps the **newest** frames: at most
// one write in flight and at most two frames waiting, and a third arrival
// evicts the oldest. Latency is then bounded by construction rather than by
// hoping the link keeps up, and what the receiver decodes is always the most
// recent picture the encoder produced.
//
// Pure and generic so it can be tested with `Int`s: `MacSender` instantiates
// it over `Data`.

import Foundation

/// The two numbers, in one place so the queue, the drop accounting and the
/// adaptive controller's `maxSendQueueDepth` cannot disagree.
enum SendQueuePolicy {
    /// Frames allowed to sit encoded-but-unsent.
    ///
    /// Two, not one: a single slot makes the socket idle for the whole gap
    /// between a completion and the next encode, which costs throughput on a
    /// good link for no latency benefit. Two is the smallest number that keeps
    /// the pipe fed, and at 30 fps it is 66 ms of queue.
    static let maxQueuedFrames = 2
    /// Writes allowed to be outstanding.
    ///
    /// One. More than one means the transport, not this queue, decides the
    /// order and the depth — and the whole point is that this queue decides.
    static let maxInFlight = 1
    /// Total depth the controller sees as "full".
    static var capacity: Int { maxQueuedFrames + maxInFlight }
}

/// A latency-first queue: newest wins, oldest is evicted.
struct VideoSendQueue<Item> {

    let maxQueued: Int
    let maxInFlight: Int

    private(set) var waiting: [Item] = []
    private(set) var inFlight = 0
    /// Frames evicted since the last `drainEvictions()`, for the tick.
    private(set) var evictedThisWindow = 0
    /// Frames evicted since the queue was created or reset, for the log.
    private(set) var evictedTotal = 0
    /// The deepest this queue has been since the last reset — the number the
    /// panel line reports, because an average depth of 1 hides a link that
    /// spends every other second at 3.
    private(set) var peakDepth = 0

    init(maxQueued: Int = SendQueuePolicy.maxQueuedFrames,
         maxInFlight: Int = SendQueuePolicy.maxInFlight) {
        self.maxQueued = max(1, maxQueued)
        self.maxInFlight = max(1, maxInFlight)
    }

    /// Frames written or waiting to be written, right now.
    var depth: Int { inFlight + waiting.count }
    var capacity: Int { maxQueued + maxInFlight }
    var isFull: Bool { depth >= capacity }

    /// Add a freshly encoded frame. Returns whatever had to be evicted to make
    /// room, **oldest first** — the caller counts them and asks for an IDR.
    @discardableResult
    mutating func enqueue(_ item: Item) -> [Item] {
        waiting.append(item)
        var evicted: [Item] = []
        while waiting.count > maxQueued {
            evicted.append(waiting.removeFirst())
        }
        evictedThisWindow += evicted.count
        evictedTotal += evicted.count
        peakDepth = max(peakDepth, depth)
        return evicted
    }

    /// The next frame to write, if the link has a slot for it.
    mutating func dequeue() -> Item? {
        guard inFlight < maxInFlight, !waiting.isEmpty else { return nil }
        inFlight += 1
        return waiting.removeFirst()
    }

    /// One write finished (successfully or not).
    mutating func completed() {
        inFlight = max(0, inFlight - 1)
    }

    /// Read and clear the per-tick eviction count.
    mutating func drainEvictions() -> Int {
        defer { evictedThisWindow = 0 }
        return evictedThisWindow
    }

    mutating func resetPeak() {
        peakDepth = depth
    }

    /// A new connection inherits nothing.
    mutating func reset() {
        waiting.removeAll()
        inFlight = 0
        evictedThisWindow = 0
        peakDepth = 0
    }
}

/// When a burst drop earns an IDR.
///
/// Evicting an encoded frame breaks the H.264 reference chain — every P-frame
/// after it predicts from something the decoder never saw, so the picture
/// smears until the next keyframe. Asking for an IDR makes recovery immediate.
///
/// Throttled, because an IDR is a bitrate spike of several times a P-frame, and
/// an unthrottled "IDR on every eviction" on a congested link is a spike per
/// frame: the cure would deepen the very queue it is recovering from. One per
/// second is fast enough that no user watches a smear, and slow enough that the
/// spikes are a rounding error on the budget.
struct KeyframeAfterDropPolicy: Equatable {

    static let minimumIntervalSeconds = 1.0

    private var lastRequestedAt: TimeInterval?
    private(set) var requested = 0
    private(set) var suppressed = 0

    init() {}

    mutating func shouldRequestIdr(evictedFrames: Int, at now: TimeInterval) -> Bool {
        guard evictedFrames > 0 else { return false }
        if let last = lastRequestedAt, now - last < Self.minimumIntervalSeconds {
            suppressed += 1
            return false
        }
        lastRequestedAt = now
        requested += 1
        return true
    }

    mutating func reset() {
        lastRequestedAt = nil
    }
}
