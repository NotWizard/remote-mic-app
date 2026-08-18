import Foundation

// ponytail: fork-local stub for the private GetSayAll/sayall-mac-remote component.
// The iPhone, Apple Watch and web transports it implements talk to counterparties
// that live in private repositories (iOS app, watch app, relay server), so they
// cannot be reimplemented here — there is nothing to connect to. These no-op
// servers keep the fork compiling and let every RC003 path build and run
// untouched. Replace this package with the real dependency in Package.swift if
// read access is ever granted.

public struct RemoteButtonIdentifier: Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct RemoteButtonPhaseIdentifier: Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum RemoteVoiceStartResult: Sendable, Equatable {
    case started
    case busy
    case unavailable
}

public enum WebRemoteSessionState: Sendable, Equatable {
    case disabled
    case unavailable
    case connecting
    case waitingForPhone
    case awaitingApproval
    case connected
    case failed

    public var isEnabled: Bool {
        switch self {
        case .connecting, .waitingForPhone, .awaitingApproval, .connected:
            return true
        case .disabled, .unavailable, .failed:
            return false
        }
    }
}

public enum WebRemoteConfiguration {
    /// No relay endpoint ships with the fork, so web sessions report as unavailable.
    public static func relayURL() -> URL? { nil }
}

public struct WatchBluetoothAudioSignalMetrics: Sendable {
    public private(set) var sampleCount = 0
    public private(set) var nonZeroSampleCount = 0
    public private(set) var peak: Float = 0
    public private(set) var rms: Float = 0

    private var squareSum: Double = 0

    public init() {}

    public mutating func append(_ samples: [Int16]) {
        for sample in samples {
            let normalized = Float(sample) / Float(Int16.max)
            let magnitude = abs(normalized)
            if sample != 0 { nonZeroSampleCount += 1 }
            if magnitude > peak { peak = magnitude }
            squareSum += Double(normalized) * Double(normalized)
        }
        sampleCount += samples.count
        rms = sampleCount > 0 ? Float((squareSum / Double(sampleCount)).squareRoot()) : 0
    }
}

/// Shared no-op transport surface. Callbacks are stored but never invoked.
open class NearbyRemoteTransport {
    public var isIdentityTrusted: ((String) -> Bool)?
    public var onConnectionStateChange: ((Bool) -> Void)?
    public var onApprovalCancelled: (() -> Void)?
    public var onApprovalRequested: ((String, String, String, @escaping (Bool) -> Void) -> Void)?
    public var onCommand: ((RemoteButtonIdentifier, @escaping (Bool) -> Void) -> Void)?
    public var onButtonEvent: (
        (RemoteButtonIdentifier, RemoteButtonPhaseIdentifier, @escaping (Bool) -> Void) -> Void
    )?
    public var onButtonEventsReset: (() -> Void)?
    public var onVoiceStartResult: ((@escaping (RemoteVoiceStartResult) -> Void) -> Void)?
    public var onVoiceStop: (() -> Void)?
    public var onAudio: (([Int16]) -> Void)?

    private let logger: (String) -> Void
    private let label: String

    public init(label: String, logger: @escaping (String) -> Void = { _ in }) {
        self.label = label
        self.logger = logger
    }

    open func start() {
        logger("\(label) unavailable_in_fork_build")
    }

    open func stop() {}

    open func updateButtonTitles(_ titles: [String: String]) {}
}

public final class PhoneRemoteServer: NearbyRemoteTransport {
    public init(logger: @escaping (String) -> Void = { _ in }) {
        super.init(label: "PHONE REMOTE", logger: logger)
    }
}

public final class WatchBluetoothRemoteServer: NearbyRemoteTransport {
    public init(logger: @escaping (String) -> Void = { _ in }) {
        super.init(label: "WATCH REMOTE", logger: logger)
    }
}

public final class WebRemoteRelayClient {
    public var onStateChange: ((WebRemoteSessionState) -> Void)?
    public var onApprovalCancelled: (() -> Void)?
    public var onApprovalRequested: ((String, String, @escaping (Bool) -> Void) -> Void)?
    public var onCommand: ((RemoteButtonIdentifier, @escaping (Bool) -> Void) -> Void)?
    public var onButtonEvent: (
        (RemoteButtonIdentifier, RemoteButtonPhaseIdentifier, @escaping (Bool) -> Void) -> Void
    )?
    public var onButtonEventsReset: (() -> Void)?
    public var onVoiceStart: ((@escaping (Bool) -> Void) -> Void)?
    public var onVoiceStop: (() -> Void)?
    public var onAudio: (([Int16]) -> Void)?

    public init() {}

    public func start(
        relayURL: URL,
        macName: String,
        appVersion: String?,
        buttonTitles: [String: String]
    ) {
        onStateChange?(.unavailable)
    }

    public func stop() {
        onStateChange?(.disabled)
    }

    public func updateButtonTitles(_ titles: [String: String]) {}
}
