import XCTest

/// Choosing which Mac drives the iPad.
///
/// The operator has a Mac Studio and a MacBook Pro, both on the same LAN and
/// the same tailnet, both running senders. Senders dial and the receiver
/// listens, so "the first sender to dial wins instantly" is not a bug in either
/// sender — it is the absence of an arbiter. These pin the arbiter.
final class SenderChoiceTests: XCTestCase {

    private let studio = SenderIdentity(id: "1111-STUDIO", host: "Mac Studio")
    private let laptop = SenderIdentity(id: "2222-LAPTOP", host: "MacBook Pro")

    // MARK: - Who is refused

    func testAnyMacAcceptsEverySender() {
        // The default, and every build before this one.
        XCTAssertFalse(SenderChoice.shouldReject(preferred: SenderChoice.anyMac, senderID: studio.id))
        XCTAssertFalse(SenderChoice.shouldReject(preferred: SenderChoice.anyMac, senderID: laptop.id))
        XCTAssertFalse(SenderChoice.shouldReject(preferred: SenderChoice.anyMac, senderID: nil))
    }

    func testTheChosenMacIsAccepted() {
        XCTAssertFalse(SenderChoice.shouldReject(preferred: studio.id, senderID: studio.id))
    }

    func testEveryOtherMacIsRefused() {
        XCTAssertTrue(SenderChoice.shouldReject(preferred: studio.id, senderID: laptop.id))
    }

    func testASenderThatCannotIdentifyItselfIsRefusedWhileAChoiceIsInForce() {
        // A stock build, or anything older than this round, sends no `senderID`.
        // It can never be the chosen one, so accepting it would mean the
        // preference silently does not apply to precisely the Mac the user did
        // not pick. "Any Mac" takes it back, which is the way out.
        XCTAssertTrue(SenderChoice.shouldReject(preferred: studio.id, senderID: nil))
        XCTAssertFalse(SenderChoice.shouldReject(preferred: SenderChoice.anyMac, senderID: nil))
    }

    // MARK: - Remembering the Macs

    func testASenderIsRememberedTheFirstTimeItIntroducesItself() {
        let known = SenderChoice.merge([], seen: studio)
        XCTAssertEqual(known, [studio])
    }

    func testTheSameSenderIsNotRememberedTwice() {
        var known = SenderChoice.merge([], seen: studio)
        known = SenderChoice.merge(known, seen: studio)
        known = SenderChoice.merge(known, seen: laptop)
        known = SenderChoice.merge(known, seen: studio)
        XCTAssertEqual(known, [studio, laptop])
    }

    func testARenamedMacUpdatesItsLabelAndKeepsItsPlace() {
        // Identity is the UUID; the host name is a label. A Mac renamed in
        // Sharing settings must not turn into a second entry, and must not jump
        // to the bottom of a list the user has learned the shape of.
        var known = SenderChoice.merge([], seen: studio)
        known = SenderChoice.merge(known, seen: laptop)
        let renamed = SenderIdentity(id: studio.id, host: "Studio (office)")
        known = SenderChoice.merge(known, seen: renamed)
        XCTAssertEqual(known, [renamed, laptop])
    }

    func testAnEmptyHostNameDoesNotEraseAKnownOne() {
        var known = SenderChoice.merge([], seen: studio)
        known = SenderChoice.merge(known, seen: SenderIdentity(id: studio.id, host: ""))
        XCTAssertEqual(known.first?.host, "Mac Studio")
    }

    func testASenderWithNoIdIsNotRemembered() {
        XCTAssertEqual(SenderChoice.merge([], seen: SenderIdentity(id: "", host: "Nameless")), [])
    }

    func testAPreferenceForAForgottenMacFallsBackToAnyMac() {
        // Otherwise the receiver refuses everything with no way back from a UI
        // that no longer lists the Mac being insisted on.
        XCTAssertEqual(SenderChoice.validate(preferred: studio.id, against: [laptop]),
                       SenderChoice.anyMac)
        XCTAssertEqual(SenderChoice.validate(preferred: studio.id, against: [studio, laptop]),
                       studio.id)
        XCTAssertEqual(SenderChoice.validate(preferred: SenderChoice.anyMac, against: [studio]),
                       SenderChoice.anyMac)
    }

    func testTheKnownListRoundTripsThroughDefaults() {
        let list = [studio, laptop]
        XCTAssertEqual(SenderChoice.decode(SenderChoice.encode(list)), list)
    }

    func testAMalformedStoredListIsEmptyRatherThanFatal() {
        XCTAssertEqual(SenderChoice.decode(nil), [])
        XCTAssertEqual(SenderChoice.decode("nonsense"), [])
        XCTAssertEqual(SenderChoice.decode([["host": "no id here"]]), [])
    }

    func testSenderIdentityFallsBackToItsIdWhenItHasNoName() {
        XCTAssertEqual(SenderIdentity(id: "abc", host: "").displayName, "abc")
        XCTAssertEqual(studio.displayName, "Mac Studio")
    }

    // MARK: - The `rejected` message

    func testTheDefaultBackoffIsThirtySeconds() {
        XCTAssertEqual(SenderChoice.defaultRetryAfterMs, 30_000)
    }

