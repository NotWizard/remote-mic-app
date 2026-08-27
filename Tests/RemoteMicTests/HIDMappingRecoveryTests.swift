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
}
