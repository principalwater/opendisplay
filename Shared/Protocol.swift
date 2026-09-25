// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 4

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Protocol version that introduced tagged frames (see `FrameType`). Below
    /// this, a frame's kind is inferred from its bytes; at or above it, the
    /// frame carries an explicit type byte and audio becomes expressible.
    static let taggedFrameVersion = 4

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// What a frame carries, as the explicit type byte of a tagged frame
/// (protocol 4+, PROTOCOL.md 5).
///
/// Before protocol 4 the kind was *inferred*: a payload starting with `{` and
/// containing no NUL byte was control JSON, anything else was video. That
/// worked only because the two kinds happened to be distinguishable — video
/// frames also begin with `{` (a telemetry prefix) and were told apart by the
/// NUL bytes in their Annex B start codes. Compressed audio has neither
/// property reliably, so a third kind cannot join that scheme: an audio packet
/// whose first byte is `{` and which contains no NUL would be parsed as JSON.
/// Hence the explicit tag.
///
/// Unknown raw values are skipped by the receiver rather than treated as an
/// error, which is what keeps a future type additive for older peers.
enum FrameType: UInt8 {
    case video = 0      // Annex B H.264
    case json = 1       // control message
    case audio = 2      // compressed audio packet (AudioPacket)
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let admitted = "admitted"                // receiver -> Mac: chosen sender may create its display
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let streamConfig = "streamConfig"        // Mac -> receiver: selected video operating point
}

/// One receiver-supported operating envelope. Every non-nil limit in an
/// entry applies together; multiple entries for the same codec are alternatives.
/// Codec names stay strings so older builds can ignore future codecs.
struct VideoCapability: Codable, Equatable {
    let codec: String
    let maxWidth: Int?
    let maxHeight: Int?
    let maxFrameRate: Int?
    let maxPixelsPerSecond: Int?

    init(codec: String, maxWidth: Int? = nil, maxHeight: Int? = nil,
         maxFrameRate: Int? = nil, maxPixelsPerSecond: Int? = nil) {
        self.codec = codec
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFrameRate = maxFrameRate
        self.maxPixelsPerSecond = maxPixelsPerSecond
    }
}

/// When a receiver may bind its listening port again after taking it down.
///
/// Pure, because the round-5 failure was entirely a matter of *timing* and had
/// nothing to do with networking:
///
/// ```
/// listener not healthy — restarting
/// status: Listening on :9000
/// listener failed: POSIXErrorCode(48): Address already in use — restarting in 1s
/// ```
///
/// `NWListener.cancel()` is asynchronous — the socket is released when the
/// listener reaches `.cancelled` — and the old code rebound in the same turn of
/// the queue, then retried on a flat one-second timer that hit the same wall.
/// `allowLocalEndpointReuse` does not help; it relaxes the rules for a socket
/// in `TIME_WAIT`, not for one that is still open.
enum ListenerRestartPolicy {

    /// How long to wait before rebinding after a failure: 1, 2, 4, 8, 8 … s.
    ///
    /// Capped, because the failure this backs off from is transient and a
    /// receiver that waits a minute to start listening is a receiver nobody
    /// can connect to.
    static func backoff(failures: Int) -> TimeInterval {
        min(pow(2, Double(max(failures, 1) - 1)), 8)
    }

    /// Whether a health check should take the listener down.
    ///
    /// Two rules, and the second is the one round 5 was missing:
    ///
    /// 1. a listener that is genuinely up is left alone — and "up" means the
    ///    listener object says `.ready`, not that a cached `Bool` was last set
    ///    to true by a callback that may have come from a listener which no
    ///    longer exists;
    /// 2. a restart already in flight is never joined by a second, because the
    ///    second one cancels the listener the first has just created. The
    ///    round-5 log has a failure timer, a foreground health check and a
    ///    retired listener's stale callback all asking inside one second.
    static func shouldRestart(listenerIsLive: Bool, rebindInFlight: Bool) -> Bool {
        !listenerIsLive && !rebindInFlight
    }
}

/// Whether a connection that has just been accepted may become **the session**.
///
/// The incident this exists for: an external watchdog ran `nc -z <ipad> 9000`
/// every thirteen seconds. That opens a TCP connection, sends nothing and
/// closes it. The receiver accepted it, called it the session, logged
/// `status: Connected`, sent `hello` into it and reset the stream state — and
/// the live session, if there was one, was gone. The iPad's log at 12:03–12:04
/// is eight of those in ninety seconds, which is why streaming over the tailnet
/// looked like it had stopped working.
///
/// The watchdog has since been changed, but a receiver that can be taken over
/// by anything that completes a TCP handshake is wrong regardless of who is
/// scanning the port — a router's service discovery, a security scanner, a
/// mistyped `telnet`. Round 6 had half the rule: a newcomer arriving *while a
/// connection was in hand* had to send bytes first. Two gaps were left, and
/// both are closed here:
///
/// 1. with no connection in hand, every newcomer was adopted immediately, so a
///    probe still churned the session state and the status line;
/// 2. "bytes" was the whole test, so a port scanner that sends a banner, or any
///    stray byte, still qualified.
///
/// The proof is now a **frame the sender could have sent**: a 4-byte
/// big-endian length followed by a JSON control message. A chosen sender is
/// identified by `welcome`; cursor, ping, or video frames can precede it.
enum ConnectionAdmission {

    /// How long a newcomer has to prove itself before it is dropped.
    ///
    /// Generous on purpose: this is one round trip after the receiver's
    /// `hello`, over links that include LTE and a tailnet relay. Short enough
    /// that a probe cannot hold a slot, long enough that a real sender on a bad
    /// link never loses one.
    static let proofTimeout: TimeInterval = 5

