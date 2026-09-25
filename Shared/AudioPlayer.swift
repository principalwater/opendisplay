// Compiled into the iOS receiver and the Mac receiver (see project.yml
// `sources`). Everything here must exist on the RECEIVER's deployment target,
// which is several majors below the sender's — CI builds the receiver app to
// catch a newer API sneaking in.

import AVFoundation
import Foundation

/// A snapshot of the audio path's health, for the overlay and the wire report.
struct AudioStats {
    var depth = 0          // packets held right now
    var target = 0         // pre-roll depth, which adapts upward on underruns
    var underruns = 0
    var dropped = 0
    var reordered = 0
    var adaptations = 0    // times the target grew this session
    /// Packets refused because their sequence number had already been queued.
    /// The echo counter: in a healthy session this stays at zero.
    var duplicates = 0
    /// Packets stopped on the way *out* of the buffer. Must stay zero.
    var replays = 0
    /// Sequence numbers skipped and never seen again.
    var lost = 0
    /// Times the sender's numbering restarted under one player.
    var restarts = 0
    /// Times the audio handed to the decoder did not continue what came
    /// before it, and the decoder therefore had to be re-primed.
    var discontinuities = 0
    /// Packets dropped to shed standing buffer latency.
    var trimmed = 0
}

/// Decodes AAC audio packets and plays them.
///
/// Feeding is decoupled from playback by a jitter buffer: packets arrive in
/// network bursts, the engine consumes them at a fixed rate. A drain timer
/// moves packets between the two, so a late packet costs latency rather than
/// a gap.
///
/// Every failure here is non-fatal by construction. Audio is an optional
/// addition to a display, and a device that cannot decode it must still show
/// the picture.
///
/// **Nothing here ever blocks the caller.** Every entry point is a
/// `queue.async` or a lock-guarded read of a snapshot, never a `queue.sync`:
/// the callers are the network receive queue (which also drains video) and the
/// main thread, and `AVAudioEngine.start()` alone can hold this queue for tens
/// of milliseconds. A stats read that waited on it would stall the picture —
/// see `publishLock`.
final class AudioPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var outputFormat: AVAudioFormat?

    /// Serialises the buffer and the engine; packets arrive on the network
    /// queue and the drain timer fires on its own.
    private let queue = DispatchQueue(label: "receiver.audio")
    private var buffer = AudioJitterBuffer()
    private var drainTimer: DispatchSourceTimer?
    private var running = false
    private var loggedFormat = false
    private var loggedStartFailure = false
    /// Packets handed to the player node and not yet consumed by it. See
    /// `maxScheduled` — this is the backpressure that paces playback.
    ///
    /// Generation-stamped, so that the
    /// completion handlers of buffers `player.stop()` threw away cannot make
    /// room for extra ones. See `AudioScheduleLedger` — the clamped counter
    /// this replaces under-counted by up to `maxScheduled` after every reset,
    /// and there are five resets in one evening of the round-5 log.
    private var ledger = AudioScheduleLedger(capacity: AudioPlayer.maxScheduled)
    private var decodeFailures = 0
    private var loggedFirstPlayback = false
    private var loggedDryStatus = false
    private var loggedNoDescriptions = false
    /// Audio-queue-only mirror of the user's mute switch. The published
    /// property the UI binds to lives on StreamReceiver; this is the copy the
    /// playback path reads, so the two threads never touch one variable.
    private var muted = false

    // MARK: - Stats snapshot
    //
    // The counters live on `queue`, but the readers (the 1 Hz overlay and the
    // 5 s wire report) run on the receiver's network queue. Publishing a
    // snapshot under a lock is what keeps those reads from waiting on an
    // engine start — a `queue.sync` here used to put the video drain behind
    // AVAudioEngine.
    /// Guards everything the audio queue publishes to, or receives from, the
    /// outside world: the counter snapshot below and the mute request.
    private let publishLock = NSLock()
    /// Session-cumulative counters, republished after every drain tick.
    private var published = AudioStats()
    /// What `drainStats()` last handed out, so it can report a delta without
    /// having to mutate anything on the audio queue.
    private var lastReported = AudioStats()

    /// Silence output without interrupting the stream.
    ///
    /// Implemented as the player node's volume rather than by discarding
    /// packets, so playback stays paced by the hardware: dropping them instead
    /// drains the jitter buffer at timer rate (100/s) against an arrival rate
    /// of ~47/s, which reads as a continuous underrun and inflates the buffer
    /// target for the rest of the session. At volume 0 the packets are decoded
    /// and consumed exactly as they would be otherwise, so unmuting is
    /// immediate and in sync.
    ///
    /// Settable from any thread; applied on the audio queue.
    var isMuted: Bool {
        get { publishLock.lock(); defer { publishLock.unlock() }; return mutedRequest }
        set {
            publishLock.lock(); mutedRequest = newValue; publishLock.unlock()
            queue.async { [weak self] in
                guard let self else { return }
                self.muted = newValue
                self.player.volume = newValue ? 0 : 1
            }
        }
    }
    private var mutedRequest = false

    // MARK: - Lifecycle

    /// Prepare the engine. Safe to call repeatedly.
    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.buffer.reset()
            self.ledger.discardAll()
            self.player.volume = self.muted ? 0 : 1
            self.publishStats()
            self.startDrainTimer()
        }
    }

    /// Start a new session: drop held audio and forget the buffer depth
    /// learned from the previous peer, which may have been on a different
    /// network entirely.
    func startNewSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.resetForNewSession()
            // Dropping the jitter buffer is not enough: up to `maxScheduled`
            // packets have already been handed to the player node and are
            // still queued inside it. Left there they play *under* the new
            // session — a quieter, 100–300 ms-late copy of the old sender's
            // sound, which is exactly what a connection that flip-flops
            // between two senders produces on every adopt. `stop()` on the
            // node discards them; `play()` restarts it if the engine is up.
            // (When the engine is not running yet, `ensureEngineRunning`
            // starts the node with it on the first packet.)
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
            self.ledger.discardAll()
            // Everything that was in flight is gone; nothing that arrives next
            // is adjacent to it.
            self.decoderNeedsReset = true
            self.publishStats()
        }
        start()
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.running = false
            self.drainTimer?.cancel()
            self.drainTimer = nil
            self.player.stop()
            if self.engine.isRunning { self.engine.stop() }
            self.buffer.reset()
            self.ledger.discardAll()
            self.converter = nil
            self.sourceFormat = nil
            self.loggedFormat = false
            self.loggedFirstPlayback = false
            self.loggedDryStatus = false
            self.loggedNoDescriptions = false
            self.decodeFailures = 0
            self.publishStats()
        }
    }

    /// Drop buffered audio without tearing the engine down — for a new session
    /// or a resume, where held packets are stale.
    func flush() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.reset()
            self.ledger.discardAll()
            self.player.stop()
            if self.engine.isRunning { self.player.play() }
            self.decoderNeedsReset = true
            self.publishStats()
        }
    }

    /// Rebuild the audio graph on the next packet.
    ///
    /// For an AVAudioSession interruption (a call, Siri, another app taking
    /// the session): the engine survives the interruption as an object but
    /// stops producing sound, and nothing in the packet path notices, so
    /// without this a single interruption ends audio for the rest of the
    /// session. Tearing the graph down makes `ensureEngineRunning` rebuild and
    /// restart it when the next packet arrives.
    func restartEngine() {
        queue.async { [weak self] in
            guard let self else { return }
            self.teardownGraph()
            self.buffer.reset()
            self.ledger.discardAll()
            self.loggedStartFailure = false
            self.loggedFirstPlayback = false
            self.publishStats()
        }
    }

    // MARK: - Feeding

    func enqueue(_ packet: AudioPacket) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.buffer.enqueue(packet)
        }
    }

    /// Counters for the 5 s wire report: each figure covers the interval since
    /// the previous call, computed as a delta against the last published
    /// snapshot rather than by zeroing anything on the audio queue. `depth`
    /// and `target` are instantaneous, not deltas.
    func drainStats() -> AudioStats {
        publishLock.lock()
        defer { publishLock.unlock() }
        let now = published
        let delta = AudioStats(depth: now.depth,
                               target: now.target,
                               underruns: now.underruns - lastReported.underruns,
                               dropped: now.dropped - lastReported.dropped,
                               reordered: now.reordered - lastReported.reordered,
                               adaptations: now.adaptations - lastReported.adaptations,
                               duplicates: now.duplicates - lastReported.duplicates,
                               replays: now.replays - lastReported.replays,
                               lost: now.lost - lastReported.lost,
                               restarts: now.restarts - lastReported.restarts,
                               discontinuities: now.discontinuities - lastReported.discontinuities,
                               trimmed: now.trimmed - lastReported.trimmed)
        lastReported = now
        return delta
    }

    /// The session-cumulative figures — for the live overlay, which samples
    /// every second and must not consume the counters the wire report reads.
    func peekStats() -> AudioStats {
        publishLock.lock()
        defer { publishLock.unlock() }
        return published
    }

    /// Republish the counters for the lock-guarded readers. Audio queue only.
    private func publishStats() {
        let snapshot = AudioStats(depth: buffer.depth,
                                  target: buffer.targetDepth,
                                  underruns: buffer.underruns,
                                  dropped: buffer.dropped,
                                  reordered: buffer.reordered,
                                  adaptations: buffer.adaptations,
                                  duplicates: buffer.duplicatesDropped,
                                  replays: buffer.replaysBlocked,
                                  lost: buffer.arrivals.lost,
                                  restarts: buffer.arrivals.restarts,
                                  discontinuities: buffer.discontinuities,
                                  trimmed: buffer.trimmed)
        publishLock.lock()
        published = snapshot
        publishLock.unlock()
    }

    // MARK: - The identity summary
    //
    // Sequence numbers are only useful if somebody looks at them, and a line
    // per packet is 47 a second. So: one line every `identityReportInterval`,
    // and **only when something moved** — a session with no duplicates, no
    // reorders and no losses says nothing at all, so a single line in the log
    // is itself the finding.
    private static let identityReportInterval: TimeInterval = 5
    private var lastIdentityReport = Date.distantPast
    private var lastIdentitySnapshot = AudioSequenceTracker()
    private var loggedUnsequencedSender = false

    // MARK: - Standing depth
    //
    // The buffer is demand-driven: a packet leaves only when the player node
    // has room, so the depth is a delay line whose length is whatever the worst
    // burst of the session made it, and nothing shortens it again. The
    // operator's round-7 stats are a textbook case — `aDepth` 9–11 against
    // `aTgt` 3 for minutes, i.e. ~200 ms of latency carried forever, with
    // `aDrop` ticking as the capacity ceiling sheds it one packet at a time.
    //
    // The *floor* over an interval is the number that says so: the depth dips
    // to zero in a healthy session every time the node takes everything there
    // is. A floor that never reaches the target is standing latency.
    private var depthFloor = Int.max
    private var depthPeak = 0

    private func noteDepth() {
        let depth = buffer.depth
        depthFloor = min(depthFloor, depth)
        depthPeak = max(depthPeak, depth)
    }

    /// The floor above which standing depth is worth shedding.
    ///
    /// Two packets under the capacity: at that point the buffer is already
    /// dropping packets at the ceiling, so trimming is not choosing to lose
    /// audio — it is choosing *when* to lose it, once, instead of at random for
    /// the rest of the session.
    private var trimThreshold: Int { max(buffer.capacity - 2, buffer.targetDepth + 4) }

    private func reportIdentityIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastIdentityReport) >= Self.identityReportInterval else { return }
        lastIdentityReport = now
        reportDepthIfStanding()
        reportDecoderIfBusy()
        let arrivals = buffer.arrivals
        guard arrivals.accepted > 0 || arrivals.duplicates > 0 else {
            // No sequenced packet has ever arrived. Say so once: a sender that
            // does not stamp packets cannot have its duplicates counted, and
            // "the duplicate counter is zero" would otherwise read as proof.
            if !loggedUnsequencedSender, buffer.depth > 0 {
                loggedUnsequencedSender = true
                Log.info("audio seq: this sender does not stamp packets — "
                         + "duplicate detection is off for the session")
            }
            return
        }
        let changed = arrivals.duplicates != lastIdentitySnapshot.duplicates
            || arrivals.reordered != lastIdentitySnapshot.reordered
            || arrivals.stale != lastIdentitySnapshot.stale
            || arrivals.lost != lastIdentitySnapshot.lost
            || arrivals.restarts != lastIdentitySnapshot.restarts
            || buffer.replaysBlocked > 0
        lastIdentitySnapshot = arrivals
        guard changed else { return }
        var line = "audio seq: \(arrivals.summary)"
        if buffer.replaysBlocked > 0 {
            line += " — \(buffer.replaysBlocked) packet(s) were stopped on the way OUT "
                + "of the buffer, which should never happen"
        }
        Log.info(line)
    }

    /// One line when the buffer is carrying latency it will never shed — and
    /// the trim that sheds it.
    private func reportDepthIfStanding() {
        defer { depthFloor = Int.max; depthPeak = 0 }
        guard depthFloor != Int.max else { return }
        guard depthFloor >= trimThreshold else { return }
        // Every packet is ~21 ms of audio at AAC-LC/48 kHz.
        let ms = Int(Double(depthFloor) * 1024 / 48 )
        buffer.trim(to: buffer.targetDepth + 1)
        Log.info("audio buffer: standing at \(depthFloor) packets (peak \(depthPeak), "
                 + "target \(buffer.targetDepth), capacity \(buffer.capacity)) — about \(ms) ms of "
                 + "latency the buffer never sheds, because it only empties when the player node "
                 + "has room. Trimmed to \(buffer.targetDepth + 1); "
                 + "\(buffer.trimmed) packet(s) trimmed this session")
    }

    /// One line when the decoder has been re-primed, which is the number the
    /// round-8 echo hunt needed and nothing reported.
    private func reportDecoderIfBusy() {
        guard buffer.discontinuities != lastDiscontinuities || rescuedFrames != lastRescuedFrames else { return }
        let gaps = buffer.discontinuities - lastDiscontinuities
        lastDiscontinuities = buffer.discontinuities
        let rescued = rescuedFrames - lastRescuedFrames
        lastRescuedFrames = rescuedFrames
        Log.info("audio decoder: \(gaps) discontinuit\(gaps == 1 ? "y" : "ies") in the last 5 s "
                 + "(\(decoderResets) decoder re-prime(s) this session) — each one is a gap the AAC "
                 + "decoder must not overlap-add across"
                 + (rescued > 0 ? "; \(rescued) PCM frame(s) rescued from an inputRanDry conversion" : ""))
    }

    private var lastDiscontinuities = 0
    private var lastRescuedFrames = 0

    // MARK: - Playback

    /// Wake up often enough to keep the engine topped up.
    ///
    /// The tick only decides *when to look*; `maxScheduled` decides how much is
    /// actually handed over, so a fast tick costs nothing and simply means the
    /// engine is refilled promptly once it has room.
    private func startDrainTimer() {
        drainTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    /// How many packets may sit scheduled inside the player node at once.
    ///
    /// This, not the timer, is what paces playback: a packet is pulled only
    /// when the engine has room, so the buffer drains at exactly the rate the
    /// hardware consumes audio. The earlier version pulled a fixed two packets
    /// per 10 ms tick — 200/s against an arrival rate of ~47/s (1024 samples at
    /// 48 kHz is ~21 ms of audio) — so it emptied the buffer roughly four times
    /// faster than it filled and underran continuously.
    static let maxScheduled = 3

    private func drain() {
        guard running else { return }
        while ledger.hasRoom {
            // Asking an empty buffer for a packet is what *defines* an underrun
            // to AudioJitterBuffer, and this timer asks a hundred times a
            // second. In the steady state the buffer is legitimately empty most
            // of the time — the reserve lives in the player node, which holds
            // up to `maxScheduled` packets of runway — so letting the timer ask
            // freely counted an underrun per tick, drove the adaptive target
            // straight to its ceiling, and turned every momentary gap into a
            // 170 ms re-buffer. Only a node that has actually run dry is an
            // underrun; anything else is just "nothing to do this tick".
            if buffer.isEmpty && !ledger.isEmpty { break }
            let packet = buffer.dequeue()
            // Read the flag whether or not a packet came out: an underrun sets
            // it too, and the next packet — whenever it arrives — is the one
            // that must not be overlap-added onto the audio from before the
            // hole.
            if buffer.takeDiscontinuity() { decoderNeedsReset = true }
            guard let packet else { break }
            play(packet)
        }
        noteDepth()
        publishStats()
        reportIdentityIfDue()
    }

    /// Set whenever the next packet's audio does not continue the last one's,
    /// and consumed by `decode`. See `AudioJitterBuffer.dequeueWasDiscontinuous`
    /// for why an AAC decoder has to be told.
    private var decoderNeedsReset = false
    /// How many times the decoder has been re-primed this session, and how many
    /// PCM frames were rescued from a `.inputRanDry` conversion that used to be
    /// thrown away. Both are in the 5 s summary.
    private var decoderResets = 0
    private var rescuedFrames = 0

    private func play(_ packet: AudioPacket) {
        guard let pcm = decode(packet) else {
            // Silence with a full buffer means every packet is failing to
            // decode; without this the two are indistinguishable from outside.
            decodeFailures += 1
            if decodeFailures == 1 || decodeFailures % 200 == 0 {
                Log.info("audio: decode failed (\(decodeFailures) so far) — no sound")
            }
            return
        }
        guard ensureEngineRunning(for: pcm.format) else { return }
        if !loggedFirstPlayback {
            loggedFirstPlayback = true
            Log.info("audio: playing \(Int(pcm.format.sampleRate))Hz "
                     + "\(pcm.format.channelCount)ch, engine running=\(engine.isRunning) "
                     + "volume=\(player.volume) muted=\(muted)")
        }
        // Muting is `player.volume`, applied in `isMuted` — the packet is still
        // scheduled so the hardware keeps pacing the buffer (see `isMuted`).
        //
        // The completion handler is the pacing signal: it fires when the engine
        // has consumed this buffer, which is what lets `drain` pull the next
        // one at the hardware's rate instead of a timer's.
        let stamp = ledger.scheduled()
        player.scheduleBuffer(pcm) { [weak self] in
            guard let self else { return }
            self.queue.async { self.ledger.completed(generation: stamp) }
        }
        if !player.isPlaying { player.play() }
    }

    // MARK: - Decoding

    private func decode(_ packet: AudioPacket) -> AVAudioPCMBuffer? {
        guard let converter = converter(for: packet),
              let outputFormat else { return nil }

        // **Re-prime the decoder across a gap.**
        //
        // AAC-LC is an MDCT codec: every decoded frame is the overlap-add of
        // this packet's second half with the *previous* packet's second half.
        // That is correct and inaudible while the stream is continuous, and it
        // is exactly wrong across a discontinuity — a flush, an interruption,
        // an underrun, a lost packet, a trim — where the "previous packet" is
        // from before the gap. Without this the first frame after every
        // reconnect is a ghost of pre-gap audio mixed under the live audio,
        // which is a faint echo that no packet counter can see: every packet is
        // unique, in order, and played exactly once.
        //
        // `AVAudioConverter.reset()` is the documented way to say "the stream
        // jumped"; it discards the decoder's carried state and nothing else.
        if decoderNeedsReset {
            decoderNeedsReset = false
            converter.reset()
            decoderResets += 1
        }

        let compressed = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: max(packet.payload.count, 1))
        compressed.byteLength = UInt32(packet.payload.count)
        compressed.packetCount = 1
        packet.payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            compressed.data.copyMemory(from: base, byteCount: packet.payload.count)
        }
        // AAC-LC is 1024 samples per packet; the description tells the decoder
        // how much of `data` this packet occupies.
        // A nil descriptor array means the decoder gets no packet boundary and
        // rejects the frame — worth knowing, since it fails identically to a
        // malformed payload.
        if compressed.packetDescriptions == nil, !loggedNoDescriptions {
            loggedNoDescriptions = true
            Log.info("audio: compressed buffer has no packetDescriptions — decoder will reject frames")
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(packet.payload.count))

        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat,
        // Exactly one AAC-LC frame: 1024 samples, which is what one packet
        // decodes to. Asking for more (this was 2048) makes the converter
        // consume the packet, find it cannot fill the request, and return
        // inputRanDry having produced no PCM at all — a silent failure on every
        // single packet, with a perfectly valid frame going in.
                                         frameCapacity: 1024) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return compressed
        }

        switch status {
        case .haveData:
            return pcm.frameLength > 0 ? pcm : nil
        case .inputRanDry, .endOfStream:
            // `inputRanDry` means "the input block had nothing more", not "this
            // failed": the converter may have produced perfectly good PCM
            // before asking for more input. Round 7 threw that away — silently,
            // on every packet where the decoder's priming made it happen —
            // which is audio dropped on the floor with no counter anywhere. If
            // there are frames, they are the packet's audio and they play.
            if pcm.frameLength > 0 {
                rescuedFrames += Int(pcm.frameLength)
                return pcm
            }
            // Not an error in AVAudioConverter's eyes, so the `.error` branch
            // never fires and nothing was logged — which is why a decode that
            // fails on every packet looked silent from outside.
            if !loggedDryStatus {
                loggedDryStatus = true
                Log.info("audio: converter returned \(status == .inputRanDry ? "inputRanDry" : "endOfStream")"
                         + " for a \(packet.payload.count)B packet — no PCM produced")
            }
            return nil
        case .error:
            if let error { Log.info("audio decode error: \(error)") }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Build (or reuse) the decoder for this packet's format.
    private func converter(for packet: AudioPacket) -> AVAudioConverter? {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(packet.sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(packet.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let inFormat = AVAudioFormat(streamDescription: &description) else { return nil }

        // AAC needs its AudioSpecificConfig before it can decode anything, and
        // an ASBD alone does not carry one — without it the decoder builds
        // happily and then rejects every frame, which is exactly what it did.
        //
        // For AAC-LC the config is two bytes fully determined by the sample
        // rate and channel count, so it is reconstructed below rather than
        // sent, and applied to the converter once it exists.

        if let converter, let sourceFormat, sourceFormat == inFormat { return converter }

        // Float32 deinterleaved is what AVAudioEngine wants; letting it convert
        // again downstream would be a second resample for nothing.
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: Double(packet.sampleRate),
                                            channels: AVAudioChannelCount(packet.channels)),
              let made = AVAudioConverter(from: inFormat, to: outFormat) else {
            Log.info("audio: no decoder for \(packet.sampleRate)Hz \(packet.channels)ch")
            return nil
        }

        if let cookie = AudioPacket.aacLCCookie(sampleRate: packet.sampleRate,
                                                channels: packet.channels) {
            made.magicCookie = cookie
        }

        converter = made
        sourceFormat = inFormat
        outputFormat = outFormat
        if !loggedFormat {
            loggedFormat = true
            Log.info("audio: decoding \(packet.sampleRate)Hz \(packet.channels)ch")
        }
        // The graph is wired for the old format; rebuild it for this one.
        teardownGraph()
        return made
    }

    // MARK: - Engine

    private func ensureEngineRunning(for format: AVAudioFormat) -> Bool {
        if engine.isRunning, player.engine != nil { return true }

        // **Exactly one player node, exactly one path to the mixer.**
        //
        // The failure this guards against is the classic one for a graph that
        // is rebuilt on every interruption and route change: a second node
        // attached without the first being detached, or a second `connect`
        // adding a second summing path, so the same PCM reaches the output
        // twice a few samples apart — a flanged echo that gets worse with each
        // reconnect and that no packet counter can see.
        //
        // Measured rather than assumed (`AudioGraphTests`): `attach` of an
        // already-attached node is a no-op, and `connect` on an output bus that
        // is already connected *replaces* that connection rather than adding
        // one. The disconnect below is therefore redundant today and is kept
        // because the invariant is what matters, not the current
        // implementation's kindness — and because it makes the rebuild
        // idempotent by construction rather than by the framework's grace.
        if player.engine == nil { engine.attach(player) }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            // Re-assert the mute state: the node is freshly connected, and a
            // graph rebuilt after an interruption or a format change would
            // otherwise come back at full volume.
            player.volume = muted ? 0 : 1
            player.play()
            loggedStartFailure = false
            logGraph(decoded: format)
            return true
        } catch {
            // Log once: this is called per packet, and a device that refuses to
            // start the engine refuses every time.
            if !loggedStartFailure {
                loggedStartFailure = true
                Log.info("audio: engine would not start (\(error)) — no playback")
            }
            return false
        }
    }

    /// One line per engine start, naming the whole graph.
    ///
    /// Two things it makes visible that nothing else did:
    ///
    /// * **the node and connection counts**, so "the graph grew a second path"
    ///   is a line in the log rather than a thing someone has to suspect;
    /// * **the three sample rates**. A mismatch between what was decoded and
    ///   what the hardware runs at means everything is going through a
    ///   resampler, and a resampler that is re-created on every rebuild is
    ///   another way to get a faint artefact that survives every packet-level
    ///   fix.
    private func logGraph(decoded: AVAudioFormat) {
        let report = AudioGraphReport(
            playerNodes: engine.attachedNodes.filter { $0 is AVAudioPlayerNode }.count,
            connectionPoints: engine.outputConnectionPoints(for: player, outputBus: 0).count,
            decodedRate: decoded.sampleRate,
            decodedChannels: Int(decoded.channelCount),
            mixerRate: engine.mainMixerNode.outputFormat(forBus: 0).sampleRate,
            outputRate: engine.outputNode.outputFormat(forBus: 0).sampleRate,
            sessionRate: Self.hardwareSampleRate)
        Log.info(report.line)
    }

    /// What the audio session says the hardware is actually running at, where
    /// there is a session to ask (iOS). Nil on macOS, where the receiver's
    /// output device rate is the engine's output format and already on the line.
    private static var hardwareSampleRate: Double? {
        #if os(iOS)
        let rate = AVAudioSession.sharedInstance().sampleRate
        return rate > 0 ? rate : nil
        #else
        return nil
        #endif
    }

    private func teardownGraph() {
        player.stop()
        if engine.isRunning { engine.stop() }
        if player.engine != nil { engine.disconnectNodeOutput(player) }
        // The decoder keeps MDCT overlap state across packets. Whatever is
        // decoded next is not adjacent to whatever was decoded last, so it must
        // not be overlap-added onto it.
        decoderNeedsReset = true
    }
}

