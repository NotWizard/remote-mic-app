import Foundation

enum XiaomiVoiceRemoteNameMatcher {
    private static let approvedNames: Set<String> = [
        "mi rc",
        "xiaomi bluetooth remote 2",
        "xiaomi bluetooth remote 2 pro",
        "小米蓝牙语音遥控器",
    ]

    static func matches(_ rawName: String?) -> Bool {
        guard let rawName else { return false }
        let normalized = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return approvedNames.contains(normalized)
    }
}

enum BluetoothLifecyclePhase: Equatable {
    case stopped
    case scanning(UInt64)
    case connecting(UInt64)
    case discovering(UInt64)
    case awaitingCapabilities(UInt64)
    case ready(UInt64)
    case disconnecting(UInt64)
    case waitingReconnect(UInt64)

    var generation: UInt64? {
        switch self {
        case .connecting(let value),
             .scanning(let value),
             .discovering(let value),
             .awaitingCapabilities(let value),
             .ready(let value),
             .disconnecting(let value),
             .waitingReconnect(let value):
            return value
        case .stopped:
            return nil
        }
    }

    func acceptsDidConnect(generation: UInt64) -> Bool {
        self == .connecting(generation)
    }

    func acceptsDidFailToConnect(generation: UInt64) -> Bool {
        self == .connecting(generation) || self == .disconnecting(generation)
    }

    func acceptsInitializationCallback(generation: UInt64) -> Bool {
        self == .discovering(generation)
    }

    func acceptsNotificationUpdate(generation: UInt64) -> Bool {
        switch self {
        case .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation):
            return true
        default:
            return false
        }
    }

    func acceptsCapabilities(generation: UInt64) -> Bool {
        self == .awaitingCapabilities(generation)
    }

    func acceptsProtocolData(generation: UInt64) -> Bool {
        self == .ready(generation)
    }

    func acceptsDisconnect(generation: UInt64) -> Bool {
        switch self {
        case .connecting(generation),
             .discovering(generation),
             .awaitingCapabilities(generation),
             .ready(generation),
             .disconnecting(generation):
            return true
        default:
            return false
        }
    }
}

enum ATVVSessionGate {
    static let cancelledOpenSuppressionInterval: TimeInterval = 2

    static func canOpenMicrophone(
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        capabilitiesConfirmed: Bool,
        sampleRate: Double
    ) -> Bool {
        phase.acceptsProtocolData(generation: generation) &&
            capabilitiesConfirmed &&
            ATVVProtocol.supportsAudio(sampleRate: sampleRate)
    }

    static func cancelledOpenDate(
        microphoneOpened: Bool,
        streaming: Bool,
        now: Date = Date()
    ) -> Date? {
        microphoneOpened && !streaming ? now : nil
    }

    static func shouldIgnoreStreamAfterCancelledOpen(
        cancelledAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let cancelledAt else { return false }
        return now < cancelledAt.addingTimeInterval(cancelledOpenSuppressionInterval)
    }
}

/// Decides whether a connection attempt that has not completed yet deserves another
/// `connect()`.
///
/// `CBCentralManager.connect(_:options:)` has no timeout by design: the request stays
/// with the Bluetooth controller and is completed when the peripheral comes back into
/// range, with no polling and no repeated radio cost from the app. An app-side deadline
/// that cancels the request and starts over replaces that free wait with a busy loop —
/// a resident install logged 21675 attempts over 11 days, and while the remote was
/// actually out of range the loop sustained roughly 317 attempts per hour.
enum BluetoothReconnectPolicy {
    /// What the bridge does with a `connect()` that is still outstanding once
    /// `pendingConnectDeadline` has elapsed.
    enum PendingConnectPolicy: Equatable {
        /// Cancel the outstanding request and issue a new `connect()` after the delay.
        /// Every elapsed deadline costs one more attempt.
        case restartAttempt(retryDelay: TimeInterval)
        /// Leave the request with the Bluetooth controller. No further `connect()` is
        /// issued; the attempt completes on its own when the remote returns.
        case keepOutstandingRequest
    }

