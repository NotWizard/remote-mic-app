import Foundation
import Testing
@testable import RemoteMic

@Suite("Bluetooth lifecycle")
struct BluetoothLifecycleTests {
    @Test func generationAndPhaseRejectStaleCallbacks() {
        let phase = BluetoothLifecyclePhase.connecting(1)
        #expect(phase.acceptsDidConnect(generation: 1))
        #expect(phase.acceptsDidFailToConnect(generation: 1))
        #expect(phase.acceptsDisconnect(generation: 1))
        #expect(!phase.acceptsDisconnect(generation: 2))
        #expect(!phase.acceptsDidConnect(generation: 2))
        #expect(BluetoothLifecyclePhase.disconnecting(1)
            .acceptsDidFailToConnect(generation: 1))
    }

    @Test func initializationCapabilitiesAndReadyAreDistinct() {
        #expect(BluetoothLifecyclePhase.discovering(1)
            .acceptsInitializationCallback(generation: 1))
        #expect(!BluetoothLifecyclePhase.discovering(1)
            .acceptsCapabilities(generation: 1))
        #expect(BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsCapabilities(generation: 1))
        #expect(!BluetoothLifecyclePhase.awaitingCapabilities(1)
            .acceptsProtocolData(generation: 1))
        #expect(BluetoothLifecyclePhase.ready(1)
            .acceptsProtocolData(generation: 1))
    }

    @Test func microphoneRequiresConfirmed16kReadySession() {
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .awaitingCapabilities(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: false,
            sampleRate: 16_000
        ))
        #expect(!ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 8_000
        ))
        #expect(ATVVSessionGate.canOpenMicrophone(
            phase: .ready(1),
            generation: 1,
            capabilitiesConfirmed: true,
            sampleRate: 16_000
        ))
    }

    @Test func directRemoteStreamIsAllowedUnlessAHostOpenWasJustCancelled() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: false,
            streaming: false,
            now: now
        ) == nil)
        #expect(ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: true,
            streaming: true,
            now: now
        ) == nil)

        let cancelledAt = ATVVSessionGate.cancelledOpenDate(
            microphoneOpened: true,
            streaming: false,
            now: now
        )
        #expect(cancelledAt == now)
        #expect(ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now.addingTimeInterval(1)
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: nil,
            now: now
        ))
        #expect(!ATVVSessionGate.shouldIgnoreStreamAfterCancelledOpen(
            cancelledAt: cancelledAt,
            now: now.addingTimeInterval(2)
        ))
    }

    @Test func nameMatcherAcceptsApprovedCandidateNames() {
        #expect(XiaomiVoiceRemoteNameMatcher.matches("MI RC"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("mi rc"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("  MI RC  "))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("Xiaomi Bluetooth Remote 2 Pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("xiaomi bluetooth remote 2 pro"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙语音遥控器"))
        #expect(XiaomiVoiceRemoteNameMatcher.matches(" 小米蓝牙语音遥控器 "))
    }

    @Test func nameMatcherRejectsBlankNilAndSimilarNonTargetNames() {
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(nil))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches(""))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("   "))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("Mi Mouse"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米蓝牙遥控器"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("MI RC2"))
        #expect(!XiaomiVoiceRemoteNameMatcher.matches("小米"))
    }

    /// Walks a wall clock across an absence and counts the `connect()` calls the policy
    /// authorizes. Every advance comes from a delay the policy declares, so the counts
    /// below are derived from shipping code rather than restated from the bug report.
    private func authorizedConnectAttempts(
        policy: BluetoothReconnectPolicy.PendingConnectPolicy,
        remoteAbsentFor seconds: TimeInterval
    ) -> Int {
        var elapsed: TimeInterval = 0
        var attempts = 0
        while elapsed <= seconds {
            attempts += 1
            elapsed += BluetoothReconnectPolicy.pendingConnectDeadline
            guard let retryDelay = BluetoothReconnectPolicy
                .retryDelayAfterPendingConnectDeadline(policy: policy)
            else { break }
            elapsed += retryDelay
        }
        return attempts
    }

    @Test func anAbsentRemoteCostsOneConnectAttemptInsteadOfHundredsPerHour() {
        let hour: TimeInterval = 3_600
        // What shipped before the fix: an 8 s self-imposed timeout plus a 3 s pause.
        let selfTimeout = BluetoothReconnectPolicy.PendingConnectPolicy
            .restartAttempt(retryDelay: 3)

        #expect(authorizedConnectAttempts(policy: selfTimeout, remoteAbsentFor: hour) == 328)
        #expect(authorizedConnectAttempts(
            policy: selfTimeout,
            remoteAbsentFor: 24 * hour
        ) == 7_855)

        // A pending request is completed by the Bluetooth controller, so the length of
        // the absence must not change the cost.
        #expect(authorizedConnectAttempts(
            policy: BluetoothReconnectPolicy.pendingConnect,
            remoteAbsentFor: hour
        ) == 1)
        #expect(authorizedConnectAttempts(
            policy: BluetoothReconnectPolicy.pendingConnect,
            remoteAbsentFor: 24 * hour
        ) == 1)
        #expect(BluetoothReconnectPolicy.retryDelayAfterPendingConnectDeadline() == nil)
    }

    @Test func aGenuineFailureStillBuysAFreshAttempt() {
        // `didFailToConnect`, `didDisconnectPeripheral` and a failed post-connect
        // handshake are not the pending case: the controller already gave up, so the
        // bridge must keep paying for new attempts instead of going dead.
        var elapsed: TimeInterval = 0
        var attempts = 0
        while elapsed <= 60 {
            attempts += 1
            elapsed += BluetoothReconnectPolicy.failureRetryDelay
        }
        #expect(attempts == 21)
        #expect(BluetoothReconnectPolicy.retryDelayAfterPendingConnectDeadline(
            policy: .restartAttempt(retryDelay: BluetoothReconnectPolicy.failureRetryDelay)
        ) == BluetoothReconnectPolicy.failureRetryDelay)
    }
}
