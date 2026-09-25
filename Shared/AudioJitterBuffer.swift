// Compiled into the Mac sender, the iOS receiver and the Mac receiver (see
// project.yml `sources`). Foundation-only and free of any API newer than the
// receiver's deployment target.

import Foundation

/// What a packet's sequence number says about it, and the bookkeeping that
/// makes an echo visible instead of merely audible.
///
/// Round 6 closed the *scheduling* half of the duplicate problem
/// (`AudioScheduleLedger`): the completion handlers of buffers `player.stop()`
/// threw away could no longer make room for extra ones. It left the *enqueue*
/// half open, and the enqueue half cannot be closed without a sequence number:
///
/// * `ptsMs` is wall-clock milliseconds as a `Double`. Two packets encoded in
///   the same millisecond are indistinguishable by it, so "have I already
///   queued this exact packet?" has no answer.
/// * `AudioJitterBuffer.enqueue` inserts by timestamp and has no notion of
///   identity, so a packet delivered twice — a retransmit above TCP, a
///   connection adopted twice, a sender that replays after a transport switch
///   — is queued twice and **played** twice, about 21 ms apart. That is what an
///   echo is.
///
/// So the sender stamps every packet (`AudioPacket.sequence`) and this decides
/// what each one is. Kept pure and separate from the buffer because the
/// interesting cases — a wrap at `UInt32.max`, a sender that restarts its
/// numbering on reconnect, a reorder that arrives after the window has moved on
/// — are exactly the ones that cannot be produced on demand from a live link.
struct AudioSequenceTracker: Equatable {

    enum Verdict: Equatable {
        /// Never seen, and at or ahead of everything seen so far. `gap` is how
        /// many sequence numbers were skipped to reach it (0 = perfectly in
        /// order).
        case fresh(gap: Int)
        /// This exact sequence has already been accepted. **Drop it.**
        case duplicate
        /// Older than the highest seen, but not seen before: the network
        /// reordered it and it is still usable.
        case reordered
        /// So far behind that the window no longer remembers whether it was
        /// seen. Dropped, because "play it again" is worse than "lose one".
        case stale
        /// The numbering went backwards by more than a reorder could explain:
        /// a new sender session. State is cleared and this packet starts the
        /// new run.
        case restart
    }

    /// How many recent sequence numbers are remembered. At AAC-LC's ~47
    /// packets a second this is ~5 s of history — far longer than any reorder
    /// that is still worth playing, and small enough to stay free.
    static let defaultWindow = 256

    /// How far backwards counts as "the sender restarted" rather than "the
    /// network reordered". Four times the window: a reorder that deep is not a
    /// reorder.
    static let restartThreshold: UInt32 = 1024

    let window: Int

    private(set) var highest: UInt32?
    private var seen: Set<UInt32> = []
    private var order: [UInt32] = []

    // Counters, session-cumulative, for the periodic summary.
    private(set) var accepted = 0
    private(set) var duplicates = 0
    private(set) var reordered = 0
    private(set) var stale = 0
    private(set) var restarts = 0
    /// Sequence numbers that were skipped and never arrived later.
    private(set) var lost = 0

    init(window: Int = defaultWindow) {
        self.window = max(1, window)
    }

    /// Distance from `a` to `b` going forwards, in modular `UInt32` space.
    /// Wrap-safe by construction: `&-` is the whole trick, and it is why a
    /// session that runs past 2^32 packets (about 2.9 years of audio) does not
    /// need a special case.
    private static func forward(_ a: UInt32, _ b: UInt32) -> UInt32 { b &- a }

    /// True when `b` is behind `a` — i.e. the forward distance is more than
    /// half the space, which in modular arithmetic is what "backwards" means.
    private static func isBehind(_ b: UInt32, _ a: UInt32) -> Bool {
        forward(a, b) > UInt32(Int32.max)
    }

