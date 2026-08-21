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