/// The audio graph, as one line, with the invariant that matters stated as a
/// property rather than as a hope.
///
/// Pure so a test can assert the sentence and the invariant without an audio
/// device — and so the invariant is checkable at all, which is the point: the
/// round-7 brief's leading suspect for the echo was a graph that had grown a
/// second player node or a second connection across restarts, and neither of
/// those is visible from anywhere else.
struct AudioGraphReport: Equatable {
    let playerNodes: Int
    let connectionPoints: Int
    let decodedRate: Double
    let decodedChannels: Int
    let mixerRate: Double
    let outputRate: Double
    /// The hardware rate from the audio session, where there is one.
    let sessionRate: Double?

    /// The only shape a correct graph has: one player node, one path out of it.
    var isSound: Bool { playerNodes == 1 && connectionPoints == 1 }

    /// True when the decoded audio has to be resampled on its way out. Not an
    /// error — AVAudioEngine does it correctly — but it is the difference
    /// between "the rates agree" and "everything is going through a converter",
    /// and only one of those is worth suspecting.
    var resamples: Bool { decodedRate != outputRate }

    var line: String {
        var text = "engine graph: \(playerNodes) player node"
            + (playerNodes == 1 ? "" : "s")
            + ", \(connectionPoints) connection point"
            + (connectionPoints == 1 ? "" : "s")
            + ", format \(Int(decodedRate))Hz \(decodedChannels)ch"
            + " → mixer \(Int(mixerRate))Hz → output \(Int(outputRate))Hz"
        if let sessionRate { text += " (session \(Int(sessionRate))Hz)" }
        if resamples {
            text += " — RESAMPLED: decoded \(Int(decodedRate))Hz into a \(Int(outputRate))Hz output"
        }
        if !isSound {
            text += " — WRONG: exactly one player node with exactly one connection is the "
                + "only correct shape; anything else sums the same audio through two paths"
        }
        return text
    }
}
