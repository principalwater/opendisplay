import XCTest
import Testing

/// The sender's audio preferences are two booleans, and both of them mean
/// something different when the key is absent than `UserDefaults.bool(forKey:)`
/// would tell you. Getting either polarity wrong is invisible until someone
/// runs the build: one silently stops sending sound, the other silently mutes
/// the user's Mac.
final class AudioPolicyTests: XCTestCase {

    // MARK: - "Stream audio" defaults ON in this fork

    func testStreamAudioIsOnWhenTheKeyHasNeverBeenWritten() {
        // The whole point of the fork policy. `UserDefaults.bool(forKey:)`
        // would answer false here, which is why the resolution is explicit.
        XCTAssertTrue(AudioPolicy.resolveStreamAudio(nil))
    }

    func testStreamAudioHonoursAnExplicitFalse() {
        XCTAssertFalse(AudioPolicy.resolveStreamAudio(false))
    }

    func testStreamAudioHonoursAnExplicitTrue() {
        XCTAssertTrue(AudioPolicy.resolveStreamAudio(true))
    }

    func testStreamAudioTreatsAnUnusableValueAsAbsent() {
        // `defaults write … audioEnabled -string yes` is a plausible typo. It
        // must degrade to the built-in default, not to "off": losing audio
        // because of a malformed value is the more surprising failure.
        XCTAssertTrue(AudioPolicy.resolveStreamAudio("yes"))
        XCTAssertTrue(AudioPolicy.resolveStreamAudio(1 as Int))
    }

    // MARK: - "Mute Mac speakers" defaults OFF

    func testSpeakerMuteIsOffWhenTheKeyHasNeverBeenWritten() {
        XCTAssertFalse(AudioPolicy.resolveMuteSpeakers(nil))
    }

    func testSpeakerMuteHonoursAnExplicitTrue() {
        XCTAssertTrue(AudioPolicy.resolveMuteSpeakers(true))
    }

    func testSpeakerMuteTreatsAnUnusableValueAsOff() {
        // The asymmetry with `streamAudio` above is deliberate: a malformed
        // value must never be able to silence the machine.
        XCTAssertFalse(AudioPolicy.resolveMuteSpeakers("yes"))
    }

    func testTheTwoKeysAreDistinct() {
        XCTAssertNotEqual(AudioPolicy.streamAudioKey, AudioPolicy.muteSpeakersKey)
        XCTAssertNotEqual(AudioPolicy.muteSpeakersKey, AudioPolicy.speakerMuteBreadcrumbKey)
    }

    // MARK: - When the speakers are actually muted

