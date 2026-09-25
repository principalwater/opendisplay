import XCTest

/// One session per physical device, and the cable wins.
///
/// The incident these were written for: with the iPad cabled, the sender ran
/// the manual endpoint (`usb:first`) *and* the usbmuxd session (`usb:<udid>`)
/// against the same receiver. A receiver adopts one connection at a time, so
/// the two took it from each other every ~2 s for as long as the cable was in.
/// `dedupeSessions()` only ever dropped WiFi twins, and `autoConnect()`
/// re-dialled the manual endpoint the moment its session went away — so ending
/// the duplicate without gating the dial would just have made the loop faster.
final class SessionDedupeTests: XCTestCase {

    private let receiver = "install-A"
    private let otherReceiver = "install-B"
    private let udid = "00008103-0011"

    private func usb(_ id: String = "usb:00008103-0011",
                     udid: String = "00008103-0011",
                     install: String? = "install-A",
                     failed: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: id, kind: .usbDevice(udid: udid), failed: failed, installID: install)
    }

    private func manual(install: String? = "install-A", failed: Bool = false,
                        connected: Bool = true, tunnel: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: "usb:first", kind: .manualEndpoint, failed: failed,
                        installID: install, connected: connected,
                        manualEndpointIsTunnel: tunnel)
    }

    private func wifi(_ name: String = "iPad", install: String? = nil,
                      txt: String? = nil, failed: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: "wifi:\(name)", kind: .wifi, failed: failed,
                        installID: install, txtID: txt, serviceName: name)
    }

    private func doomed(_ sessions: [SessionSnapshot],
                        cabledNames: Set<String> = [],
                        attached: Set<String> = ["00008103-0011"]) -> [String] {
        SessionDedupe.duplicateSessionIDs(sessions, cabledDeviceNames: cabledNames,
                                          attachedUDIDs: attached)
    }

    // MARK: - The incident

    func testTheManualEndpointLosesToTheCableForTheSameReceiver() {
        XCTAssertEqual(doomed([manual(), usb()]), ["usb:first"])
    }

    func testTheCableSessionIsNeverTheOneDropped() {
        // Symmetry check: whichever order they appear in, the cable survives.
        XCTAssertEqual(doomed([usb(), manual()]), ["usb:first"])
    }

    func testAManualEndpointReachingADifferentReceiverIsLeftAlone() {
        // An iproxy tunnel or an SSH forward to a second iPad is a legitimate
        // second session, not a duplicate.
        XCTAssertTrue(doomed([manual(install: otherReceiver), usb()]).isEmpty)
    }

    func testAManualEndpointThatHasNotSaidHelloYetIsLeftAlone() {
        // Before `hello` there is no identity to compare, and guessing would
        // kill a session that might be reaching another device entirely. This
        // is the window the ping-pong lives in; it closes on the first hello.
        XCTAssertTrue(doomed([manual(install: nil), usb()]).isEmpty)
    }

    func testAFailedCableSessionDoesNotEvictTheManualEndpoint() {
        // A corpse holds no pipeline. Dropping the working manual session for
        // it would leave the user with nothing.
        XCTAssertTrue(doomed([manual(), usb(failed: true)]).isEmpty)
    }

    func testAnUnpluggedCableSessionDoesNotEvictTheManualEndpoint() {
        // The USB session lingers through its grace period after a detach. It
        // is on its way out and must not take the manual endpoint with it.
        XCTAssertTrue(doomed([manual(), usb()], attached: []).isEmpty)
    }

    func testTwoManualEndpointsCannotExist() {
        // There is only ever one `usb:first`; this is a sanity check that the
        // rule does not somehow drop a lone manual session.
        XCTAssertTrue(doomed([manual()]).isEmpty)
    }

    // MARK: - The WiFi rule, unchanged

    func testAWiFiTwinOfACabledDeviceIsDropped() {
        XCTAssertEqual(doomed([wifi(install: receiver), usb()]), ["wifi:iPad"])
    }

    func testAWiFiTwinIsMatchedByItsTXTIdWhenItsOwnHelloHasNotArrived() {
        XCTAssertEqual(doomed([wifi(txt: receiver), usb()]), ["wifi:iPad"])
    }

    func testAWiFiTwinIsMatchedByServiceNameForReceiversTooOldToHaveAnInstallID() {
        XCTAssertEqual(doomed([wifi("Alice's iPad"), usb(install: nil)],
                              cabledNames: ["Alice's iPad"]),
                       ["wifi:Alice's iPad"])
    }

    func testAWiFiSessionForAnotherDeviceSurvives() {
        XCTAssertTrue(doomed([wifi(install: otherReceiver), usb()]).isEmpty)
    }

    func testAFailedCableSessionDoesNotEvictAWorkingWiFiSession() {
        XCTAssertTrue(doomed([wifi(install: receiver), usb(failed: true)]).isEmpty)
    }

    func testTheManualEndpointStillEvictsItsOwnWiFiTwin() {
        // Preserved behaviour, for `usb:first` over **usbmuxd**: that session
        // is the cable by another name, and the cable beats WiFi.
        XCTAssertEqual(doomed([manual(), wifi(install: receiver)], attached: []),
                       ["wifi:iPad"])
    }

    // MARK: - Round 7: a tunnel is not a cable

    func testATunnelLosesItsWiFiTwinRatherThanWinningIt() {
        // `-host <tailnet address>` is the escape hatch of last resort, and the
        // precedence this file has documented since round 5 is
        // cable > Bonjour > manual endpoint. Until round 7 only the first half
        // was enforced, so an unreachable tailnet session held a receiver that
        // was sitting on the same LAN.
        XCTAssertEqual(doomed([manual(tunnel: true), wifi(install: receiver)], attached: []),
                       ["usb:first"])
    }

    func testTheEvictionIsAsymmetricSoNeitherKillsBoth() {
        // A rule where each could evict the other would return both ids and
        // the receiver would end up with no session at all.
        let result = doomed([manual(tunnel: true), wifi(install: receiver)], attached: [])
        XCTAssertEqual(result.count, 1)
    }

    func testATunnelIsNotEvictedByAWiFiSessionThatHasNotSaidHello() {
        // No `installID` means the LAN session has proved nothing yet. Dropping
        // a working tunnel for it would be trading a live session for a guess.
        XCTAssertTrue(doomed([manual(tunnel: true), wifi(install: nil, txt: receiver)],
                             attached: []).isEmpty)
    }

    func testATunnelIsNotEvictedByAWiFiSessionThatIsNotConnected() {
        let dialing = SessionSnapshot(id: "wifi:iPad", kind: .wifi, installID: receiver,
                                      serviceName: "iPad", connected: false)
        XCTAssertTrue(doomed([manual(tunnel: true), dialing], attached: []).isEmpty)
    }

    func testAllThreeAtOnceKeepsOnlyTheCable() {
        let result = Set(doomed([manual(), wifi(install: receiver), usb()]))
        XCTAssertEqual(result, ["usb:first", "wifi:iPad"])
    }

    func testNothingIsDroppedWhenEachSessionIsItsOwnDevice() {
        let sessions = [usb("usb:1", udid: "1", install: "A"),
                        usb("usb:2", udid: "2", install: "B"),
                        wifi("C", install: "C")]
        XCTAssertTrue(doomed(sessions, attached: ["1", "2"]).isEmpty)
    }

    // MARK: - Not re-dialling the manual endpoint

    private func shouldDial(_ sessions: [SessionSnapshot],
                            attached: Set<String> = ["00008103-0011"],
                            known: String? = "install-A") -> Bool {
        SessionDedupe.shouldDialManualEndpoint(sessions: sessions,
                                               attachedUDIDs: attached,
                                               knownInstallID: known)
    }

    func testTheManualEndpointIsNotRedialledWhileTheCableCoversIt() {
        // The other half of the fix. `autoConnect()` runs on every hello, every
        // browse event and every usbmux publish; without this the loop simply
        // restarts after each `end()`.
        XCTAssertFalse(shouldDial([usb()]))
    }

    func testItIsDialledWhenNothingIsRunning() {
        XCTAssertTrue(shouldDial([]))
    }

    func testItIsDialledWhenTheCableServesADifferentReceiver() {
        XCTAssertTrue(shouldDial([usb(install: otherReceiver)]))
    }

    func testItIsDialledWhenWeHaveNeverLearnedWhatItReaches() {
        // First run, or after `defaults delete`. There is nothing to compare,
        // so dial and find out — the dedupe catches the collision afterwards.
        XCTAssertTrue(shouldDial([usb()], known: nil))
    }

    func testItIsNotDialledTwice() {
        XCTAssertFalse(shouldDial([manual()]))
    }

    func testPullingTheCableRearmsItImmediately() {
        // The whole reason the gate is keyed on attachment rather than on a
        // session existing: the USB session is still there, retrying through
        // its grace period, but the cable is gone and the manual endpoint is
        // the only way back.
        XCTAssertFalse(shouldDial([usb()], attached: [udid]))
        XCTAssertTrue(shouldDial([usb()], attached: []))
    }

    func testAFailedCableSessionDoesNotSuppressTheManualEndpoint() {
        XCTAssertTrue(shouldDial([usb(failed: true)]))
    }

    func testALiveBonjourSessionNowSuppressesTheManualEndpoint() {
        // **Changed in round 5.** Until now WiFi had no claim on the manual
        // endpoint, on the reasoning that it is the worse transport. That was
        // true when Bonjour auto-connect only ran for 12 s at launch: the two
        // rarely met. Now that a known receiver is dialed over Bonjour at any
        // time, they meet constantly — and two endpoints pointed at one
        // receiver is the ping-pong of round 4 with different names on it.
        //
        // The order is cable > Bonjour > manual, and the gate is identity: this
        // only fires when the manual endpoint provably reaches the SAME
        // receiver (`knownInstallID`). A tunnel to a second iPad is untouched.
        XCTAssertFalse(shouldDial([wifi(install: receiver)]))
    }

    func testAManualEndpointReachingSomeOtherDeviceIsStillDialedOverBonjour() {
        XCTAssertTrue(shouldDial([wifi(install: otherReceiver)]))
    }

    // MARK: - Deciding BEFORE anything is built

    // The 20:25 incident, in one line of log each:
    //
    //   [20:25:05.280] phone hello (usb session)
    //   [20:25:05.378] phone hello (manual session)
    //   [20:25:05.570] virtual display created: id=139
    //   [20:25:05.607] two sessions for one device — dropping usb:first
    //   [20:25:05.910] virtual display created: id=140
    //
    // The verdict was right and 340 ms too late: both endpoints had built a
    // display and both had started an audio encoder, so the user saw a display
    // appear and vanish and heard the Mac twice. `admits` is the same rule
    // asked at the first hello, before `setupExtend`.

    private func admits(_ candidate: SessionSnapshot,
                        hello: String? = nil,
                        others: [SessionSnapshot] = [],
                        cabled: Set<String> = ["00008103-0011"],
                        map: [String: String] = ["00008103-0011": "install-A"]) -> Bool {
        SessionDedupe.admits(candidate, helloInstallID: hello, others: others,
                             cabledUDIDs: cabled, installIDByUDID: map)
    }

    func testTheManualEndpointIsRefusedAtHelloWhenTheCableCarriesTheSameReceiver() {
        // The persisted udid → install id map answers this without the USB
        // session having said anything at all — which is the whole point: at
        // 20:25 it had not.
        XCTAssertFalse(admits(manual(install: nil), hello: receiver, others: [usb(install: nil)]))
    }

    func testTheManualEndpointIsRefusedEvenBeforeTheUSBSessionExists() {
        XCTAssertFalse(admits(manual(install: nil), hello: receiver, others: []))
    }

    func testTheCabledSessionIsNeverTheOneRefused() {
        XCTAssertTrue(admits(usb(), hello: receiver, others: [manual()]))
    }

    func testASecondCableIsASecondDeviceAndIsAdmitted() {
        let second = SessionSnapshot(id: "usb:other", kind: .usbDevice(udid: "udid-B"),
                                     installID: otherReceiver)
        XCTAssertTrue(admits(second, hello: otherReceiver, others: [usb()],
                             cabled: [udid, "udid-B"],
                             map: [udid: receiver, "udid-B": otherReceiver]))
    }

    func testAManualEndpointReachingADifferentReceiverIsAdmitted() {
        // An iproxy tunnel to a second iPad is a legitimate second session.
        XCTAssertTrue(admits(manual(install: nil), hello: otherReceiver, others: [usb()]))
    }

    func testAnUnidentifiedHelloIsAdmitted() {
        // An old receiver that announces no install id cannot be matched to a
        // cable. Refusing it would be guessing, and the cost of guessing wrong
        // is a device that never gets a display.
        XCTAssertTrue(admits(manual(install: nil), hello: nil, others: [usb()]))
    }

    func testACableTheUserDisconnectedDoesNotVetoTheManualEndpoint() {
        // `cabledUDIDs` is "cables this app will actually drive", not "cables
        // that are plugged in": a device opted out of auto-connect, or one
        // whose USB session failed to start, must not suppress the only
        // endpoint that can still reach it.
        XCTAssertTrue(admits(manual(install: nil), hello: receiver, others: [], cabled: []))
    }

    func testAWiFiTwinIsAlsoRefusedBeforeItBuildsAnything() {
        XCTAssertFalse(admits(wifi(install: receiver), hello: receiver, others: [usb()]))
    }

    func testAWiFiSessionForAnUncabledDeviceIsAdmitted() {
        XCTAssertTrue(admits(wifi(install: otherReceiver), hello: otherReceiver, others: [usb()]))
    }

    // MARK: - Ending the manual session before it says hello

    private func coveredManuals(_ sessions: [SessionSnapshot],
                                cabled: Set<String> = ["00008103-0011"],
                                map: [String: String] = ["00008103-0011": "install-A"],
                                known: String? = "install-A") -> [String] {
        SessionDedupe.manualEndpointsCoveredByCable(sessions, cabledUDIDs: cabled,
                                                    installIDByUDID: map, knownInstallID: known)
    }

    func testAManualSessionThatHasNotSpokenYetIsEndedFromThePersistedIdentity() {
        // It is mid-dial, holds no display, and the cable already covers the
        // receiver it last reached. Ending it here is what stops it getting as
        // far as `setupExtend`.
        XCTAssertEqual(coveredManuals([manual(install: nil), usb(install: nil)]), ["usb:first"])
    }

    func testAManualSessionWithNoKnownIdentityAtAllIsLeftAlone() {
        XCTAssertTrue(coveredManuals([manual(install: nil)], known: nil).isEmpty)
    }

    func testItsOwnHelloBeatsThePersistedGuess() {
        // The endpoint was re-pointed at a different device since last launch.
        XCTAssertTrue(coveredManuals([manual(install: otherReceiver)]).isEmpty)
    }

    func testNothingIsEndedWithNoCableAttached() {
        XCTAssertTrue(coveredManuals([manual(), usb()], cabled: []).isEmpty)
    }

    func testOnlyManualSessionsAreEndedByThisRule() {
        XCTAssertTrue(coveredManuals([usb(), wifi(install: receiver)]).isEmpty)
    }

    // MARK: - The launch race the gate now closes

    func testTheDialIsRefusedFromThePersistedMapAloneAtLaunch() {
        // At launch nothing has a session and nothing has said hello, but the
        // udid → install id map survives from the last run. That is the only
        // thing that can answer before a display exists — and at 20:25 the
        // old gate, which needed a session WITH an install id, could not.
        XCTAssertFalse(SessionDedupe.shouldDialManualEndpoint(
            sessions: [], attachedUDIDs: [udid],
            installIDByUDID: [udid: receiver], knownInstallID: receiver))
    }

    func testTheDialIsStillAllowedWhenTheCableIsADifferentDevice() {
        XCTAssertTrue(SessionDedupe.shouldDialManualEndpoint(
            sessions: [], attachedUDIDs: [udid],
            installIDByUDID: [udid: otherReceiver], knownInstallID: receiver))
    }

    func testPullingTheCableRearmsTheDialWithTheMapStillInPlace() {
        // The map is persistent and keeps the pairing forever; attachment is
        // what changes. Unplugging must bring the manual endpoint back with no
        // extra state to reset.
        let map = [udid: receiver]
        XCTAssertFalse(SessionDedupe.shouldDialManualEndpoint(
            sessions: [], attachedUDIDs: [udid], installIDByUDID: map, knownInstallID: receiver))
        XCTAssertTrue(SessionDedupe.shouldDialManualEndpoint(
            sessions: [], attachedUDIDs: [], installIDByUDID: map, knownInstallID: receiver))
    }

    func testTheWholeIncidentCannotHappenAgain() {
        // Replays 20:25 with the new rules in the order the app asks them.
        let map = [udid: receiver]
        // 1. launch: the cable is known to be this receiver, so `usb:first` is
        //    never dialed in the first place.
        XCTAssertFalse(SessionDedupe.shouldDialManualEndpoint(
            sessions: [], attachedUDIDs: [udid], installIDByUDID: map, knownInstallID: receiver))
        // 2. and if it was already dialed (map learned a moment later), it is
        //    ended while still waiting to be greeted.
        XCTAssertEqual(SessionDedupe.manualEndpointsCoveredByCable(
            [manual(install: nil)], cabledUDIDs: [udid],
            installIDByUDID: map, knownInstallID: receiver), ["usb:first"])
        // 3. and if it survives that and says hello, it is refused before
        //    `setupExtend` — no display, no encoder, no audio.
        XCTAssertFalse(SessionDedupe.admits(manual(install: nil), helloInstallID: receiver,
                                            others: [], cabledUDIDs: [udid],
                                            installIDByUDID: map))
    }

    // MARK: - The loop cannot restart

    func testEndingTheDuplicateAndThenRedialingIsNotPossible() {
        // Walks the exact sequence of the incident: both sessions live, dedupe
        // ends the manual one, and the next autoConnect must NOT bring it back.
        let before = [manual(), usb()]
        let killed = doomed(before)
        XCTAssertEqual(killed, ["usb:first"])
        let after = before.filter { !killed.contains($0.id) }
        XCTAssertFalse(shouldDial(after), "this is the ping-pong")
    }
    // MARK: - Bonjour for receivers we already know (round 5)
    //
    // "Without Tailscale on the LAN nothing connects." The reason was two
    // rules, both of which happened to be wrong for this operator: WiFi
    // auto-connect matched a service *name* out of `wifiRemembered`, and it ran
    // only in a 12 s window at launch. An iPad whose receiver app is opened
    // thirteen seconds after the Mac app was never dialed at all.

    private func candidate(_ name: String = "iPad", txt: String? = "install-A",
                           serviceName: String? = nil)
        -> SessionDedupe.BonjourCandidate {
        SessionDedupe.BonjourCandidate(sessionID: "wifi:\(name)", txtID: txt,
                                       serviceName: serviceName)
    }

    private func toDial(_ candidates: [SessionDedupe.BonjourCandidate],
                        sessions: [SessionSnapshot] = [],
                        known: Set<String> = ["install-A"],
                        cabled: Set<String> = [],
                        map: [String: String] = [:],
                        manualKnown: String? = nil,
                        byName: [String: String] = [:]) -> [String] {
        SessionDedupe.knownBonjourToDial(candidates: candidates, sessions: sessions,
                                         knownInstallIDs: known, cabledUDIDs: cabled,
                                         installIDByUDID: map,
                                         manualEndpointInstallID: manualKnown,
                                         installIDByServiceName: byName)
    }

    private func decisions(_ candidates: [SessionDedupe.BonjourCandidate],
                           sessions: [SessionSnapshot] = [],
                           known: Set<String> = ["install-A"],
                           byName: [String: String] = [:])
        -> [SessionDedupe.BonjourDecision] {
        SessionDedupe.bonjourDecisions(candidates: candidates, sessions: sessions,
                                       knownInstallIDs: known, cabledUDIDs: [],
                                       installIDByUDID: [:],
                                       manualEndpointInstallID: nil,
                                       installIDByServiceName: byName)
    }

    func testAKnownReceiverOnBonjourIsDialedWithNoLaunchWindowAndNoNameMatch() {
        XCTAssertEqual(toDial([candidate()]), ["wifi:iPad"])
        // Renaming the device changes the service name and nothing else: the
        // TXT id is the identity.
        XCTAssertEqual(toDial([candidate("Alices iPad")]), ["wifi:Alices iPad"])
    }

    func testAnUnknownReceiverIsNotDialed() {
        // A flatmate opening the app on their own iPad is not consent. Those
        // still go through `wifiRemembered` and its launch window.
        XCTAssertTrue(toDial([candidate(txt: "install-STRANGER")]).isEmpty)
    }

    func testAServiceWithNoTXTRecordIsNotDialed() {
        // Browse results routinely arrive without their TXT record. Without an
        // id there is no identity, and matching on the name is exactly the rule
        // being removed.
        XCTAssertTrue(toDial([candidate(txt: nil)]).isEmpty)
    }

    func testAReceiverAlreadyOnTheCableIsNotDialedOverBonjour() {
        // Cable > Bonjour, unchanged and total — while the cable is in.
        XCTAssertTrue(toDial([candidate()], cabled: [udid],
                             map: [udid: receiver]).isEmpty)
        XCTAssertTrue(toDial([candidate()], sessions: [usb()], cabled: [udid]).isEmpty)
    }

    func testAUsbSessionAloneNoLongerVetoesBonjour() {
        // This assertion used to read `sessions: [usb()]` with no cable at all,
        // and it passed — it was pinning the defect. A USB session outlives the
        // detach (it waits for a replug), so "a session exists" said nothing
        // about whether the cable was still there, and on 2026-09-22 unplugging
        // the iPad cost the LAN path until the sender was restarted. The veto
        // now needs the attachment fact; see StaleCableVetoTests.
        XCTAssertEqual(toDial([candidate()], sessions: [usb()]), ["wifi:iPad"])
    }

    func testAReceiverAlreadyStreamingOverTheManualEndpointIsNotDialedOverBonjour() {
        // Bonjour > manual as a *dial order*, but whichever is already live
        // wins: taking the connection away from a running session to rebuild it
        // one rung higher is the ping-pong, not an upgrade.
        XCTAssertTrue(toDial([candidate()], sessions: [manual()]).isEmpty)
    }

    func testAManualEndpointThatHasNotSaidHelloYetStillBlocksItsBonjourTwin() {
        // Same pre-emptive trick as `manualEndpointsCoveredByCable`: the
        // persisted id answers before the hello does, which is the window in
        // which both would otherwise build a display.
        XCTAssertTrue(toDial([candidate()], sessions: [manual(install: nil)],
                             manualKnown: receiver).isEmpty)
    }

    func testTheManualEndpointIsNotDialedWhileBonjourAlreadyServesTheReceiver() {
        // The other direction of the same rule.
        XCTAssertFalse(SessionDedupe.shouldDialManualEndpoint(
            sessions: [wifi(install: receiver)], attachedUDIDs: [],
            installIDByUDID: [:], knownInstallID: receiver))
        XCTAssertFalse(SessionDedupe.shouldDialManualEndpoint(
            sessions: [wifi(txt: receiver)], attachedUDIDs: [],
            installIDByUDID: [:], knownInstallID: receiver),
            "the TXT id counts before the hello arrives")
    }

    func testAFailedBonjourSessionDoesNotBlockTheManualEndpoint() {
        XCTAssertTrue(SessionDedupe.shouldDialManualEndpoint(
            sessions: [wifi(install: receiver, failed: true)], attachedUDIDs: [],
            installIDByUDID: [:], knownInstallID: receiver))
    }

    func testABonjourSessionThatIsAlreadyRunningIsNotDialedAgain() {
        XCTAssertTrue(toDial([candidate()], sessions: [wifi(install: receiver)]).isEmpty)
        XCTAssertTrue(toDial([candidate()], sessions: [wifi(txt: receiver)]).isEmpty)
    }

    func testAFailedBonjourSessionIsRedialed() {
        // A corpse holds no pipeline; leaving it in place would mean a receiver
        // that came back never being picked up again.
        XCTAssertEqual(toDial([candidate()], sessions: [wifi(install: receiver, failed: true)]),
                       ["wifi:iPad"])
    }

    func testOneReceiverAdvertisingTwiceIsDialedOnce() {
        // A device on two interfaces (WiFi and a bridged link) publishes two
        // services with the same TXT id. Dialing both is the ping-pong.
        XCTAssertEqual(toDial([candidate("iPad"), candidate("iPad-2")]), ["wifi:iPad"])
    }

    func testTwoDifferentKnownReceiversAreBothDialed() {
        // One session per *device*, not one session in total.
        let candidates = [candidate("iPad", txt: receiver),
                          candidate("iPhone", txt: otherReceiver)]
        XCTAssertEqual(toDial(candidates, known: [receiver, otherReceiver]),
                       ["wifi:iPad", "wifi:iPhone"])
    }

    func testTheWholeLANWithoutTailscaleStory() {
        // Launch: nothing known yet from this transport, the iPad is not
        // advertising, nothing is dialed.
        XCTAssertTrue(toDial([], known: [receiver]).isEmpty)
        // Ninety seconds later the operator opens the receiver app. The old
        // rule's 12 s window has long closed; the new one dials on identity.
        XCTAssertEqual(toDial([candidate()], known: [receiver]), ["wifi:iPad"])
        // It is running, so the next browse event does nothing.
        XCTAssertTrue(toDial([candidate()], sessions: [wifi(txt: receiver)],
                             known: [receiver]).isEmpty)
        // The cable is plugged in: the cable wins and the Bonjour twin is
        // dropped by the existing rule.
        XCTAssertEqual(doomed([wifi(txt: receiver), usb()], attached: [udid]), ["wifi:iPad"])
    }

    // MARK: - Round 7: why it still did not fire
    //
    // `bonjourKnownInstallIDs` *was* written — the operator's defaults hold the
    // right id — and `autoConnect()` *does* run on every browse change. Two
    // other things were wrong, and either alone was enough to make the feature
    // silent: the TXT record is often absent from a browse result, and an
    // unreachable `-host` session was counted as though it were serving the
    // receiver.

    func testAServiceWithNoTXTIsDialedWhenItsNameHasBeenPairedBefore() {
        // `NWBrowser.Result.metadata` is `.none` far more often than round 5
        // assumed. The name is never missing, so a name this Mac has itself
        // seen paired with an id is the fallback identity.
        XCTAssertEqual(toDial([candidate(txt: nil, serviceName: "iPad Pro 11")],
                              byName: ["iPad Pro 11": receiver]),
                       ["wifi:iPad"])
    }

    func testTheNameFallbackIsOnlyUsedWhenTheTXTIsActuallyAbsent() {
        // A TXT id that names a receiver we do not know is a *statement*, not a
        // gap: a second iPad that happens to have inherited the name must not
        // be dialed because of it.
        XCTAssertTrue(toDial([candidate(txt: "install-STRANGER", serviceName: "iPad Pro 11")],
                             byName: ["iPad Pro 11": receiver]).isEmpty)
    }

    func testAnUnknownNameIsStillNotDialed() {
        XCTAssertTrue(toDial([candidate(txt: nil, serviceName: "Someone else's iPad")],
                             byName: ["iPad Pro 11": receiver]).isEmpty)
    }

    func testAnUnreachableTunnelNoLongerSuppressesTheLANDial() {
        // The round-6 incident, exactly: 1373 consecutive
        // `connection waiting: Connection refused — will retry` lines from a
        // `-host` session that was, for every one of those seconds, the reason
        // the iPad on the same LAN was never dialed.
        let dialing = manual(connected: false, tunnel: true)
        XCTAssertEqual(toDial([candidate()], sessions: [dialing]), ["wifi:iPad"])
        XCTAssertEqual(toDial([candidate()], sessions: [manual(install: nil, connected: false,
                                                               tunnel: true)],
                              manualKnown: receiver), ["wifi:iPad"])
    }

    func testAConnectedTunnelStillKeepsTheReceiver() {
        // No churn: taking a working session away to rebuild it one rung higher
        // is the ping-pong, not an upgrade.
        XCTAssertTrue(toDial([candidate()], sessions: [manual(tunnel: true)]).isEmpty)
    }

    func testEveryBrowseResultGetsADecisionAndALine() {
        // Round 6 logged nothing at all for a result that did not match, which
        // made three different failures look like one silence.
        let all = decisions([candidate("iPad", txt: receiver),
                             candidate("Flatmate", txt: "install-STRANGER"),
                             candidate("Mystery", txt: nil, serviceName: "Mystery")])
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.dial), [true, false, false])
        XCTAssertEqual(all[0].matchedBy, .txtRecord)
        XCTAssertEqual(all[1].matchedBy, .none)
        XCTAssertEqual(all[2].matchedBy, .none)
        XCTAssertTrue(all[1].reason.contains("not a receiver this Mac has connected to"),
                      all[1].reason)
        XCTAssertTrue(all[2].reason.contains("no TXT id"), all[2].reason)
        for decision in all { XCTAssertFalse(decision.logLine.isEmpty) }
        XCTAssertTrue(all[0].logLine.contains("DIALING"), all[0].logLine)
    }

    func testTheDecisionLineNamesHowItWasRecognized() {
        let byName = decisions([candidate(txt: nil, serviceName: "iPad Pro 11")],
                               byName: ["iPad Pro 11": receiver])
        XCTAssertEqual(byName.first?.matchedBy, .serviceName)
        XCTAssertTrue(byName.first!.logLine.contains("remembered name"), byName.first!.logLine)
    }
}