    /// Seconds after which the bridge stops telling the user it is still connecting.
    /// Reaching it only changes the displayed state; whether the request survives is
    /// `pendingConnect`.
    static let pendingConnectDeadline: TimeInterval = 8

    /// Delay before a new attempt after a genuine failure, a disconnect, or a failed
    /// post-connect handshake — cases where the controller has already given up.
    static let failureRetryDelay: TimeInterval = 3

    /// The behaviour the bridge applies.
    static let pendingConnect: PendingConnectPolicy = .keepOutstandingRequest

    /// Delay before the next `connect()` when `pendingConnectDeadline` elapses with the
    /// request still outstanding, or `nil` when that request must be left alone.
    static func retryDelayAfterPendingConnectDeadline(
        policy: PendingConnectPolicy = pendingConnect
    ) -> TimeInterval? {
        switch policy {
        case .restartAttempt(let retryDelay):
            return retryDelay
        case .keepOutstandingRequest:
            return nil
        }
    }
}

/// Every decision `XiaomiBluetoothBridge` makes about an ATVV voice session, with no
/// CoreBluetooth dependency.
///
/// `CBCentralManager` and `CBPeripheral` can neither be constructed nor driven from a
/// unit test, which is why the bridge had no behaviour coverage at all even though every
/// voice session flows through it. None of the protocol work actually needs the radio:
/// capability negotiation, the session state machine, frame reassembly and decode are
/// decided from bytes plus the current lifecycle phase. They live here so tests can
/// replay a real event sequence, and the bridge is the adapter that owns the radio and
/// applies the returned effects to its delegate.
///
/// Outputs are returned rather than performed so that a test observes the same ordered
/// sequence the delegate does. The one dependency that cannot be a return value is the
/// characteristic write: whether it reached the remote feeds straight back into session
/// state (`MIC_OPEN` only counts as opened once the write went out, and `MIC_CLOSE` logs
/// the outcome), so it is passed in as a non-escaping closure.
final class ATVVVoiceSessionCore {
    /// Assumed capabilities before the remote answers `GET_CAPABILITIES`: ATVV v1.0,
    /// 16 kHz IMA-ADPCM, 120-byte frames.
    static let defaultCapabilities = ATVVCapabilities(
        version: 0x0100,
        codecs: 0x02,
        interaction: 0x03,
        frameSize: 120,
        selectedCodec: 0x02,
        sampleRate: 16_000
    )

    /// How long after a `STREAM_STOP` a stray audio frame is refused instead of being
    /// allowed to open a new session. Trailing frames of the session that just ended
    /// arrive after the stop and must not restart it.
    static let postStopAudioSuppressionInterval: TimeInterval = 0.3

    /// What the bridge must do, in order, as a result of one event.
    enum Effect: Equatable {
        /// A voice session began. The bridge notifies its delegate, then logs — that
        /// order is what the runtime log already shows, because the delegate logs too.
        case voiceDidStart(sessionID: UInt8, implicitFromAudio: Bool)
        /// A voice session ended through the protocol: `STREAM_STOP`, or a codec the Mac
        /// cannot use. Delegate first, then the stream log line.
        case voiceDidStop(sessionID: UInt8)
        /// A voice session was torn down by a reset — a disconnect, `stop()`, or a new
        /// peripheral. The delegate hears the same "voice stopped", but no stream log
        /// line is written: the reset path never wrote one.
        case voiceDidAbort
        /// Decoded 16 kHz PCM for one reassembled frame, in arrival order.
        case decoded([Int16])
        /// 16 kHz capabilities confirmed. The bridge cancels its initialization timeout
        /// and goes ready.
        case capabilitiesAccepted
        /// Initialization failed, or the remote picked a codec the Mac cannot use.
        case failed(LocalizedMessage)
        /// Always last, and always after any `failed` and `voiceDidStop`, so the session
        /// teardown is visible before the connection is torn down.
        case scheduleReconnect
    }

