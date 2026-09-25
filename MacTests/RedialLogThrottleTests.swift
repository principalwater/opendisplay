import XCTest

/// A dial that cannot reach its receiver used to write a line per attempt for
/// the life of the process: every 6 s when the name is unreachable, about once
/// a second when the device is up with the app closed. Retrying is right — the
/// remote path depends on it — but the log is read by people and by the
/// watchdog, which looks at the last 200 lines only.
final class RedialLogThrottleTests: XCTestCase {

    func testTheFirstAttemptsAreSpokenPlainly() {
        var throttle = RedialLogThrottle()
        for attempt in 1...RedialLogThrottle.verbatimAttempts {
            XCTAssertEqual(throttle.note("preparing", now: Double(attempt)), .speak,
                           "attempt \(attempt) is someone watching a reconnect")
        }
    }

    func testItGoesQuietAndSummarisesOnceTheIntervalHasPassed() {
        var throttle = RedialLogThrottle()
        var now: TimeInterval = 0
        for _ in 1...RedialLogThrottle.verbatimAttempts {
            now += 1
            _ = throttle.note("preparing", now: now)
        }

        var silent = 0
        while now < RedialLogThrottle.summaryInterval {
            now += 1
            if throttle.note("preparing", now: now) == .quiet { silent += 1 }
        }
        XCTAssertGreaterThan(silent, 100, "the quiet run has to actually be quiet")

        now += RedialLogThrottle.summaryInterval
        XCTAssertEqual(throttle.note("preparing", now: now),
                       .summarise(suppressed: silent + 1),
                       "the summary accounts for every attempt it swallowed")
    }

    func testTheCountStartsAgainAfterASummary() {
        var throttle = RedialLogThrottle()
        var now: TimeInterval = 0
        for _ in 1...RedialLogThrottle.verbatimAttempts { now += 1; _ = throttle.note("x", now: now) }
        now += RedialLogThrottle.summaryInterval
        guard case .summarise = throttle.note("x", now: now) else {
            return XCTFail("expected the first summary")
        }
        now += 1
        XCTAssertEqual(throttle.note("x", now: now), .quiet,
                       "a summary resets the clock, it does not open the floodgates")
    }

    func testADifferentFailureIsNewsAndStartsTheCountAgain() {
        var throttle = RedialLogThrottle()
        var now: TimeInterval = 0
        for _ in 1...20 { now += 1; _ = throttle.note("preparing", now: now) }
        now += 1
        XCTAssertEqual(throttle.note("Connection refused", now: now), .speak,
                       "a different failure mode is worth saying out loud")
    }

    func testASuccessfulDialMakesTheNextFailureNewsAgain() {
        var throttle = RedialLogThrottle()
        var now: TimeInterval = 0
        for _ in 1...20 { now += 1; _ = throttle.note("preparing", now: now) }
        throttle.reset()
        now += 1
        XCTAssertEqual(throttle.note("preparing", now: now), .speak)
    }
}