    mutating func observe(_ seq: UInt32) -> Verdict {
        guard let highest else {
            remember(seq)
            highest = seq
            accepted += 1
            return .fresh(gap: 0)
        }

        if Self.isBehind(seq, highest) {
            let back = Self.forward(seq, highest)
            if back > Self.restartThreshold {
                seen.removeAll(keepingCapacity: true)
                order.removeAll(keepingCapacity: true)
                remember(seq)
                self.highest = seq
                accepted += 1
                restarts += 1
                return .restart
            }
            if seen.contains(seq) {
                duplicates += 1
                return .duplicate
            }
            if back > UInt32(window) {
                stale += 1
                return .stale
            }
            remember(seq)
            accepted += 1
            reordered += 1
            // It was counted as lost when the gap opened; it made it after all.
            lost = max(0, lost - 1)
            return .reordered
        }

        if seq == highest || seen.contains(seq) {
            duplicates += 1
            return .duplicate
        }

        let gap = Int(Self.forward(highest, seq)) - 1
        lost += max(0, gap)
        remember(seq)
        self.highest = seq
        accepted += 1
        return .fresh(gap: max(0, gap))
    }

    private mutating func remember(_ seq: UInt32) {
        guard seen.insert(seq).inserted else { return }
        order.append(seq)
        while order.count > window {
            seen.remove(order.removeFirst())
        }
    }

    /// A new sender session: forget the run entirely, keep the counters (they
    /// are reported as deltas and zeroed by `resetCounters`).
    mutating func resetRun() {
        seen.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        highest = nil
    }

    mutating func resetCounters() {
        accepted = 0
        duplicates = 0
        reordered = 0
        stale = 0
        restarts = 0
        lost = 0
    }

    var hasAnythingToReport: Bool {
        duplicates > 0 || reordered > 0 || stale > 0 || restarts > 0 || lost > 0
    }

    /// One line, for the periodic summary.
    var summary: String {
        "\(accepted) accepted, \(duplicates) duplicate, \(reordered) reordered, "
            + "\(stale) too late, \(lost) lost, \(restarts) sender restart"
            + (restarts == 1 ? "" : "s")
    }
}

/// Absorbs network jitter between arrival and playback.
///
/// Packets leave the Mac evenly spaced but arrive in bursts, and an audio
/// device consumes them at a fixed rate: hand it packets exactly as they land
/// and every late one is an audible gap. The buffer trades a little latency
/// for continuity — it holds `targetDepth` packets before playback starts, so
/// a burst has somewhere to go and a late packet has time to catch up.
///
/// Deliberately not a resampler or a clock-drift corrector. It reorders,
/// bounds, and reports; long-run drift between the Mac's clock and the
/// device's is left to the audio engine.
///
/// Not thread-safe: callers serialise on their own queue.
struct AudioJitterBuffer {

    /// Packets held before playback begins. At AAC-LC's 1024 samples per
    /// packet and 48kHz, each packet is ~21ms, so 3 is ~64ms — enough to ride
    /// out ordinary WiFi jitter without a latency people notice against video.
    static let defaultTarget = 3
    /// Hard ceiling. Past this the network is delivering faster than playback
    /// consumes (or playback stalled); dropping the oldest keeps latency
    /// bounded instead of letting the buffer grow into a delay.
    static let defaultCapacity = 12

    /// Ceiling for adaptive growth. At ~21ms per packet this is ~170ms, past
    /// which audio lags the picture more than it gains in continuity — better
    /// to accept the occasional gap than to drift visibly out of sync.
    static let maxAdaptiveTarget = 8

    private var packets: [AudioPacket] = []
    private var started = false

    /// Current pre-roll depth. Starts at `baseTarget` and grows when the link
    /// proves too jittery for it — see `enqueue`. Never shrinks within a
    /// session: a link that underran once will underrun again, and oscillating
    /// the target is audible as repeated re-buffering.
    private(set) var targetDepth: Int
    private let baseTarget: Int
    let capacity: Int
    /// How many times the target has been raised — reported so a link that
    /// needed help is distinguishable from one that never struggled.
    private(set) var adaptations = 0