    private(set) var capabilities = ATVVVoiceSessionCore.defaultCapabilities
    private(set) var capabilitiesConfirmed = false
    private(set) var isStreaming = false
    private(set) var isMicrophoneOpen = false
    private(set) var sessionID: UInt8 = 0
    private var cancelledMicrophoneOpenAt: Date?
    private var lastStopAt: Date?
    private var decoder = IMAADPCMDecoder()
    private var accumulator = FrameAccumulator()
    private var pendingSync: (predictor: Int, stepIndex: Int)?

    /// Drops partially reassembled frames and decoder state without ending the session.
    ///
    /// This is the narrow reset the initialization-failure paths need: a handshake that
    /// failed must not leave half a frame behind, but it must not fabricate a
    /// "voice stopped" for a session that was never streaming either.
    func resetDecodeState() {
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
    }

    /// Clears everything negotiated with one peripheral so the next connection starts
    /// from the defaults instead of inheriting a codec.
    func resetForNewConnection() -> [Effect] {
        capabilitiesConfirmed = false
        capabilities = Self.defaultCapabilities
        return reset()
    }

    /// Ends any session in flight and clears per-session state. `lastStopAt` is
    /// deliberately kept: it guards against a trailing frame reopening the session, and a
    /// reset is not evidence that those frames have stopped arriving.
    func reset() -> [Effect] {
        var effects: [Effect] = []
        if isStreaming {
            isStreaming = false
            effects.append(.voiceDidAbort)
        }
        isMicrophoneOpen = false
        cancelledMicrophoneOpenAt = nil
        sessionID = 0
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        return effects
    }

