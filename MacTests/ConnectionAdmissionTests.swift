import XCTest

/// A probe must not be able to steal a session (§45).
///
/// The incident: an external watchdog ran `nc -z <ipad> 9000` every thirteen
/// seconds. The receiver accepted the connection, called it the session, logged
/// `status: Connected`, sent `hello` into it, reset the stream state — and then
/// the probe hung up. The iPad's round-6 log has eight of those between 12:03
/// and 12:04, which is why LTE-over-tailnet looked as though it had stopped
/// working.
final class ConnectionAdmissionTests: XCTestCase {

    /// A frame exactly as a sender writes it: 4-byte big-endian length, then
    /// the JSON. `welcome` is untagged by protocol rule (PROTOCOL.md 5).
    private func frame(_ json: String, tagged: Bool = false) -> Data {
        let payload = Data(json.utf8)
        let body = tagged ? Data([FrameType.json.rawValue]) + payload : payload
        var out = Data()
        var header = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &header) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    private let welcome = #"{"type":"welcome","pv":4,"min":1}"#

    // MARK: - What proves a sender

    func testAWelcomeProvesIt() {
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(welcome)),
                       .adopt(type: "welcome"))
    }

    func testATaggedGreetingAlsoProvesIt() {
        // Nothing in the protocol forbids a future sender tagging its greeting,
        // and a rule that refused it would be a compatibility trap we had set
        // for ourselves.
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(welcome, tagged: true)),
                       .adopt(type: "welcome"))
    }

    func testAnotherMacIsRefusedBeforeItCanReplaceTheSession() {
        let studio = frame(#"{"type":"welcome","senderID":"studio","host":"Mac Studio"}"#)
        XCTAssertEqual(ConnectionAdmission.judge(buffered: studio,
                                                 preferredSenderID: "macbook"),
                       .refuse(reason: RejectionMessage.reasonOtherMacSelected,
                               sender: SenderIdentity(id: "studio", host: "Mac Studio")))
        XCTAssertEqual(ConnectionAdmission.judge(buffered: studio,
                                                 preferredSenderID: "studio"),
                       .adopt(type: "welcome"))
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(welcome),
                                                 preferredSenderID: "macbook"),
                       .refuse(reason: RejectionMessage.reasonOtherMacSelected, sender: nil))
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(#"{"type":"ping","senderID":"studio"}"#),
                                                 preferredSenderID: "macbook"), .keepReading)
    }

    func testChosenMacCanSendOtherFramesBeforeWelcome() {
        var proof = ConnectionAdmission.Proof()
        let ping = frame(#"{"type":"ping"}"#)
        let macbook = frame(#"{"type":"welcome","senderID":"macbook"}"#)
        XCTAssertEqual(proof.read(Data(ping.prefix(3)), preferredSenderID: "macbook"), .keepReading)
        XCTAssertEqual(proof.read(Data(ping.dropFirst(3)) + Data(macbook.prefix(5)),
                                  preferredSenderID: "macbook"), .keepReading)
        XCTAssertEqual(proof.read(Data(macbook.dropFirst(5)), preferredSenderID: "macbook"),
                       .adopt(type: "welcome"))
        XCTAssertEqual(proof.buffered, ping + macbook)

        var rival = ConnectionAdmission.Proof()
        let studio = frame(#"{"type":"welcome","senderID":"studio","host":"Mac Studio"}"#)
        XCTAssertEqual(rival.read(ping + studio, preferredSenderID: "macbook"),
                       .refuse(reason: RejectionMessage.reasonOtherMacSelected,
                               sender: SenderIdentity(id: "studio", host: "Mac Studio")))
    }

    func testLargePreWelcomeFrameIsSkippedWithoutBuffering() {
        var frame = Data()
        var length = UInt32(100_000).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(Data(repeating: 0x65, count: 100_000))
        let welcome = self.frame(#"{"type":"welcome","senderID":"macbook"}"#)
        var proof = ConnectionAdmission.Proof()
        XCTAssertEqual(proof.read(Data(frame.prefix(20)), preferredSenderID: "macbook"), .keepReading)
        XCTAssertTrue(proof.buffered.isEmpty)
        XCTAssertEqual(proof.read(Data(frame.dropFirst(20).prefix(50_000)),
                                  preferredSenderID: "macbook"), .keepReading)
        XCTAssertEqual(proof.read(Data(frame.dropFirst(50_020)) + welcome,
                                  preferredSenderID: "macbook"), .adopt(type: "welcome"))
        XCTAssertEqual(proof.buffered, welcome)
        XCTAssertTrue(proof.droppedVideo)
    }

    func testAPartialFrameIsNotYetAVerdict() {
        let full = frame(welcome)
        for prefix in [0, 1, 3, 4, 10, full.count - 1] {
            XCTAssertEqual(ConnectionAdmission.judge(buffered: full.prefix(prefix)),
                           .keepReading, "\(prefix) bytes is not a decision")
        }
    }

    // MARK: - What does not

    func testTheWatchdogProbeIsRefused() {
        // `nc -z` opens the connection, sends nothing, closes it. This is the
        // exact shape of the round-6 incident.
        guard case .reject(let reason) = ConnectionAdmission.judge(buffered: Data(),
                                                                  closed: true) else {
            return XCTFail("an empty connection that closed must be refused")
        }
        XCTAssertTrue(reason.contains("port probe"), reason)
    }

    func testSilenceTimesOutRatherThanHoldingASlotForever() {
        guard case .reject = ConnectionAdmission.judge(buffered: Data(), timedOut: true) else {
            return XCTFail("a silent connection must not hold a slot")
        }
        XCTAssertEqual(ConnectionAdmission.proofTimeout, 5)
    }

    func testBytesAloneAreNotProof() {
        // Round 6's rule was "sent some bytes", which a port scanner's banner,
        // an HTTP request or any stray byte satisfies.
        XCTAssertEqual(ConnectionAdmission.judge(buffered: Data("GET / HTTP/1.1\r\n".utf8)),
                       .keepReading)
        guard case .reject = ConnectionAdmission.judge(buffered: Data("GET / HTTP/1.1\r\n".utf8),
                                                       closed: true) else {
            return XCTFail("noise that then hung up is not a sender")
        }
    }

    func testJSONThatIsNotAControlMessageIsRefused() {
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(#"{"hello":"there"}"#)),
                       .keepReading, "no `type`, so not yet a control message")
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(#"[1,2,3]"#)), .keepReading)
        XCTAssertEqual(ConnectionAdmission.judge(buffered: frame(#"{"type":""}"#)), .keepReading)
    }

    func testAnAbsurdLengthPrefixCannotMakeUsBufferTheInternet() {
        var out = Data()
        var header = UInt32.max.bigEndian
        withUnsafeBytes(of: &header) { out.append(contentsOf: $0) }
        out.append(Data(repeating: 0x41, count: 16))
        XCTAssertNil(ConnectionAdmission.greetingType(in: out))
        XCTAssertEqual(ConnectionAdmission.judge(buffered: out), .keepReading)
        guard case .reject = ConnectionAdmission.judge(buffered: out,
                                                      preferredSenderID: "macbook") else {
            return XCTFail("a chosen-Mac proof must reject an impossible frame length")
        }
    }

    func testAFloodIsCutOffRatherThanBuffered() {
        let flood = Data(repeating: 0x41, count: ConnectionAdmission.maxGreetingBytes + 1)
        guard case .reject(let reason) = ConnectionAdmission.judge(buffered: flood) else {
            return XCTFail("a peer that sends a megabyte of noise is not a sender")
        }
        XCTAssertTrue(reason.contains("without a control message"), reason)
    }

    func testAZeroLengthFrameIsNotAGreeting() {
        var out = Data([0, 0, 0, 0])
        out.append(frame(welcome))
        // The first frame is empty; the parser must not read the `welcome`
        // behind it as if it were that frame's body.
        XCTAssertNil(ConnectionAdmission.greetingType(in: out))
    }

    // MARK: - The type that comes back

    func testTheVerdictNamesTheMessageSoTheLogCanSayWhatProvedIt() {
        XCTAssertEqual(ConnectionAdmission.greetingType(in: frame(#"{"type":"welcome"}"#)),
                       "welcome")
        XCTAssertEqual(ConnectionAdmission.greetingType(in: frame(#"{"type":"rejected"}"#)),
                       "rejected")
    }
}
