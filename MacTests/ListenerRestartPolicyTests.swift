import XCTest

/// When the receiver's listening port may be bound again (§37).
final class ListenerRestartPolicyTests: XCTestCase {

    func testTheBackoffDoublesFromOneSecond() {
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 1), 1)
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 2), 2)
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 3), 4)
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 4), 8)
    }

    func testTheBackoffIsCapped() {
        // A receiver that waits a minute to start listening is a receiver
        // nobody can connect to.
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 5), 8)
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 50), 8)
    }

    func testTheFirstFailureIsNotFree() {
        // Round 5 retried immediately-ish on a flat 1 s timer and hit
        // EADDRINUSE every time; the first wait has to be a real one.
        XCTAssertGreaterThan(ListenerRestartPolicy.backoff(failures: 1), 0)
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: 0), 1,
                       "a nonsense count is treated as the first failure")
        XCTAssertEqual(ListenerRestartPolicy.backoff(failures: -3), 1)
    }

    func testALiveListenerIsNeverRestarted() {
        XCTAssertFalse(ListenerRestartPolicy.shouldRestart(listenerIsLive: true,
                                                           rebindInFlight: false))
        XCTAssertFalse(ListenerRestartPolicy.shouldRestart(listenerIsLive: true,
                                                           rebindInFlight: true))
    }

    func testASecondRestartNeverJoinsOneAlreadyInFlight() {
        // The second one cancels the listener the first has just created,
        // which is the loop in the round-5 log: a failure timer, a foreground
        // health check and a retired listener's stale callback all asking
        // inside the same second.
        XCTAssertFalse(ListenerRestartPolicy.shouldRestart(listenerIsLive: false,
                                                           rebindInFlight: true))
    }

    func testADeadListenerWithNothingInFlightIsRestarted() {
        XCTAssertTrue(ListenerRestartPolicy.shouldRestart(listenerIsLive: false,
                                                          rebindInFlight: false))
    }
}