    @discardableResult
    func requestMicrophoneOpen(
        phase: BluetoothLifecyclePhase,
        write: (Data) -> Bool
    ) -> Bool {
        guard let generation = phase.generation,
              ATVVSessionGate.canOpenMicrophone(
                  phase: phase,
                  generation: generation,
                  capabilitiesConfirmed: capabilitiesConfirmed,
                  sampleRate: capabilities.sampleRate
              ),
              !isMicrophoneOpen,
              !isStreaming
        else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_rejected")
            return false
        }
        guard write(ATVVProtocol.microphoneOpen(
            version: capabilities.version,
            codec: capabilities.selectedCodec
        )) else {
            AppLogger.shared.write("ATVV MIC_OPEN host_request_write_failed")
            return false
        }
        cancelledMicrophoneOpenAt = nil
        isMicrophoneOpen = true
        AppLogger.shared.write("ATVV MIC_OPEN host_request")
        return true
    }

    @discardableResult
    func requestMicrophoneExtend(write: (Data) -> Bool) -> Bool {
        guard isMicrophoneOpen,
              isStreaming,
              let command = ATVVProtocol.microphoneExtend(
                  version: capabilities.version,
                  sessionID: sessionID
              ),
              write(command)
        else {
            AppLogger.shared.write("ATVV MIC_EXTEND rejected session=\(sessionID)")
            return false
        }
        AppLogger.shared.write("ATVV MIC_EXTEND request session=\(sessionID)")
        return true
    }

    @discardableResult
    func requestMicrophoneClose(
        now: Date = Date(),
        write: (Data) -> Bool
    ) -> Bool {
        guard isMicrophoneOpen || isStreaming else { return true }
        let cancelledOpenAt = ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: isMicrophoneOpen,
            streaming: isStreaming,
            now: now
        )
        let didWrite = write(ATVVProtocol.microphoneClose(
            version: capabilities.version,
            sessionID: sessionID
        ))
        isMicrophoneOpen = false
        cancelledMicrophoneOpenAt = cancelledOpenAt
        AppLogger.shared.write(
            "ATVV MIC_CLOSE request session=\(sessionID) written=\(didWrite)"
        )
        return didWrite
    }

    /// Handles one control-characteristic notification.
    ///
    /// `callbackGeneration` is the connection generation the notification was delivered
    /// for. CoreBluetooth reuses the same `CBPeripheral` across reconnects, so a callback
    /// belonging to a previous connection can still arrive after a new one has started;
    /// it must never touch the current session, and is dropped before anything else.
    func handleControlValue(
        _ data: Data,
        phase: BluetoothLifecyclePhase,
        callbackGeneration: UInt64,
        now: Date = Date(),
        write: (Data) -> Bool
    ) -> [Effect] {
        guard let generation = phase.generation,
              generation == callbackGeneration,
              phase.acceptsCapabilities(generation: generation) ||
                phase.acceptsProtocolData(generation: generation)
        else { return [] }
        let bytes = Array(data)
        guard let opcode = bytes.first else { return [] }

        switch opcode {
        case 0x0B:
            return handleCapabilities(
                data,
                phase: phase,
                generation: generation,
                now: now,
                write: write
            )
        case 0x08:
            guard requestMicrophoneOpen(phase: phase, write: write) else {
                AppLogger.shared.write("ATVV MIC_OPEN remote_request_ignored")
                return []
            }
            AppLogger.shared.write("ATVV MIC_OPEN remote_request")
            return []
        case 0x04:
            return handleStreamStart(
                bytes,
                phase: phase,
                generation: generation,
                now: now,
                write: write
            )
        case 0x00:
            guard phase.acceptsProtocolData(generation: generation) else { return [] }
            return stopStreaming(now: now)
        case 0x0A:
            guard phase.acceptsProtocolData(generation: generation), bytes.count >= 7 else {
                return []
            }
            let predictorBits = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
            pendingSync = (Int(Int16(bitPattern: predictorBits)), Int(bytes[6]))
            accumulator.reset()
            return []
        default:
            return []
        }
    }

    /// Handles one audio-characteristic notification: reassembles frames and decodes
    /// them. A stream that starts with audio and no preceding `STREAM_START` is accepted,
    /// which is the RC003 baseline path.
    func handleAudioValue(
        _ data: Data,
        phase: BluetoothLifecyclePhase,
        callbackGeneration: UInt64,
        gainDB: Double,
        now: Date = Date()
    ) -> [Effect] {
        guard let generation = phase.generation,
              generation == callbackGeneration,
              phase.acceptsProtocolData(generation: generation)
        else { return [] }
        guard ATVVSessionGate.canOpenMicrophone(
            phase: phase,
            generation: generation,
            capabilitiesConfirmed: capabilitiesConfirmed,
            sampleRate: capabilities.sampleRate
        ) else {
            AppLogger.shared.write("ATVV AUDIO ignored_not_ready")
            return []
        }
        if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledMicrophoneOpenAt,
            now: now
        ) {
            AppLogger.shared.write("ATVV AUDIO ignored_cancelled_open")
            return []
        }
        cancelledMicrophoneOpenAt = nil

        var effects: [Effect] = []
        if !isStreaming {
            if let lastStopAt,
               now.timeIntervalSince(lastStopAt) < Self.postStopAudioSuppressionInterval {
                return []
            }
            effects += startStreaming(implicitFromAudio: true)
        }

        for frame in accumulator.append(data, frameSize: capabilities.frameSize) {
            if let pendingSync {
                decoder.reset(
                    predictor: pendingSync.predictor,
                    stepIndex: pendingSync.stepIndex
                )
                self.pendingSync = nil
            }
            effects.append(.decoded(
                PCMPostprocessor.process(decoder.decode(frame), gainDB: gainDB)
            ))
        }
        return effects
    }

    private func handleCapabilities(
        _ data: Data,
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        now: Date,
        write: (Data) -> Bool
    ) -> [Effect] {
        guard phase.acceptsCapabilities(generation: generation) else {
            AppLogger.shared.write("ATVV CAPS ignored_stale_phase")
            return []
        }
        guard let parsed = ATVVCapabilities.parse(data) else {
            return failInitialization(
                LocalizedMessage("connection.error.invalid_voice_response")
            )
        }
        capabilities = parsed
        AppLogger.shared.write(
            "ATVV CAPS version=\(parsed.version) codec=\(parsed.selectedCodec) frame=\(parsed.frameSize)"
        )
        guard ATVVProtocol.supportsAudio(sampleRate: parsed.sampleRate) else {
            return rejectUnsupportedAudio(
                LocalizedMessage("connection.error.unsupported_16khz_codec"),
                now: now,
                write: write
            )
        }
        capabilitiesConfirmed = true
        return [.capabilitiesAccepted]
    }

    private func handleStreamStart(
        _ bytes: [UInt8],
        phase: BluetoothLifecyclePhase,
        generation: UInt64,
        now: Date,
        write: (Data) -> Bool
    ) -> [Effect] {
        guard ATVVSessionGate.canOpenMicrophone(
            phase: phase,
            generation: generation,
            capabilitiesConfirmed: capabilitiesConfirmed,
            sampleRate: capabilities.sampleRate
        ) else {
            AppLogger.shared.write("ATVV STREAM_START ignored_not_ready")
            return []
        }
        if bytes.count >= 3 {
            let codec = bytes[2]
            capabilities = ATVVCapabilities(
                version: capabilities.version,
                codecs: capabilities.codecs,
                interaction: bytes[1],
                frameSize: capabilities.frameSize,
                selectedCodec: codec,
                sampleRate: codec == 0x02 ? 16_000 : 8_000
            )
        }
        guard ATVVProtocol.supportsAudio(sampleRate: capabilities.sampleRate) else {
            return rejectUnsupportedAudio(
                LocalizedMessage("connection.error.unsupported_8khz_codec"),
                now: now,
                write: write
            )
        }
        let receivedSessionID = bytes.count >= 4 ? bytes[3] : 0
        if ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledMicrophoneOpenAt,
            now: now
        ) {
            _ = write(ATVVProtocol.microphoneClose(
                version: capabilities.version,
                sessionID: receivedSessionID
            ))
            AppLogger.shared.write(
                "ATVV STREAM_START ignored_cancelled session=\(receivedSessionID)"
            )
            return []
        }
        cancelledMicrophoneOpenAt = nil
        sessionID = receivedSessionID
        return startStreaming(implicitFromAudio: false)
    }

    private func startStreaming(implicitFromAudio: Bool) -> [Effect] {
        accumulator.reset()
        pendingSync = nil
        decoder.reset()
        lastStopAt = nil
        guard !isStreaming else { return [] }
        isStreaming = true
        return [.voiceDidStart(sessionID: sessionID, implicitFromAudio: implicitFromAudio)]
    }

    private func stopStreaming(now: Date) -> [Effect] {
        guard isStreaming else { return [] }
        isStreaming = false
        isMicrophoneOpen = false
        accumulator.reset()
        pendingSync = nil
        lastStopAt = now
        return [.voiceDidStop(sessionID: sessionID)]
    }

    private func failInitialization(_ message: LocalizedMessage) -> [Effect] {
        resetDecodeState()
        return [.failed(message), .scheduleReconnect]
    }

    private func rejectUnsupportedAudio(
        _ message: LocalizedMessage,
        now: Date,
        write: (Data) -> Bool
    ) -> [Effect] {
        var effects: [Effect] = [.failed(message)]
        _ = requestMicrophoneClose(now: now, write: write)
        if isStreaming {
            effects += stopStreaming(now: now)
        } else {
            resetDecodeState()
        }
        effects.append(.scheduleReconnect)
        return effects
    }
}
