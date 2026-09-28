import Foundation

/// How often a repeated connection event is allowed to say so.
///
/// A sender with a `-host` endpoint retries forever, and it should: that is
/// the remote path, and an iPad that comes back has to be picked up. What it
/// must not do is write a line every time. Both failure modes are chatty —
/// a dial to an unreachable name sits in `.preparing` until the 5 s deadline
/// (~10 lines a minute), and a dial to a device that is up with the app closed
/// is refused about once a second (round 6 has 1373 consecutive lines of it).
/// On alfheim-home that was essentially the whole idle log, and
/// `opendisplay-watchdog` reads only the last 200 lines to find its
/// `rejected-by-receiver until=` marker, so the flood crowds out the one line
/// it is looking for. The receiver also rejects an unselected sender every
/// two seconds while awaiting a host switch; it uses this same throttle.
///
/// The first few attempts are worth seeing — someone watching a reconnect is
/// reading them. After that the news is not "it failed again" but "it has been
/// failing for five minutes", which is one line. The throttle decides only
/// *whether* to speak; each call site keeps its own wording.
struct RedialLogThrottle {

    /// Attempts spoken plainly before the throttle engages.
    static let verbatimAttempts = 3
    /// How long a quiet run lasts before it is worth a summary.
    static let summaryInterval: TimeInterval = 300

    enum Verdict: Equatable {
        /// Log the ordinary line.
        case speak
        /// Say nothing.
        case quiet
        /// Log a summary; `suppressed` attempts went unsaid, this one included.
        case summarise(suppressed: Int)
    }

    private var topic: String?
    private var attempts = 0
    private var suppressed = 0
    private var lastSpokeAt: TimeInterval = 0

    /// `topic` is what is going wrong — the connection state, or the error.
    /// A change of topic is news, so it speaks and starts the count again.
    mutating func note(_ newTopic: String, now: TimeInterval) -> Verdict {
        if newTopic != topic {
            topic = newTopic
            attempts = 0
            suppressed = 0
        }
        attempts += 1
        if attempts <= Self.verbatimAttempts {
            lastSpokeAt = now
            return .speak
        }
        suppressed += 1
        guard now - lastSpokeAt >= Self.summaryInterval else { return .quiet }
        let quiet = suppressed
        suppressed = 0
        lastSpokeAt = now
        return .summarise(suppressed: quiet)
    }

    /// A dial succeeded, or the target changed: the next failure is news again.
    mutating func reset() {
        topic = nil
        attempts = 0
        suppressed = 0
        lastSpokeAt = 0
    }
}