// MARK: - The tunnel that outlived its usefulness

/// `shouldDialManualEndpoint` refuses to start a tunnel while Bonjour reaches
/// the receiver, but the tunnel is always started *first* — before any browse
/// result exists — so the refusal never applied to the one that mattered.
final class ManualTunnelSupersededTests: XCTestCase {

    private let receiver = "8E792EFE-C572-4035-9666-341042A1758E"

    private func tunnel(connected: Bool = false, failed: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: "usb:first", kind: .manualEndpoint, failed: failed,
                        connected: connected, manualEndpointIsTunnel: true)
    }

    private func lan(connected: Bool, txtID: String? = nil) -> SessionSnapshot {
        SessionSnapshot(id: "wifi:iPad Pro 11", kind: .wifi,
                        installID: txtID == nil ? receiver : nil, txtID: txtID,
                        connected: connected)
    }

    func testADialingTunnelIsRetiredOnceBonjourIsActuallyUp() {
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(), lan(connected: true)], knownInstallID: receiver)
        XCTAssertEqual(doomed, ["usb:first"])
    }

    func testTheTXTIdIsEnoughToRecogniseTheReceiverBeforeItsHello() {
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(), lan(connected: false, txtID: receiver)], knownInstallID: receiver)
        XCTAssertTrue(doomed.isEmpty, "a Bonjour session that is only dialing proves nothing")

        let up = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(), lan(connected: true, txtID: receiver)], knownInstallID: receiver)
        XCTAssertEqual(up, ["usb:first"])
    }

    func testATunnelCarryingTheSessionIsLeftAlone() {
        // Round 7 decides that one with the hello in hand; sweeping it up here
        // would cut a live stream.
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(connected: true), lan(connected: true)], knownInstallID: receiver)
        XCTAssertTrue(doomed.isEmpty)
    }

    func testAUsbmuxFirstIsNotATunnelAndTheCableAlwaysWins() {
        let cable = SessionSnapshot(id: "usb:first", kind: .manualEndpoint,
                                    connected: false, manualEndpointIsTunnel: false)
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [cable, lan(connected: true)], knownInstallID: receiver)
        XCTAssertTrue(doomed.isEmpty)
    }

    func testNothingIsRetiredWhenBonjourServesSomeOtherReceiver() {
        let other = SessionSnapshot(id: "wifi:someone else", kind: .wifi,
                                    installID: "OTHER-ID", connected: true)
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(), other], knownInstallID: receiver)
        XCTAssertTrue(doomed.isEmpty)
    }

    func testNothingIsRetiredBeforeThisMacHasEverIdentifiedTheReceiver() {
        let doomed = SessionDedupe.manualTunnelsCoveredByLAN(
            [tunnel(), lan(connected: true)], knownInstallID: nil)
        XCTAssertTrue(doomed.isEmpty, "with no known id the tunnel is the only lead")
    }
}