    // Counters for the stats report; a silent buffer and a thrashing one look
    // identical from outside without them.
    private(set) var underruns = 0
    private(set) var dropped = 0
    private(set) var reordered = 0

    /// Identity, when the sender stamps it. Two trackers, deliberately:
    ///
    /// * `arrivals` judges what comes off the wire — duplicates never enter the
    ///   queue, so they can never be decoded;
    /// * `departures` judges what leaves for the player node — the belt to the
    ///   other's braces, because "the same PCM reached the node twice" is the
    ///   symptom, and a bug anywhere between the two would otherwise be
    ///   invisible. In a correct run it reports nothing at all.
    private(set) var arrivals = AudioSequenceTracker()
    private(set) var departures = AudioSequenceTracker()
    /// Packets refused at the door because their sequence had already been
    /// accepted. The echo counter.
    private(set) var duplicatesDropped = 0
    /// Packets that reached the node twice. Must stay zero; a non-zero value
    /// names a bug between `enqueue` and `dequeue`.
    private(set) var replaysBlocked = 0

    /// **True when the packet just handed out does not continue the one
    /// before it.**
    ///
    /// Pre-roll, an underrun, a lost packet, a flush, a trim: each of them
    /// means the next packet's audio is not adjacent to the last packet's, and
    /// the consumer has to be told because **the decoder does not find out any
    /// other way**. AAC-LC is an MDCT codec with 50% overlap between
    /// consecutive frames: hand the decoder a packet from after a gap and it
    /// overlap-adds it with the tail of the frame from *before* the gap. The
    /// result is a ghost of the pre-gap audio mixed quietly under the live
    /// audio — a faint echo that no packet counter can see, because every
    /// packet is unique, in order, and played exactly once. It happens on every
    /// backgrounding, every interruption, every reconnect and every underrun.
    ///
    /// `AudioPlayer` turns this into an `AVAudioConverter.reset()`, which is
    /// the documented way to tell a converter that the stream it is decoding
    /// has jumped.
    private(set) var dequeueWasDiscontinuous = false
    /// How many times that has happened this session. Reported, because "the
    /// decoder was reset 40 times in five minutes" is a different diagnosis
    /// from "twice".
    private(set) var discontinuities = 0
    /// Packets dropped to shed standing latency — see `trim(to:)`.
    private(set) var trimmed = 0

    var depth: Int { packets.count }
    var isEmpty: Bool { packets.isEmpty }

    init(targetDepth: Int = defaultTarget, capacity: Int = defaultCapacity) {
        // A capacity below the target would drop packets before playback could
        // ever start, so the buffer would never produce a sound.
        let base = max(1, targetDepth)
        self.baseTarget = base
        self.targetDepth = base
        self.capacity = max(base, capacity)
    }

    /// Raise the pre-roll depth after an underrun.
    ///
    /// The starting target is a guess about a link we have not measured. One
    /// underrun is noise; repeated ones mean the guess is wrong for this
    /// network, and the buffer should hold more before playing. Growth is
    /// capped both by `maxAdaptiveTarget` (latency) and by `capacity` (there
    /// must be room above the target to absorb a burst).
    private mutating func adaptAfterUnderrun() {
        let ceiling = min(Self.maxAdaptiveTarget, capacity - 1)
        guard targetDepth < ceiling else { return }
        targetDepth += 1
        adaptations += 1
    }

    /// Queue a packet, ordering it by timestamp.
    ///
    /// Ordering matters because TCP guarantees byte order, not decode order
    /// across a reconnect: a session that migrates transports can deliver a
    /// packet from the old path after one from the new.
    /// Queue a packet unless its sequence number says it has been here before.
    ///
    /// Returns false when the packet was refused, so the caller can say why in
    /// a log rather than watching packets disappear.
    @discardableResult
    mutating func enqueue(_ packet: AudioPacket) -> Bool {
        if let seq = packet.sequence {
            switch arrivals.observe(seq) {
            case .duplicate, .stale:
                duplicatesDropped += 1
                return false
            case .restart:
                // A new run of sequence numbers is a new sender session as far
                // as identity goes. The held packets belong to the old run and
                // the departure tracker must not judge the new one against it.
                departures.resetRun()
            case .fresh, .reordered:
                break
            }
        }
        insert(packet)
        return true
    }