    /// The largest greeting worth reading. A `welcome` is ~60 bytes; anything
    /// past this is not a handshake and must not be buffered.
    static let maxGreetingBytes = 64 * 1024
    /// A pre-welcome video frame can be large. Skip its body without keeping
    /// it in memory, but reject absurd length prefixes immediately.
    /// ponytail: raise this ceiling only if a measured keyframe exceeds 8 MiB.
    static let maxCandidateFrameBytes = 8 * 1024 * 1024

    enum Verdict: Equatable {
        /// A well-formed control frame arrived: this is a sender.
        case adopt(type: String)
        /// A valid sender, but the receiver is reserved for another Mac.
        case refuse(reason: String, sender: SenderIdentity?)
        /// Nothing conclusive yet — keep reading.
        case keepReading
        /// Never a sender. The reason is the log line.
        case reject(reason: String)
    }

    struct Proof {
        private(set) var buffered = Data()
        private var priorControl = Data()
        private(set) var droppedVideo = false
        private var bytesToSkip = 0
        private var receivedBytes = 0

        /// Keep control frames for `adopt(initialData:)`. With a chosen Mac,
        /// video before `welcome` is skipped and followed by a keyframe request.
        mutating func read(_ incoming: Data, preferredSenderID: String = SenderChoice.anyMac,
                           closed: Bool = false, timedOut: Bool = false) -> Verdict {
            receivedBytes += incoming.count
            var remaining = incoming
            if bytesToSkip > 0 {
                let count = min(bytesToSkip, remaining.count)
                remaining.removeFirst(count)
                bytesToSkip -= count
            }
            buffered.append(remaining)

            if preferredSenderID.isEmpty {
                if let type = ConnectionAdmission.greeting(in: buffered)?["type"] as? String {
                    return .adopt(type: type)
                }
                if buffered.count > maxGreetingBytes {
                    return .reject(reason: "sent \(receivedBytes) bytes without a control message")
                }
            } else {
                while bytesToSkip == 0, buffered.count >= 4 {
                    let base = buffered.startIndex
                    var length: UInt32 = 0
                    for i in 0..<4 { length = (length << 8) | UInt32(buffered[base + i]) }
                    guard length > 0, length <= UInt32(maxCandidateFrameBytes) else {
                        return .reject(reason: "invalid opening frame length \(length)")
                    }
                    let frameBytes = 4 + Int(length)
                    if length > UInt32(maxGreetingBytes) && buffered.count < frameBytes {
                        droppedVideo = true
                        bytesToSkip = frameBytes - buffered.count
                        buffered.removeAll(keepingCapacity: true)
                        break
                    }
                    guard buffered.count >= frameBytes else { break }
                    if let greeting = ConnectionAdmission.greeting(in: buffered),
                       greeting["type"] as? String == WireMessage.welcome {
                        let senderID = greeting["senderID"] as? String
                        if SenderChoice.shouldReject(preferred: preferredSenderID, senderID: senderID) {
                            let sender = senderID.flatMap { id in
                                id.isEmpty ? nil : SenderIdentity(id: id, host: greeting["host"] as? String ?? "")
                            }
                            return .refuse(reason: RejectionMessage.reasonOtherMacSelected, sender: sender)
                        }
                        buffered = priorControl + buffered
                        return .adopt(type: WireMessage.welcome)
                    }
                    if ConnectionAdmission.greeting(in: buffered) != nil,
                       priorControl.count + frameBytes <= maxGreetingBytes {
                        priorControl.append(buffered.prefix(frameBytes))
                    } else {
                        droppedVideo = true
                    }
                    buffered.removeFirst(frameBytes)
                }
            }
            if closed {
                return .reject(reason: receivedBytes == 0
                               ? "closed without sending anything (a port probe, not a sender)"
                               : "closed after \(receivedBytes) byte(s) without an accepted control message")
            }
            if timedOut {
                return .reject(reason: receivedBytes == 0
                               ? "sent nothing within \(Int(proofTimeout))s"
                               : "sent \(receivedBytes) byte(s) in \(Int(proofTimeout))s without an accepted control message")
            }
            return .keepReading
        }
    }

    static func judge(buffered: Data, preferredSenderID: String = SenderChoice.anyMac,
                      closed: Bool = false, timedOut: Bool = false) -> Verdict {
        var proof = Proof()
        return proof.read(buffered, preferredSenderID: preferredSenderID,
                          closed: closed, timedOut: timedOut)
    }

    /// The `type` of the first complete JSON control frame in `data`, if there
    /// is one. Nil means "not yet, or not a control frame" — the two are told
    /// apart by the caller, which knows whether more bytes can still arrive.
    ///
    /// Deliberately tolerant of a *tagged* first frame as well: nothing in the
    /// protocol forbids a future sender from tagging its greeting, and a rule
    /// that rejected it would be a compatibility trap set for ourselves.
    static func greetingType(in data: Data) -> String? {
        greeting(in: data)?["type"] as? String
    }

    private static func greeting(in data: Data) -> [String: Any]? {
        guard data.count >= 4 else { return nil }
        let base = data.startIndex
        var length: UInt32 = 0
        for i in 0..<4 { length = (length << 8) | UInt32(data[base + i]) }
        guard length > 0, length <= UInt32(maxGreetingBytes) else { return nil }
        guard data.count >= 4 + Int(length) else { return nil }
        let body = data.subdata(in: (base + 4)..<(base + 4 + Int(length)))
        for candidate in [body, body.dropFirst()] where !candidate.isEmpty {
            guard candidate.first == UInt8(ascii: "{") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(candidate)),
                  let dict = object as? [String: Any],
                  let type = dict["type"] as? String, !type.isEmpty else { continue }
            return dict
        }
        return nil
    }
}