// MARK: - The cable that was already unplugged

/// Pulling the cable leaves the USB session behind: it does not end, it waits
/// for a replug. Until 2026-09-22 that waiting session vetoed every Bonjour
/// dial, so unplugging the iPad cost the LAN path until the sender restarted —
/// the operator saw "listening" on the iPad and nothing on the Mac.
final class StaleCableVetoTests: XCTestCase {

    private let receiver = "install-A"
    private let udid = "00008103-000979A821DB001E"

    private func usbSession(failed: Bool = false) -> SessionSnapshot {
        SessionSnapshot(id: "usb:\(udid)", kind: .usbDevice(udid: udid),
                        failed: failed, installID: receiver)
    }

    private func candidate() -> SessionDedupe.BonjourCandidate {
        SessionDedupe.BonjourCandidate(sessionID: "wifi:iPad", txtID: receiver,
                                       serviceName: "iPad")
    }

    private func dialed(cabled: Set<String>, map: [String: String] = [:]) -> [String] {
        SessionDedupe.knownBonjourToDial(candidates: [candidate()],
                                         sessions: [usbSession()],
                                         knownInstallIDs: [receiver],
                                         cabledUDIDs: cabled,
                                         installIDByUDID: map,
                                         manualEndpointInstallID: nil)
    }