    private mutating func insert(_ packet: AudioPacket) {
        if let last = packets.last, packet.ptsMs < last.ptsMs {
            // Out of order: insert at the right position rather than appending.
            let index = packets.firstIndex { $0.ptsMs > packet.ptsMs } ?? packets.count
            packets.insert(packet, at: index)
            reordered += 1
        } else {
            packets.append(packet)
        }

        while packets.count > capacity {
            packets.removeFirst()
            dropped += 1
        }
    }

    /// The next packet to play, or nil while the buffer is still filling.
    ///
    /// Returns nil in two distinct situations that deliberately behave the
    /// same way — pre-roll (not enough packets yet) and underrun (drained) —
    /// because the caller's response is identical: play silence and wait. Only
    /// the underrun counter tells them apart afterwards.
    mutating func dequeue() -> AudioPacket? {
        if !started {
            guard packets.count >= targetDepth else { return nil }
            started = true
            // The first packet after a pre-roll follows either silence or the
            // last thing that was played before the buffer was dropped. Either
            // way it is not adjacent to it.
            noteDiscontinuity()
        }
        guard !packets.isEmpty else {
            underruns += 1
            started = false     // re-fill before resuming, or we underrun every packet
            adaptAfterUnderrun()
            // The gap is now, not at the next dequeue: whatever plays next
            // follows a hole in the audio.
            noteDiscontinuity()
            return nil
        }
        // Loop rather than return, so a packet the departure tracker refuses
        // costs the caller nothing: it asked for the next packet, and the next
        // packet is the one after the one that must not be played twice.
        while !packets.isEmpty {
            let packet = packets.removeFirst()
            guard let seq = packet.sequence else { return packet }
            switch departures.observe(seq) {
            case .duplicate, .stale:
                replaysBlocked += 1
                continue
            case .restart:
                noteDiscontinuity()
                return packet
            case .fresh(let gap):
                // A packet that is not the successor of the last one played:
                // the sender's audio has a hole in it exactly `gap` packets
                // wide, and the decoder must not overlap this frame onto the
                // one before the hole.
                if gap > 0 { noteDiscontinuity() }
                return packet
            case .reordered:
                noteDiscontinuity()
                return packet
            }
        }
        return nil
    }

    /// Consume the discontinuity flag: true exactly once per gap.
    mutating func takeDiscontinuity() -> Bool {
        defer { dequeueWasDiscontinuous = false }
        return dequeueWasDiscontinuous
    }

    private mutating func noteDiscontinuity() {
        // Counted once per *run* of gap: a flush followed immediately by a
        // pre-roll is one discontinuity, not two, and the count is meant to be
        // readable as "how often did the audio jump".
        if !dequeueWasDiscontinuous { discontinuities += 1 }
        dequeueWasDiscontinuous = true
    }

    /// Drop the oldest packets until only `depth` remain.
    ///
    /// The buffer is demand-driven — a packet leaves only when the player node
    /// has room — so its depth is a pure delay line whose length is set by the
    /// worst burst the session has seen, and **nothing ever shortens it
    /// again**. The operator's round-7 stats show exactly that: `aDepth` pinned
    /// at 9–11 against `aTgt` 3 for minutes at a time, i.e. ~200 ms of latency
    /// the buffer carries forever, and `aDrop` ticking as the *capacity* limit
    /// sheds it one packet at a time, at random moments, for the rest of the
    /// session.
    ///
    /// Trimming deliberately drops the **oldest** packets: they are the most
    /// late, and the alternative — dropping the newest — would replay the
    /// past. One trim of seven packets is one gap; the capacity limit's slow
    /// leak is a gap every few seconds indefinitely.
    mutating func trim(to depth: Int) {
        let target = max(0, depth)
        guard packets.count > target else { return }
        let excess = packets.count - target
        packets.removeFirst(excess)
        trimmed += excess
        noteDiscontinuity()
    }

