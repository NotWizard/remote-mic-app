import Foundation
import Testing
@testable import RemoteMic

/// Behaviour coverage for the ATVV voice session that every `XiaomiBluetoothBridge`
/// session flows through.
///
/// `CBCentralManager` and `CBPeripheral` can neither be constructed nor driven from a
/// unit test, so the bridge itself had no coverage at all. `ATVVVoiceSessionCore` is the
/// production handling extracted out of it: these tests replay real protocol event
/// sequences against the same code the shipping app runs.
///
/// **These are replayed events, not real CoreBluetooth callbacks.** Nothing here proves a
/// real remote produces this byte sequence, or that CoreBluetooth delivers notifications
/// in this order. See `Bugs/2026-08-21-bluetooth-bridge-had-no-behaviour-coverage.md`.
@Suite("Xiaomi bluetooth bridge voice session")
struct XiaomiBluetoothBridgeSessionTests {
    // MARK: - Real remote byte sequences

    /// The `GET_CAPABILITIES` answer of a 16 kHz IMA-ADPCM remote: ATVV v1.0, codec mask
    /// 0x02, 120-byte frames. Same bytes as `ATVVProtocolTests`.
    static let capabilities16k = Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0x78])
    /// Same, but advertising only the 8 kHz codec the Mac side cannot use.
    static let capabilities8k = Data([0x0B, 0x01, 0x00, 0x01, 0x03, 0x00, 0x78])
    /// `STREAM_START`, interaction 0x03, codec 0x02 (16 kHz), session 7.
    static let streamStart = Data([0x04, 0x03, 0x02, 0x07])
    /// `STREAM_START` that switches to the unusable 8 kHz codec.
    static let streamStart8k = Data([0x04, 0x03, 0x01, 0x07])
    static let streamStop = Data([0x00])

    static let frameSize = 120

    /// Deterministic ADPCM payload. Every nibble value occurs, so a decode regression
    /// changes the samples rather than only their count.
    static func audioPayload(frames: Int) -> Data {
        Data((0..<(frames * frameSize)).map { UInt8(($0 * 7 + 3) & 0xFF) })
    }

    /// What the samples must be: one continuous decoder across the frames in order, each
    /// frame post-processed on its own, exactly as the core does it.
    static func expectedBatches(for payload: Data, gainDB: Double) -> [[Int16]] {
        let reference = IMAADPCMDecoder()
        return stride(from: 0, to: payload.count, by: frameSize).map { offset in
            let frame = payload.subdata(in: offset..<(offset + frameSize))
            return PCMPostprocessor.process(reference.decode(frame), gainDB: gainDB)
        }
    }

    // MARK: - Replay harness

    /// Drives the production core and records what the bridge would have done.
    ///
    /// `apply` mirrors `XiaomiBluetoothBridge.apply` / `confirmCapabilities` for the one
    /// effect that moves the lifecycle phase, so a replayed handshake advances the phase
    /// the same way a real connection does.
    private final class Replay {
        let core = ATVVVoiceSessionCore()
        private(set) var effects: [ATVVVoiceSessionCore.Effect] = []
        private(set) var writes: [Data] = []
        private(set) var decoded: [[Int16]] = []
        private(set) var voiceStarts = 0
        private(set) var voiceStops = 0
        var writeSucceeds = true
        var gainDB: Double = 0
        var generation: UInt64
        var phase: BluetoothLifecyclePhase
        var now: Date

        init(generation: UInt64 = 1) {
            self.generation = generation
            phase = .discovering(generation)
            now = Date(timeIntervalSince1970: 1_000_000)
        }

        /// Every sample delivered so far, flattened.
        var allSamples: [Int16] { decoded.flatMap { $0 } }

        /// True when a host-initiated `MIC_OPEN` (opcode 0x0C) was written.
        var didWriteMicrophoneOpen: Bool { writes.contains { $0.first == 0x0C } }
        /// True when a `MIC_CLOSE` (opcode 0x0D) was written.
        var didWriteMicrophoneClose: Bool { writes.contains { $0.first == 0x0D } }

        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

        /// Records a write and reports the configured outcome. Used by tests that call the
        /// core's request methods directly instead of replaying a notification.
        func recordedWrite(_ data: Data) -> Bool {
            write(data)
        }

        private func write(_ data: Data) -> Bool {
            writes.append(data)
            return writeSucceeds
        }

        @discardableResult
        private func apply(_ produced: [ATVVVoiceSessionCore.Effect])
            -> [ATVVVoiceSessionCore.Effect] {
            effects += produced
            for effect in produced {
                switch effect {
                case .voiceDidStart:
                    voiceStarts += 1
                case .voiceDidStop, .voiceDidAbort:
                    voiceStops += 1
                case .decoded(let samples):
                    decoded.append(samples)
                case .capabilitiesAccepted:
                    phase = .ready(generation)
                case .failed, .scheduleReconnect:
                    break
                }
            }
            return produced
        }

        @discardableResult
        func control(
            _ data: Data,
            callbackGeneration: UInt64? = nil
        ) -> [ATVVVoiceSessionCore.Effect] {
            apply(core.handleControlValue(
                data,
                phase: phase,
                callbackGeneration: callbackGeneration ?? generation,
                now: now,
                write: { self.write($0) }
            ))
        }

        @discardableResult
        func audio(
            _ data: Data,
            callbackGeneration: UInt64? = nil
        ) -> [ATVVVoiceSessionCore.Effect] {
            apply(core.handleAudioValue(
                data,
                phase: phase,
                callbackGeneration: callbackGeneration ?? generation,
                gainDB: gainDB,
                now: now
            ))
        }

        @discardableResult
        func resetForNewConnection() -> [ATVVVoiceSessionCore.Effect] {
            apply(core.resetForNewConnection())
        }

        /// Completes the `GET_CAPABILITIES` handshake so the session is ready, the way the
        /// bridge does after it subscribes to both characteristics.
        func negotiateCapabilities(_ data: Data = capabilities16k) {
            phase = .awaitingCapabilities(generation)
            control(data)
        }

        /// Moves to the next connection generation, as a reconnect does.
        func reconnect() {
            resetForNewConnection()
            generation += 1
            phase = .discovering(generation)
        }
    }

    // MARK: - Priority 1: the RC003 baseline path

    /// `STREAM_START → AUDIO → STREAM_STOP` with **no** host-initiated `MIC_OPEN` must
    /// produce exactly one voice session and every decoded sample.
    ///
    /// `AGENTS.md` names this as a release gate: a remote that opens its own stream is the
    /// ordinary case, and the Mac must not require `MIC_OPEN` first. Audio is delivered in
    /// 100-byte notifications against a 120-byte frame size, so nothing lines up with a
    /// frame boundary and reassembly is genuinely exercised.
    @Test func remoteInitiatedStreamProducesOneSessionAndCompleteAudioWithoutMicOpen() {
        let replay = Replay()
        replay.negotiateCapabilities()
        #expect(replay.core.capabilitiesConfirmed)
        #expect(replay.core.capabilities.frameSize == Self.frameSize)

        replay.control(Self.streamStart)
        #expect(replay.core.isStreaming)
        #expect(replay.core.sessionID == 7)
        #expect(replay.effects.contains(
            .voiceDidStart(sessionID: 7, implicitFromAudio: false)
        ))

        let payload = Self.audioPayload(frames: 3)
        for chunk in [0..<100, 100..<200, 200..<300, 300..<360] {
            replay.audio(payload.subdata(in: chunk))
        }

        replay.control(Self.streamStop)

        // Exactly one session, opened and closed once.
        #expect(replay.voiceStarts == 1)
        #expect(replay.voiceStops == 1)
        #expect(!replay.core.isStreaming)
        #expect(replay.effects.last == .voiceDidStop(sessionID: 7))

        // The complete audio, in order, byte-for-byte what a reference decode produces.
        let expected = Self.expectedBatches(for: payload, gainDB: replay.gainDB)
        #expect(replay.decoded.count == 3)
        #expect(replay.decoded == expected)
        #expect(replay.allSamples.count == 3 * Self.frameSize * 2)

        // The whole session ran without the host ever opening the microphone.
        #expect(!replay.didWriteMicrophoneOpen)
        #expect(!replay.core.isMicrophoneOpen)
    }

    /// The same baseline, but the remote sends audio without any `STREAM_START` at all —
    /// the implicit path RC003 actually uses. Still exactly one session.
    @Test func audioAloneOpensExactlyOneSessionAndNeverASecondOne() {
        let replay = Replay()
        replay.negotiateCapabilities()

        let payload = Self.audioPayload(frames: 2)
        replay.audio(payload.subdata(in: 0..<120))
        replay.audio(payload.subdata(in: 120..<240))

        #expect(replay.voiceStarts == 1)
        #expect(replay.effects.contains(
            .voiceDidStart(sessionID: 0, implicitFromAudio: true)
        ))
        #expect(!replay.effects.contains(
            .voiceDidStart(sessionID: 0, implicitFromAudio: false)
        ))
        #expect(replay.decoded == Self.expectedBatches(for: payload, gainDB: replay.gainDB))
        #expect(!replay.didWriteMicrophoneOpen)

        replay.control(Self.streamStop)
        #expect(replay.voiceStarts == 1)
        #expect(replay.voiceStops == 1)
    }

    /// Trailing frames of the session that just ended must not open a new one, but a
    /// genuinely new utterance after the suppression window must.
    @Test func trailingAudioAfterStopDoesNotOpenASecondSession() {
        let replay = Replay()
        replay.negotiateCapabilities()
        replay.control(Self.streamStart)
        replay.control(Self.streamStop)
        #expect(replay.voiceStarts == 1)

        replay.advance(ATVVVoiceSessionCore.postStopAudioSuppressionInterval / 2)
        replay.audio(Self.audioPayload(frames: 1))
        #expect(replay.voiceStarts == 1)
        #expect(replay.decoded.isEmpty)

        replay.advance(ATVVVoiceSessionCore.postStopAudioSuppressionInterval)
        replay.audio(Self.audioPayload(frames: 1))
        #expect(replay.voiceStarts == 2)
        #expect(replay.decoded.count == 1)
    }

    // MARK: - Priority 2: a disconnect in the middle of a stream

    /// A disconnect mid-stream must end the voice session, not leave it streaming.
    ///
    /// The bridge reaches this through `handleDisconnect → finishAttempt →
    /// resetPeripheral`, which is `resetForNewConnection()` on the session.
    @Test func disconnectMidStreamEndsTheSessionAndStopsAcceptingAudio() {
        let replay = Replay()
        replay.negotiateCapabilities()
        replay.control(Self.streamStart)

        let payload = Self.audioPayload(frames: 2)
        replay.audio(payload.subdata(in: 0..<120))
        #expect(replay.core.isStreaming)
        #expect(replay.decoded.count == 1)

        // The remote drops mid-utterance.
        let disconnect = replay.resetForNewConnection()

        #expect(disconnect == [.voiceDidAbort])
        #expect(!replay.core.isStreaming)
        #expect(!replay.core.isMicrophoneOpen)
        #expect(replay.core.sessionID == 0)
        #expect(replay.voiceStops == 1)
        // Nothing negotiated survives, so the next connection cannot inherit a codec.
        #expect(!replay.core.capabilitiesConfirmed)
        #expect(replay.core.capabilities == ATVVVoiceSessionCore.defaultCapabilities)

        // Frames still in flight when the link dropped must not be decoded or restart
        // the session: the phase still says ready, but nothing is confirmed any more.
        replay.audio(payload.subdata(in: 120..<240))
        #expect(replay.decoded.count == 1)
        #expect(!replay.core.isStreaming)
        #expect(replay.voiceStarts == 1)

        // The session already ended; tearing down again must not fake a second stop.
        #expect(replay.resetForNewConnection() == [])
        #expect(replay.voiceStops == 1)
    }

    /// A disconnect while no session is running must not fabricate a "voice stopped".
    @Test func disconnectWithNoStreamRunningReportsNothing() {
        let replay = Replay()
        replay.negotiateCapabilities()

        #expect(replay.resetForNewConnection() == [])
        #expect(replay.voiceStops == 0)
    }

    // MARK: - Priority 3: a stale connection generation

    /// CoreBluetooth reuses the same `CBPeripheral` across reconnects, so a notification
    /// belonging to the previous connection can arrive after a new one is ready. It must
    /// not be accepted by the current session.
    ///
    /// The positive control at the end is the point: a core that rejected everything would
    /// satisfy the first half of this test.
    @Test func staleGenerationCallbacksAreRejectedWhileTheCurrentOneStillWorks() {
        let replay = Replay()
        replay.negotiateCapabilities()
        replay.control(Self.streamStart)
        #expect(replay.core.isStreaming)

        let stalePayload = Self.audioPayload(frames: 1)
        replay.reconnect()
        replay.negotiateCapabilities()
        #expect(replay.generation == 2)
        #expect(replay.phase == .ready(2))

        let decodedBefore = replay.decoded.count
        let startsBefore = replay.voiceStarts

        // Generation 1's late callbacks arrive while generation 2 is ready.
        #expect(replay.control(Self.streamStart, callbackGeneration: 1) == [])
        #expect(replay.audio(stalePayload, callbackGeneration: 1) == [])
        #expect(replay.control(Self.streamStop, callbackGeneration: 1) == [])
        #expect(!replay.core.isStreaming)
        #expect(replay.decoded.count == decodedBefore)
        #expect(replay.voiceStarts == startsBefore)

        // Positive control: generation 2's own events are still handled.
        replay.control(Self.streamStart)
        #expect(replay.core.isStreaming)
        #expect(replay.voiceStarts == startsBefore + 1)
        replay.audio(stalePayload)
        #expect(replay.decoded.count == decodedBefore + 1)
    }

    /// A capabilities answer that arrives after the phase has moved on must not be
    /// applied, and must not confirm a session.
    @Test func capabilitiesArrivingInTheWrongPhaseAreIgnored() {
        let replay = Replay()
        replay.phase = .ready(replay.generation)

        #expect(replay.control(Self.capabilities16k) == [])
        #expect(!replay.core.capabilitiesConfirmed)

        // Audio cannot flow while capabilities were never confirmed.
        #expect(replay.audio(Self.audioPayload(frames: 1)) == [])
        #expect(!replay.core.isStreaming)
    }

    // MARK: - Codec rejection and host-initiated open

    /// A remote that only offers 8 kHz must be refused, and the refusal must schedule a
    /// fresh attempt rather than sitting on a codec the Mac cannot decode.
    @Test func an8kHzOnlyRemoteIsRefusedAndRetried() {
        let replay = Replay()
        replay.negotiateCapabilities(Self.capabilities8k)

        #expect(replay.effects == [
            .failed(LocalizedMessage("connection.error.unsupported_16khz_codec")),
            .scheduleReconnect,
        ])
        #expect(!replay.core.capabilitiesConfirmed)
        #expect(!replay.core.isStreaming)
    }

    /// A remote that negotiates 16 kHz but then starts an 8 kHz stream must be refused at
    /// `STREAM_START`, with no session and no audio.
    @Test func aStreamThatSwitchesTo8kHzIsRefusedWithoutStartingASession() {
        let replay = Replay()
        replay.negotiateCapabilities()

        let effects = replay.control(Self.streamStart8k)

        #expect(effects.first == .failed(
            LocalizedMessage("connection.error.unsupported_8khz_codec")
        ))
        #expect(effects.last == .scheduleReconnect)
        #expect(replay.voiceStarts == 0)
        #expect(!replay.core.isStreaming)
        #expect(replay.decoded.isEmpty)
    }

    /// `MIC_OPEN` must only count as open once the write actually went out. Setting the
    /// flag before checking the write would strand the session with a microphone the
    /// remote never heard about.
    @Test func aFailedMicrophoneOpenWriteLeavesTheMicrophoneClosed() {
        let replay = Replay()
        replay.negotiateCapabilities()
        replay.writeSucceeds = false

        #expect(!replay.core.requestMicrophoneOpen(
            phase: replay.phase,
            write: { replay.recordedWrite($0) }
        ))
        #expect(!replay.core.isMicrophoneOpen)
        #expect(replay.didWriteMicrophoneOpen)

        // The same request succeeds once the write reaches the remote.
        replay.writeSucceeds = true
        #expect(replay.core.requestMicrophoneOpen(
            phase: replay.phase,
            write: { replay.recordedWrite($0) }
        ))
        #expect(replay.core.isMicrophoneOpen)
    }

    /// A host `MIC_OPEN` that the user cancels before the stream starts must suppress the
    /// stream the remote then sends, and must tell the remote to close it.
    @Test func aCancelledHostOpenSuppressesTheStreamItWouldHaveStarted() {
        let replay = Replay()
        replay.negotiateCapabilities()

        #expect(replay.core.requestMicrophoneOpen(
            phase: replay.phase,
            write: { replay.recordedWrite($0) }
        ))
        #expect(replay.core.requestMicrophoneClose(
            now: replay.now,
            write: { replay.recordedWrite($0) }
        ))

        replay.control(Self.streamStart)

        #expect(replay.voiceStarts == 0)
        #expect(!replay.core.isStreaming)
        #expect(replay.didWriteMicrophoneClose)

        // Once the suppression window passes, a new stream is accepted again.
        replay.advance(ATVVSessionGate.cancelledOpenSuppressionInterval)
        replay.control(Self.streamStart)
        #expect(replay.voiceStarts == 1)
    }
}