    func testSpeakersAreMutedOnlyWithTheOptionOnAudioOnAndDeliveryActive() {
        XCTAssertTrue(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                                     audioStreaming: true,
                                                     audioDeliveryActive: true))
    }

    func testTheOptionAloneDoesNotMuteTheMac() {
        // Turning the switch on while nothing is connected must not silence
        // the Mac the user is sitting at.
        XCTAssertFalse(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                                      audioStreaming: true,
                                                      audioDeliveryActive: false))
    }

    func testTurningStreamAudioOffAlsoUnmutesTheSpeakers() {
        // Otherwise the Mac stays silent for a feature that is no longer
        // sending anything anywhere.
        XCTAssertFalse(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                                      audioStreaming: false,
                                                      audioDeliveryActive: true))
    }

    func testWithTheOptionOffNothingIsEverMuted() {
        for streaming in [true, false] {
            for deliveryActive in [true, false] {
                XCTAssertFalse(AudioPolicy.shouldMuteSpeakers(optionEnabled: false,
                                                              audioStreaming: streaming,
                                                              audioDeliveryActive: deliveryActive))
            }
        }
    }

    // MARK: - The crash breadcrumb

    func testBreadcrumbRoundTripsThroughADefaultsDictionary() {
        let crumb = SpeakerMuteBreadcrumb(deviceUID: "BuiltInSpeakerDevice", wasMuted: false)
        let restored = SpeakerMuteBreadcrumb(crumb.asDictionary)
        XCTAssertEqual(restored, crumb)
    }

    func testBreadcrumbRemembersThatTheDeviceWasAlreadyMuted() {
        // The one case where recovery must do nothing: we never unmuted it, so
        // "restoring" it would turn on sound the user had deliberately off.
        let crumb = SpeakerMuteBreadcrumb(deviceUID: "X", wasMuted: true)
        XCTAssertEqual(SpeakerMuteBreadcrumb(crumb.asDictionary)?.wasMuted, true)
    }

    func testAbsentOrMalformedBreadcrumbIsNil() {
        XCTAssertNil(SpeakerMuteBreadcrumb(nil))
        XCTAssertNil(SpeakerMuteBreadcrumb("not a dictionary"))
        XCTAssertNil(SpeakerMuteBreadcrumb(["wasMuted": true]))   // no device UID
    }

    func testBreadcrumbWithoutTheFlagDefaultsToNotPreviouslyMuted() {
        // A breadcrumb from an older build, or a half-written one: assume the
        // device was unmuted, i.e. assume there IS something to undo. The
        // failure mode of that guess is a Mac that makes sound again.
        XCTAssertEqual(SpeakerMuteBreadcrumb(["uid": "X"])?.wasMuted, false)
    }
    // MARK: - Which strategy a device earns (round 5)
    //
    // Round 4 could only mute, and the operator's MOTU M4 — a four-output USB
    // interface — has no settable master mute, so the feature reported itself
    // unavailable and the room stayed loud. There is more than one way to make
    // a device quiet.

    func testAMasterMuteIsAlwaysPreferred() {
        let capability = OutputSilenceCapability(masterMuteSettable: true,
                                                 muteSettableChannels: [1, 2],
                                                 masterVolumeSettable: true,
                                                 volumeSettableChannels: [1, 2])
        XCTAssertEqual(SilencePolicy.strategy(for: capability), .masterMute)
    }

    func testPerChannelMuteBeatsAnyVolume() {
        // A mute is exactly reversible and a volume is only as reversible as
        // our memory of the old number, so mute wins wherever it exists.
        let capability = OutputSilenceCapability(masterMuteSettable: false,
                                                 muteSettableChannels: [1, 2, 3, 4],
                                                 masterVolumeSettable: true)
        XCTAssertEqual(SilencePolicy.strategy(for: capability), .channelMute([1, 2, 3, 4]))
    }

    func testAMasterVolumeIsTheThirdChoice() {
        let capability = OutputSilenceCapability(masterVolumeSettable: true,
                                                 volumeSettableChannels: [1, 2])
        XCTAssertEqual(SilencePolicy.strategy(for: capability), .masterVolume)
    }

    func testTheMOTUCase() {
        // Four outputs, no master anything: per-channel volume, which is the
        // only thing left and the thing that actually makes the room quiet.
        let capability = OutputSilenceCapability(volumeSettableChannels: [1, 2, 3, 4])
        XCTAssertEqual(SilencePolicy.strategy(for: capability), .channelVolume([1, 2, 3, 4]))
        XCTAssertTrue(SilencePolicy.strategy(for: capability).isAvailable)
    }

    func testADeviceThatOffersNothingIsStillReportedHonestly() {
        XCTAssertEqual(SilencePolicy.strategy(for: OutputSilenceCapability()), .unavailable)
        XCTAssertFalse(SilenceStrategy.unavailable.isAvailable)
    }

    func testOnlyTheVolumeStrategiesHaveToCopeWithTheUserTurningItUp() {
        XCTAssertFalse(SilenceStrategy.masterMute.isVolumeBased)
        XCTAssertFalse(SilenceStrategy.channelMute([1]).isVolumeBased)
        XCTAssertTrue(SilenceStrategy.masterVolume.isVolumeBased)
        XCTAssertTrue(SilenceStrategy.channelVolume([1]).isVolumeBased)
    }

    func testTheMasterElementIsZeroAndChannelsAreNot() {
        XCTAssertEqual(SilenceStrategy.masterElement, 0)
        XCTAssertEqual(SilenceStrategy.masterMute.elements, [0])
        XCTAssertEqual(SilenceStrategy.masterVolume.elements, [0])
        XCTAssertEqual(SilenceStrategy.channelVolume([1, 2, 3, 4]).elements, [1, 2, 3, 4])
        XCTAssertEqual(SilenceStrategy.unavailable.elements, [])
    }

    func testEveryStrategyDescribesItselfForTheLogAndTheSettingsHint() {
        for strategy in [SilenceStrategy.masterMute, .channelMute([1, 2]),
                         .masterVolume, .channelVolume([1, 2, 3, 4]), .unavailable] {
            XCTAssertFalse(strategy.label.isEmpty)
        }
    }

    // MARK: - Restore bookkeeping

    func testAVolumeRecordRoundTripsThroughADefaultsDictionary() {
        // The one that matters most: a crash while four channels are at zero
        // must be undoable from a plist at the next launch.
        let record = SpeakerMuteBreadcrumb(deviceUID: "MOTU-M4",
                                           strategy: .channelVolume([1, 2, 3, 4]),
                                           volumes: [1: 0.8, 2: 0.8, 3: 0.35, 4: 0.35])
        let restored = SpeakerMuteBreadcrumb(record.asDictionary)
        XCTAssertEqual(restored, record)
        XCTAssertNotNil(try? PropertyListSerialization.data(fromPropertyList: record.asDictionary,
                                                           format: .binary, options: 0),
                        "a breadcrumb that cannot be written to defaults is not a breadcrumb")
    }

    func testAChannelMuteRecordRoundTrips() {
        let record = SpeakerMuteBreadcrumb(deviceUID: "X", strategy: .channelMute([1, 2]),
                                           mutes: [1: false, 2: true])
        XCTAssertEqual(SpeakerMuteBreadcrumb(record.asDictionary), record)
    }

    func testARoundFourBreadcrumbIsStillUnderstood() {
        // Upgrading over a crashed round-4 build must not leave the Mac muted.
        let legacy: [String: Any] = ["uid": "BuiltInSpeakerDevice", "wasMuted": false]
        let restored = SpeakerMuteBreadcrumb(legacy)
        XCTAssertEqual(restored?.deviceUID, "BuiltInSpeakerDevice")
        XCTAssertEqual(restored?.strategy, .masterMute)
        XCTAssertEqual(restored?.wasMuted, false)
        XCTAssertFalse(restored?.hasNothingToRestore ?? true)
    }

    func testADeviceThatWasAlreadySilentIsLeftAlone() {
        // We never changed it, so "restoring" it would turn on sound the user
        // had deliberately off.
        let muted = SpeakerMuteBreadcrumb(deviceUID: "X", strategy: .masterMute, mutes: [0: true])
        XCTAssertTrue(muted.hasNothingToRestore)
        let zeroed = SpeakerMuteBreadcrumb(deviceUID: "X", strategy: .masterVolume, volumes: [0: 0])
        XCTAssertTrue(zeroed.hasNothingToRestore)
    }

    func testAPartiallySilentDeviceIsStillRestored() {
        // Two channels up, two already down: the two we pulled down have to go
        // back, and the record has to say so.
        let record = SpeakerMuteBreadcrumb(deviceUID: "X", strategy: .channelVolume([1, 2, 3, 4]),
                                           volumes: [1: 0.8, 2: 0.8, 3: 0, 4: 0])
        XCTAssertFalse(record.hasNothingToRestore)
    }

    func testAnUnavailableStrategyHasNothingToRestore() {
        let record = SpeakerMuteBreadcrumb(deviceUID: "X", strategy: .unavailable)
        XCTAssertTrue(record.hasNothingToRestore)
    }

    func testTheBreadcrumbKeyIsUnchangedFromRoundFour() {
        // Deliberately the same key: a build that crashed before this change
        // left one behind, and it has to be found.
        XCTAssertEqual(AudioPolicy.speakerMuteBreadcrumbKey, "speakerMuteBreadcrumb")
    }
}

