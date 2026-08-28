import Foundation
import SayAllMacRemoteCore
import Testing
@testable import RemoteMic

/// The reconnect-after-idle failure that shipped twice.
///
/// Symptom: after a long idle the remote reconnects and every custom button mapping is gone,
/// buttons falling back to their native meanings until the app is restarted.
///
/// Field log at the moment of failure:
/// ```
/// VOICE FN MAPPING applied=false ... matched=0
/// HID START rejected reason=power_key_not_suppressed ...
/// BLE READY name=小米蓝牙语音遥控器
/// ```
/// `matched=0` is a not-registered-yet state, not a verdict — the remote's HID service registers
/// on its own timeline, independent of BLE. A backoff retry was added for exactly this, and the
/// log contained **no `HID MAPPING RETRY` line at all**: the retry gate read the published
/// `isConnected`, which `refreshBluetoothPresentation()` only assigns at the *end* of
/// `bluetoothBridge(_:didChange:)` — after `applyHIDSettings()` has already run from the `.ready`
/// branch. On a reconnect the stale value is `false`, so the gate concluded "no remote attached,
/// nothing to retry" and reset itself.
///
/// The previous test suite passed throughout, because it called `HIDMappingRetryPolicy` directly
/// with `remoteConnected: true`. These tests drive the real callback order instead.
@Suite("HID mapping recovery after reconnect")
struct HIDMappingRecoveryTests {
    private struct Scope {
        let settings: AppSettings
        let defaults: UserDefaults
        let name: String

        func tearDown() {
            defaults.removePersistentDomain(forName: name)
        }
    }

    private static func scopedSettings(_ label: String) throws -> Scope {
        let name = "HIDMappingRecoveryTests.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let settings = AppSettings(defaults: defaults)
        settings.customMappingEnabled = true
        return Scope(settings: settings, defaults: defaults, name: name)
    }

    /// Records what the shared logger actually wrote. `AppLogger` notifies observers
    /// synchronously from the writing thread, so the lock is required.
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func record(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func count(prefix: String) -> Int {
            lines.filter { $0.hasPrefix(prefix) }.count
        }

        func reset() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
    }

    /// A mapper whose services are absent, standing in for the window where the remote's HID
    /// service has not registered yet. Every write attempt therefore reports `matched=0`.
    private static func mapperWithNoServices() -> RemoteVoiceFunctionMapper {
        RemoteVoiceFunctionMapper { [] }
    }

    /// Builds a model whose mapping writes always report `matched=0`, and tears it down.
    ///
    /// `hidRuntimePermissions: { false }` keeps the monitor from opening a real `IOHIDManager`.
    /// The IOHID callbacks carry an unretained context and suites run in parallel, so a unit test
    /// that opens one crashes the process. Nothing asserted here needs a real manager — the
    /// subject is which recovery decisions get made and logged.
    @MainActor
    private static func withModel(
        _ scope: Scope,
        _ body: (BridgeAppModel, LogSink) throws -> Void
    ) throws {
        let model = BridgeAppModel(
            settings: scope.settings,
            voiceFunctionMapper: mapperWithNoServices(),
            hidRuntimePermissions: { false }
        )
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer {
            AppLogger.shared.removeWriteObserver(token)
            model.stop()
        }
        model.started = true
        try body(model, sink)
    }