    func testSwitchingUsesAMuchShorterBackoff() {
        // "Switch to…" is a swap, not a ban: if the Mac just chosen is not
        // actually running, the one being left comes back in seconds.
        XCTAssertLessThan(SenderChoice.switchRetryAfterMs, SenderChoice.defaultRetryAfterMs)
    }

    func testAPeerSuppliedBackoffIsClamped() {
        // The wire is unauthenticated and this number decides how long a Mac
        // stops working. Zero would be a redial storm; a day would be a session
        // the user can only fix by quitting the app.
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs(0), RejectionMessage.minRetryAfterMs)
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs(-5_000), RejectionMessage.minRetryAfterMs)
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs(86_400_000), RejectionMessage.maxRetryAfterMs)
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs(30_000), 30_000)
    }

    func testAnAbsentBackoffIsTheDefault() {
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs(nil), SenderChoice.defaultRetryAfterMs)
        XCTAssertEqual(RejectionMessage.clampRetryAfterMs("soon"), SenderChoice.defaultRetryAfterMs)
    }

    func testThePayloadIsTheDocumentedShape() {
        let payload = RejectionMessage.payload(retryAfterMs: 30_000,
                                               reason: RejectionMessage.reasonOtherMacSelected)
        XCTAssertEqual(payload["type"] as? String, "rejected")
        XCTAssertEqual(payload["retryAfterMs"] as? Int, 30_000)
        XCTAssertEqual(payload["reason"] as? String, "otherMacSelected")
        XCTAssertNotNil(try? JSONSerialization.data(withJSONObject: payload),
                        "it has to survive being put on a wire")
    }

    func testTheWatchdogMarkerIsGreppable() {
        // The external watchdog's whole parser is
        // `grep -o 'rejected-by-receiver until=[0-9]*'`, so the token has to be
        // exactly that: one line, one epoch, no localisation.
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let line = RejectionMessage.markerLine(until: until, receiver: "iPad",
                                               reason: RejectionMessage.reasonOtherMacSelected)
        XCTAssertTrue(line.hasPrefix("rejected-by-receiver until=1800000000 "), line)
        XCTAssertTrue(line.contains("receiver=iPad"))
        XCTAssertTrue(line.contains("reason=otherMacSelected"))
        XCTAssertFalse(line.contains("\n"))
    }

    // MARK: - The sender's backoff

    func testARefusedTargetIsNotDialedUntilItsDeadline() {
        let now = Date()
        var backoff = RejectionBackoff()
        backoff.note("wifi:iPad", until: now.addingTimeInterval(30))
        XCTAssertTrue(backoff.isSuppressed("wifi:iPad", at: now))
        XCTAssertTrue(backoff.isSuppressed("wifi:iPad", at: now.addingTimeInterval(29)))
        XCTAssertFalse(backoff.isSuppressed("wifi:iPad", at: now.addingTimeInterval(31)))
    }

    func testOtherTargetsAreUnaffected() {
        var backoff = RejectionBackoff()
        backoff.note("wifi:iPad", until: Date().addingTimeInterval(30))
        XCTAssertFalse(backoff.isSuppressed("usb:1234", at: Date()))
    }

    func testAUserClickClearsTheBackoff() {
        let now = Date()
        var backoff = RejectionBackoff()
        backoff.note("wifi:iPad", until: now.addingTimeInterval(30))
        backoff.clear("wifi:iPad")
        XCTAssertFalse(backoff.isSuppressed("wifi:iPad", at: now))
    }

    func testTheRemainingTimeIsWhatThePanelCounts() {
        let now = Date()
        var backoff = RejectionBackoff()
        backoff.note("wifi:iPad", until: now.addingTimeInterval(30))
        XCTAssertEqual(backoff.remaining("wifi:iPad", at: now), 30, accuracy: 0.01)
        XCTAssertEqual(backoff.remaining("wifi:iPad", at: now.addingTimeInterval(60)), 0)
        XCTAssertEqual(backoff.remaining("never refused", at: now), 0)
    }

    func testExpiredDeadlinesArePrunedSoTheMapDoesNotGrow() {
        let now = Date()
        var backoff = RejectionBackoff()
        backoff.note("a", until: now.addingTimeInterval(-1))
        backoff.note("b", until: now.addingTimeInterval(30))
        backoff.prune(at: now)
        XCTAssertEqual(backoff.suppressedIDs, ["b"])
    }

    // MARK: - The sender's own id

    func testTheSenderIDIsCreatedOnceAndThenStable() {
        let defaults = UserDefaults(suiteName: "SenderChoiceTests.\(UUID().uuidString)")!
        let first = SenderIdentityStore.localSenderID(defaults)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(SenderIdentityStore.localSenderID(defaults), first)
        XCTAssertNotNil(UUID(uuidString: first), "a UUID, not a host name that can collide or change")
    }

    func testAnEmptyStoredSenderIDIsReplaced() {
        let defaults = UserDefaults(suiteName: "SenderChoiceTests.\(UUID().uuidString)")!
        defaults.set("", forKey: SenderIdentityStore.senderIDKey)
        XCTAssertFalse(SenderIdentityStore.localSenderID(defaults).isEmpty)
    }
}