    /// Drop everything and re-arm pre-roll, keeping what has been learned
    /// about this link. For a resume, where the held packets are stale but the
    /// network is the same one that needed the deeper buffer.
    mutating func reset() {
        if !packets.isEmpty || started { noteDiscontinuity() }
        packets.removeAll(keepingCapacity: true)
        started = false
        // The held packets are gone, so nothing that arrives next can be a
        // duplicate *of them* — but the run itself continues (same sender, same
        // numbering), so the trackers keep their history. Forgetting it here is
        // what would let the packets already inside the player node be queued a
        // second time by a retransmit, which is the echo.
    }

    /// Drop everything and forget the adaptation too. For a new session, whose
    /// peer may be on an entirely different network — carrying over a target
    /// grown for a bad WiFi link would add latency a cable does not need.
    mutating func resetForNewSession() {
        reset()
        targetDepth = baseTarget
        adaptations = 0
        // A different sender numbers from scratch, and `restart` would catch
        // that anyway — but only after `restartThreshold` packets of the new
        // run had been judged against the old one's window. Clearing it here is
        // free and exact.
        arrivals.resetRun()
        departures.resetRun()
    }

    /// Zero the counters after they have been reported.
    mutating func resetCounters() {
        underruns = 0
        dropped = 0
        reordered = 0
        duplicatesDropped = 0
        replaysBlocked = 0
        discontinuities = 0
        trimmed = 0
        arrivals.resetCounters()
        departures.resetCounters()
    }
}

/// How many decoded buffers are inside the player node, and which ones still
/// count.
///
/// `AVAudioPlayerNode.scheduleBuffer` takes a completion handler and that
/// handler is the only signal that a buffer has been consumed — so the count
/// of buffers in flight, which is what paces playback, is only as good as the
/// bookkeeping around it. There is one way for that bookkeeping to go wrong
/// and it goes wrong silently:
///
/// > `player.stop()` **discards** every scheduled buffer and fires each of
/// > their completion handlers. `AudioPlayer` calls it in `stop`, `flush`,
/// > `startNewSession` and `teardownGraph`, and each of those then set the
/// > counter to zero. The discarded buffers' handlers land *afterwards* and
/// > decrement it again.
///
/// A counter clamped at zero (which is what round 5 shipped) turns that into a
/// permanent under-count: after a reset the node is believed to hold fewer
/// buffers than it does, so the drain loop hands it more, and the extra ones
/// are pure added latency — audio drifting later behind the picture with every
/// reconnect, and after enough of them the tail of one session still audible
/// under the head of the next. Five reconnects in one evening is what the
/// round-5 log has.
///
/// The fix is a **generation**: every discard invalidates the handlers that
/// were already out, so a completion can only ever be counted against the
/// batch it belongs to.
struct AudioScheduleLedger: Equatable {

    /// How many buffers may sit inside the node at once.
    let capacity: Int

    /// Bumped on every discard. A completion stamped with an older value is
    /// from a buffer that no longer exists.
    private(set) var generation = 0
    /// Buffers handed to the node in the current generation and not yet
    /// reported consumed.
    private(set) var outstanding = 0
    /// Completions that arrived for a discarded generation. Diagnostic only —
    /// a non-zero value is normal after any reset, and is exactly the number
    /// the clamped counter used to subtract from the wrong batch.
    private(set) var strayCompletions = 0

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var hasRoom: Bool { outstanding < capacity }
    var isEmpty: Bool { outstanding == 0 }

    /// Record a buffer handed to the node, and return the stamp its completion
    /// handler must carry back.
    mutating func scheduled() -> Int {
        outstanding += 1
        return generation
    }

    /// A completion handler fired.
    mutating func completed(generation stamp: Int) {
        guard stamp == generation else {
            strayCompletions += 1
            return
        }
        outstanding = max(0, outstanding - 1)
    }

    /// `player.stop()`, or anything else that throws away what is queued.
    mutating func discardAll() {
        generation += 1
        outstanding = 0
    }
}