/// Regression for the 2026-09-22 host-audio outage. These use Swift Testing
/// alongside the project's existing XCTest suite; the hostless target supports
/// both and no audio hardware is touched.
struct HostAudioSilencingLifecycleTests {

    @Test("A waiting or reconnecting dialer cannot silence the host")
    func waitingDialerDoesNotOpenAudioDelivery() {
        #expect(AudioDeliveryPolicy.isActive(connectionReady: false,
                                             peerSpeaksTaggedFrames: false) == false)
        #expect(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                               audioStreaming: true,
                                               audioDeliveryActive: false) == false)
    }

    @Test("A socket without the receiver audio handshake cannot silence the host")
    func preHelloConnectionDoesNotOpenAudioDelivery() {
        #expect(AudioDeliveryPolicy.isActive(connectionReady: true,
                                             peerSpeaksTaggedFrames: false) == false)
    }

    @Test("A tagged receiver connection may silence the selected host output")
    func taggedConnectionOpensAudioDelivery() {
        let delivery = AudioDeliveryPolicy.isActive(connectionReady: true,
                                                    peerSpeaksTaggedFrames: true)
        #expect(delivery)
        #expect(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                               audioStreaming: true,
                                               audioDeliveryActive: delivery))
    }

    @Test("Disconnect closes delivery and restores the host output")
    func disconnectClosesAudioDelivery() {
        let delivery = AudioDeliveryPolicy.isActive(connectionReady: false,
                                                    peerSpeaksTaggedFrames: true)
        #expect(delivery == false)
        #expect(AudioPolicy.shouldMuteSpeakers(optionEnabled: true,
                                               audioStreaming: true,
                                               audioDeliveryActive: delivery) == false)
    }
}