    /// The regression test. Before the fix this produced no `HID MAPPING RETRY scheduled` line,
    /// exactly as the user's log showed, and the mapping stayed dead for the whole session.
    @MainActor
    @Test func aFailedMappingWriteAtBleReadySchedulesARetry() throws {
        let scope = try Self.scopedSettings("retryScheduled")
        defer { scope.tearDown() }
        try Self.withModel(scope) { model, sink in
            let bridge = XiaomiBluetoothBridge(
                settings: scope.settings,
                delegate: model,
                targetIdentifier: UUID()
            )

            // The real order: BLE reports ready while the HID service is still unregistered.
            model.bluetoothBridge(bridge, didChange: .ready("小米蓝牙语音遥控器"))
            AppLogger.shared.flush()

            // The decisive line, absent from the field log.
            #expect(sink.count(prefix: "HID MAPPING RETRY scheduled") == 1)
            // First delay of the backoff, so this is the schedule and not some later attempt.
            #expect(sink.lines.contains {
                $0.hasPrefix("HID MAPPING RETRY scheduled attempt=1 delay_ms=500")
            })
        }
    }

    /// The other half of the fix: the monitor must no longer refuse to start just because the
    /// power key could not be neutralised. Opening the manager is what delivers the
    /// device-matching callback, and that callback is the only reliable signal that the mapping
    /// write can succeed — refusing here made the signal unreachable, leaving polling as the
    /// sole recovery path.
    @Test func observingTheRemoteDoesNotRequireThePowerKeyToBeNeutralisedFirst() {
        #expect(HIDPermissionGate.canObserve(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        // Permissions still gate it.
        #expect(!HIDPermissionGate.canObserve(
            mappingEnabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(!HIDPermissionGate.canObserve(
            mappingEnabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!HIDPermissionGate.canObserve(
            mappingEnabled: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
    }

    /// The recovery path must not restart the monitors.
    ///
    /// Restarting closed and re-seized the remote once per attempt, and the backoff holds at 15 s
    /// with no give-up point, so it was a permanent dropout cycle. It also re-entered
    /// `deviceDidMatch` while that callback was on the stack, leaving the monitor it had just
    /// dropped holding an exclusive open on the device — every button dead until restart.
    ///
    /// `HID START` is written once per `HIDRemoteMonitor.start()`, so counting it counts restarts.
    @MainActor
    @Test func repeatedRecoveryAttemptsDoNotRestartTheMonitors() throws {
        let scope = try Self.scopedSettings("noRestart")
        defer { scope.tearDown() }
        try Self.withModel(scope) { model, sink in
            let bridge = XiaomiBluetoothBridge(
                settings: scope.settings,
                delegate: model,
                targetIdentifier: UUID()
            )
            model.bluetoothBridge(bridge, didChange: .ready("小米蓝牙语音遥控器"))
            AppLogger.shared.flush()
            let startsAfterConnect = sink.lines.filter { $0.hasPrefix("HID START") }.count

            // What a device appearance triggers, ten times over.
            for _ in 0 ..< 10 {
                model.retryPowerKeyMappingWrite(reason: "device_appeared")
            }
            AppLogger.shared.flush()

            #expect(sink.lines.filter { $0.hasPrefix("HID START") }.count == startsAfterConnect)
            // Still reporting itself rather than failing silently.
            #expect(sink.lines.contains { $0.hasPrefix("HID MAPPING WRITE pending") })
        }
    }

    /// Once the write lands, the loop has to stop and say so. A recovery path that keeps
    /// retrying after success is how the dropout cycle stayed invisible.
    @MainActor
    @Test func aSuccessfulWriteEndsTheRetryLoop() throws {
        let scope = try Self.scopedSettings("writeSucceeds")
        defer { scope.tearDown() }
        // A service that accepts writes, standing in for the HID service having registered.
        let mapper = RemoteVoiceFunctionMapper {
            [
                RemoteVoiceMappingService(
                    registryID: 1,
                    locationID: 42,
                    readMappings: { [] },
                    setMappings: { _ in true }
                ),
            ]
        }
        let model = BridgeAppModel(
            settings: scope.settings,
            voiceFunctionMapper: mapper,
            hidRuntimePermissions: { false }
        )
        let sink = LogSink()
        let token = AppLogger.shared.addWriteObserver { sink.record($0) }
        defer {
            AppLogger.shared.removeWriteObserver(token)
            model.stop()
        }
        model.started = true

        model.retryPowerKeyMappingWrite(reason: "device_appeared")
        AppLogger.shared.flush()

        #expect(sink.lines.contains { $0.hasPrefix("HID MAPPING WRITE applied") })
        #expect(!sink.lines.contains { $0.hasPrefix("HID MAPPING WRITE pending") })
        // Nothing further is scheduled once it is applied.
        #expect(!sink.lines.contains { $0.hasPrefix("HID MAPPING RETRY scheduled") })

        // And a second call is a no-op, not another write.
        sink.reset()
        model.retryPowerKeyMappingWrite(reason: "device_appeared")
        AppLogger.shared.flush()
        #expect(!sink.lines.contains { $0.hasPrefix("HID MAPPING WRITE") })
    }

    /// The field regression that shipped in 1.8.25-fork.6.
    ///
    /// The remote's voice button is hardware F5. Injection modes map it to *nothing* so the app's
    /// injected modifier is the only source. The fallback instead maps F5 to that same modifier —
    /// one key, two sources, two release paths — which the code's own comment says sticks. With
    /// the field log ending on `neutralized=false`, the user got VoiceOver toggling (Cmd+F5) and a
    /// Mac where clicks behaved as Command-clicks.
    ///
    /// It was reached because a failed apply ends on its fallback attempt, and the retry replayed
    /// that last attempt rather than the intent — so the first retry that succeeded made the
    /// fallback permanent.
    @MainActor
    @Test func aWriteThatNeverReachedTheRemoteDoesNotDowngradeTheVoiceKey() throws {
        let scope = try Self.scopedSettings("noDowngrade")
        defer { scope.tearDown() }
        scope.settings.voiceTriggerKey = .rightCommand

        // Absent services on the first three attempts, then present — the field sequence.
        final class Services: @unchecked Sendable {
            private let lock = NSLock()
            private var remaining: Int
            private(set) var neutralAttempts: [Bool] = []
            init(absentFor: Int) { remaining = absentFor }
            func provide() -> [RemoteVoiceMappingService] {
                lock.lock()
                defer { lock.unlock() }
                guard remaining <= 0 else {
                    remaining -= 1
                    return []
                }
                return [
                    RemoteVoiceMappingService(
                        registryID: 1,
                        locationID: 42,
                        readMappings: { [] },
                        setMappings: { [weak self] mappings in
                            let neutral = mappings.contains(
                                RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
                            )
                            self?.lock.lock()
                            self?.neutralAttempts.append(neutral)
                            self?.lock.unlock()
                            return true
                        }
                    ),
                ]
            }
        }
        let services = Services(absentFor: 3)
        let mapper = RemoteVoiceFunctionMapper { services.provide() }
        let model = BridgeAppModel(
            settings: scope.settings,
            voiceFunctionMapper: mapper,
            hidRuntimePermissions: { false }
        )
        defer { model.stop() }
        model.started = true

        // Three attempts while the remote's HID service is unregistered.
        for _ in 0 ..< 3 {
            model.retryPowerKeyMappingWrite(reason: "device_appeared")
        }
        // Nothing reached the remote, so nothing may have been concluded about it.
        #expect(!mapper.didReachDevice)
        #expect(services.neutralAttempts.isEmpty)

        // Now it registers.
        model.retryPowerKeyMappingWrite(reason: "device_appeared")

        // The mapping that landed must be the neutral one, not the fallback.
        #expect(mapper.didReachDevice)
        #expect(mapper.isVoiceKeyNeutralized)
        #expect(services.neutralAttempts.allSatisfy { $0 })
    }

    /// The fallback must still be available when it is a real conclusion: the remote was reached
    /// and refused the neutral mapping. Without this the fix would just be "never fall back".
    @MainActor
    @Test func aRemoteThatRefusesTheNeutralMappingStillGetsTheFallback() throws {
        let scope = try Self.scopedSettings("realFallback")
        defer { scope.tearDown() }
        scope.settings.voiceTriggerKey = .rightCommand

        let accepted = Mutex<[Bool]>([])
        let mapper = RemoteVoiceFunctionMapper {
            [
                RemoteVoiceMappingService(
                    registryID: 1,
                    locationID: 42,
                    readMappings: { [] },
                    setMappings: { mappings in
                        let neutral = mappings.contains(
                            RemoteVoiceFunctionMappingPolicy.neutralRemoteVoiceKey
                        )
                        // Reachable, but refuses to discard the voice key.
                        guard !neutral else { return false }
                        accepted.withLock { $0.append(neutral) }
                        return true
                    }
                ),
            ]
        }
        let model = BridgeAppModel(
            settings: scope.settings,
            voiceFunctionMapper: mapper,
            hidRuntimePermissions: { false }
        )
        defer { model.stop() }
        model.started = true

        model.retryPowerKeyMappingWrite(reason: "device_appeared")

        #expect(mapper.didReachDevice)
        #expect(!mapper.isVoiceKeyNeutralized)
        // The fallback was applied, which is correct here: this is a conclusion, not a guess.
        #expect(accepted.withLock { $0 } == [false])
    }

    /// The mapping write must precede monitoring.
    ///
    /// If a monitor came up first, buttons would already be acted on while the power key was still
    /// live. This replaces a check that sliced `applyHIDSettings` out of the source and compared
    /// snippet offsets — that only noticed the literal moving, and did move when the decision was
    /// extracted. Observing the order the lines are actually written catches a real reordering.
    @MainActor
    @Test func theMappingIsWrittenBeforeAnyMonitorStarts() throws {
        let scope = try Self.scopedSettings("ordering")
        defer { scope.tearDown() }
        try Self.withModel(scope) { model, sink in
            model.applyHIDSettings()
            AppLogger.shared.flush()

            let lines = sink.lines
            let mapIndex = try #require(lines.firstIndex { $0.hasPrefix("VOICE FN MAPPING") })
            let startIndex = try #require(lines.firstIndex { $0.hasPrefix("HID START") })
            #expect(mapIndex < startIndex)
        }
    }
}

/// Minimal lock wrapper; the mapper's closures are not main-actor isolated.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
