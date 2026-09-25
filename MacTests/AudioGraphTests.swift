import AVFoundation
import XCTest

/// **Exactly one player node, exactly one path out of it.**
///
/// The round-8 brief's leading suspect for the operator's echo: if a restart
/// attaches a new player node without detaching the old one, or connects the
/// same node to the mixer a second time, the same signal is summed through two
/// paths with slightly different latency — a faint flanging echo that survives
/// every packet-level fix and gets worse with every reconnect. The receiver
/// rebuilds its graph on every interruption, route change, foreground and
/// format change, so this is not a hypothetical shape.
///
/// It is not what is happening, and this file is why. These tests drive a
/// **real `AVAudioEngine`** through the exact rebuild cycle `AudioPlayer` runs
/// — attach, connect, start, stop, disconnect, repeat — and count what the
/// graph actually contains. No audio device is needed: the graph exists before
/// anything is started.
final class AudioGraphTests: XCTestCase {

    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

    private func playerNodes(in engine: AVAudioEngine) -> Int {
        engine.attachedNodes.filter { $0 is AVAudioPlayerNode }.count
    }

    // MARK: - The framework's actual behaviour

    func testConnectingTheSameNodeAgainReplacesTheConnectionRatherThanAddingOne() {
        // This is the measurement the audit turned on. If `connect` *added* a
        // path, every rebuild would add one more copy of the audio, and the
        // echo would be explained. It does not.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        XCTAssertEqual(engine.outputConnectionPoints(for: player, outputBus: 0).count, 1)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        XCTAssertEqual(engine.outputConnectionPoints(for: player, outputBus: 0).count, 1,
                       "three connects, one path")
    }

    func testAttachingAnAlreadyAttachedNodeIsANoOp() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(player)
        engine.attach(player)
        XCTAssertEqual(playerNodes(in: engine), 1)
    }

    func testTheRebuildCycleTheReceiverRunsNeverGrowsTheGraph() {
        // `teardownGraph()` then `ensureEngineRunning(for:)`, ten times — an
        // evening of backgrounding, interrupting and reconnecting.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        for _ in 0..<10 {
            if player.engine == nil { engine.attach(player) }
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            XCTAssertEqual(playerNodes(in: engine), 1)
            XCTAssertEqual(engine.outputConnectionPoints(for: player, outputBus: 0).count, 1)
            // The teardown half.
            if player.engine != nil { engine.disconnectNodeOutput(player) }
        }
        XCTAssertEqual(playerNodes(in: engine), 1, "ten rebuilds, one node")
    }

    func testTheGraphCheckWouldActuallyCatchASecondNode() {
        // A test that can only pass is worth nothing; this is the negative
        // control. Two player nodes, and the invariant says so.
        let engine = AVAudioEngine()
        let first = AVAudioPlayerNode()
        let second = AVAudioPlayerNode()
        engine.attach(first)
        engine.connect(first, to: engine.mainMixerNode, format: format)
        engine.attach(second)
        engine.connect(second, to: engine.mainMixerNode, format: format)
        XCTAssertEqual(playerNodes(in: engine), 2)
        let report = AudioGraphReport(playerNodes: playerNodes(in: engine),
                                      connectionPoints: 1,
                                      decodedRate: 48000, decodedChannels: 2,
                                      mixerRate: 48000, outputRate: 48000, sessionRate: nil)
        XCTAssertFalse(report.isSound)
        XCTAssertTrue(report.line.contains("WRONG"))
    }

    // MARK: - The line

    func testTheHealthyLineSaysOneNodeOneConnection() {
        let report = AudioGraphReport(playerNodes: 1, connectionPoints: 1,
                                      decodedRate: 48000, decodedChannels: 2,
                                      mixerRate: 48000, outputRate: 48000, sessionRate: 48000)
        XCTAssertTrue(report.isSound)
        XCTAssertFalse(report.resamples)
        XCTAssertEqual(report.line,
                       "engine graph: 1 player node, 1 connection point, format 48000Hz 2ch "
                       + "→ mixer 48000Hz → output 48000Hz (session 48000Hz)")
    }

    func testARateMismatchIsNamedOnTheLine() {
        // The third mechanism the brief asked about: decoded 48 kHz into a
        // session that is actually running at 44.1 kHz means everything goes
        // through a resampler, which is worth knowing before suspecting it.
        let report = AudioGraphReport(playerNodes: 1, connectionPoints: 1,
                                      decodedRate: 48000, decodedChannels: 2,
                                      mixerRate: 48000, outputRate: 44100, sessionRate: 44100)
        XCTAssertTrue(report.isSound)
        XCTAssertTrue(report.resamples)
        XCTAssertTrue(report.line.contains("RESAMPLED: decoded 48000Hz into a 44100Hz output"))
    }

    func testASecondConnectionPointIsNamedToo() {
        let report = AudioGraphReport(playerNodes: 1, connectionPoints: 2,
                                      decodedRate: 48000, decodedChannels: 2,
                                      mixerRate: 48000, outputRate: 48000, sessionRate: nil)
        XCTAssertFalse(report.isSound)
        XCTAssertTrue(report.line.contains("2 connection points"))
        XCTAssertTrue(report.line.contains("sums the same audio through two paths"))
    }

    func testTheLineOmitsTheSessionRateWhereThereIsNoSession() {
        let report = AudioGraphReport(playerNodes: 1, connectionPoints: 1,
                                      decodedRate: 48000, decodedChannels: 2,
                                      mixerRate: 48000, outputRate: 48000, sessionRate: nil)
        XCTAssertFalse(report.line.contains("session"))
    }
}