    func testAUsbSessionWhoseCableIsGoneDoesNotVetoTheLanPath() {
        XCTAssertEqual(dialed(cabled: []), ["wifi:iPad"],
                       "the cable is out — Bonjour is the only way left to this receiver")
    }

    func testAnAttachedCableStillWins() {
        XCTAssertTrue(dialed(cabled: [udid]).isEmpty,
                      "cable beats Bonjour, and that precedence is unchanged")
    }

    func testTheCableIsRecognisedThroughThePersistedUdidMapToo() {
        // The session may not have said hello yet, so the id comes from the map.
        let noHello = SessionSnapshot(id: "usb:\(udid)", kind: .usbDevice(udid: udid))
        let dial = SessionDedupe.knownBonjourToDial(
            candidates: [candidate()], sessions: [noHello],
            knownInstallIDs: [receiver], cabledUDIDs: [udid],
            installIDByUDID: [udid: receiver], manualEndpointInstallID: nil)
        XCTAssertTrue(dial.isEmpty)
    }

    func testTheReasonIsRecordedForTheLog() {
        let refused = SessionDedupe.bonjourDecisions(
            candidates: [candidate()], sessions: [usbSession()],
            knownInstallIDs: [receiver], cabledUDIDs: [udid],
            installIDByUDID: [:], manualEndpointInstallID: nil)
        XCTAssertEqual(refused.first?.reason, "a cable session already serves this receiver")

        let allowed = SessionDedupe.bonjourDecisions(
            candidates: [candidate()], sessions: [usbSession()],
            knownInstallIDs: [receiver], cabledUDIDs: [],
            installIDByUDID: [:], manualEndpointInstallID: nil)
        XCTAssertTrue(allowed.first?.dial == true)
    }
}
