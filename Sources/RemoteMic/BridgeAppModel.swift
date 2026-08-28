import AppKit
import Combine
import CoreAudio
import Foundation
import SayAllMacRemoteCore

/// Which of the three mobile transports currently owns the single voice channel.
///
/// Internal rather than file-private only so the arbitration between the iPhone, the Apple
/// Watch and the phone web page can be driven from tests. The watch backlog defect of
/// 2026-08-15 was exactly a missing distinction here — both nearby transports shared one
/// marker, so the watch's late stop released the iPhone's session — and the transports
/// themselves cannot be injected, so this enum is the narrowest seam that makes the rule
/// assertable. See Bugs/2026-08-15-watch-ble-audio-backlog-blocks-iphone/DEBUG.md.
enum MobileVoiceSource {
    case nearbyPhone
    case nearbyWatch
    case web

    var logName: String {
        switch self {
        case .nearbyPhone: return "iphone"
        case .nearbyWatch: return "watch"
        case .web: return "web"
        }
    }
}

/// Decides whether releasing the virtual audio output would change anything.
///
/// A resident menu-bar install produced 30880 `AUDIO RELEASE completed` diagnostic lines
/// in 11 days, of which 30878 released nothing: every bluetooth reconnect attempt drives
/// two connection-state transitions, and each one asked for a release even though the
/// engine had already been torn down.
enum VirtualAudioReleaseGate {
    /// The in-memory half of the decision: every observable effect of a release has
    /// already happened.
    static func teardownAlreadyComplete(
        engineHoldsDevice: Bool,
        pendingVoiceBufferCount: Int,
        publishedAudioReady: Bool,
        publishedStatusAlreadyReleased: Bool
    ) -> Bool {
        !engineHoldsDevice
            && pendingVoiceBufferCount == 0
            && !publishedAudioReady
            && publishedStatusAlreadyReleased
    }

    /// Full decision. `defaultInputFallbackWouldRun` is only consulted once the cheap
    /// facts hold, so the CoreAudio probe behind it stays off the hot path. Returning
    /// `false` whenever any cleanup could still be pending keeps the gate conservative:
    /// it never trades correctness for quieter logs.
    static func hasNothingToRelease(
        engineHoldsDevice: Bool,
        pendingVoiceBufferCount: Int,
        publishedAudioReady: Bool,
        publishedStatusAlreadyReleased: Bool,
        defaultInputFallbackWouldRun: () -> Bool
    ) -> Bool {
        guard teardownAlreadyComplete(
            engineHoldsDevice: engineHoldsDevice,
            pendingVoiceBufferCount: pendingVoiceBufferCount,
            publishedAudioReady: publishedAudioReady,
            publishedStatusAlreadyReleased: publishedStatusAlreadyReleased
        ) else { return false }
        return !defaultInputFallbackWouldRun()
    }
}

private struct MobileButtonGestureKey: Hashable {
    let source: UsageEventSource
    let button: RemoteButton
}

private struct ManagedDefaultInputTransition {
    let virtualUID: String
    let fallbackUID: String
}

enum BluetoothVoiceStopPolicy {
    /// Remote stop ends capture but must not discard PCM already scheduled for playback.
    static func shouldFlushAudio(handledByFnTapMode _: Bool) -> Bool {
        false
    }
}

/// Main-actor isolated on purpose: the 22 `@Published` properties below are observed by
/// SwiftUI, so every mutation has to happen on the main actor. That used to be maintained
/// by hand with one `DispatchQueue.main.async` per callback entry point, and the discipline
/// failed — `webRemoteClient.onStateChange` published `webRemoteState` straight from the
/// transport's thread. The isolation makes the compiler carry that rule, so the only hops
/// left are the ones for callbacks that genuinely arrive off the main thread.
@MainActor
final class BridgeAppModel: ObservableObject, XiaomiBluetoothBridgeDelegate {
    private static let longRecordingOpenTimeout: TimeInterval = 5
    private static let longRecordingCloseTimeout: TimeInterval = 2

    let settings: AppSettings
    let privateFeature: PrivateFeatureIntegration
    let macroFeature: MacroFeatureIntegration

    @Published private(set) var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published private(set) var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published private(set) var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var doubaoAudioStatus = LocalizedMessage("audio.compatibility.checking")
    @Published private(set) var isStreaming = false
    @Published private(set) var isConnected = false
    @Published private(set) var isVoiceTriggerEnabled = false
    @Published private(set) var activeRemoteButtons = Set<RemoteButton>()
    @Published private(set) var lastRemoteButtonPress: RemoteButton?
    @Published private(set) var connectedRemoteProfileIDs = Set<UUID>()
    @Published private(set) var remoteBatteryLevels: [UUID: Int] = [:]
    @Published private(set) var remotePowerStates: [UUID: RemotePowerState] = [:]
    @Published private(set) var audioDevices: [AudioDeviceInfo] = []
    @Published private(set) var testToneStatus = LocalizedMessage("audio.output.none_selected")
    @Published private(set) var isPlayingTestTone = false
    @Published private(set) var isAudioOutputReady = false
    @Published private(set) var currentVoiceSampleCount: UInt64 = 0
    @Published private(set) var isPhoneRemoteConnectionEnabled = false
    @Published private(set) var isPhoneRemoteConnected = false
    @Published private(set) var isWatchRemoteConnected = false
    @Published private(set) var webRemoteState: WebRemoteSessionState = .disabled
    @Published private(set) var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")

    /// `nonisolated` because this object is deliberately driven from more than the main
    /// thread: `configure`/`stop` run on `audioPreparationQueue` (CoreAudio device work is
    /// slow), and its drain bookkeeping runs on AVAudioEngine's own buffer-completion
    /// threads behind an internal lock. Only the *reference* is nonisolated; the published
    /// state derived from it is still assigned on the main actor.
    private nonisolated let audioOutput = VirtualAudioOutput()
    private let phoneRemoteServer = PhoneRemoteServer(logger: { message in
        AppLogger.shared.write(message)
    })
    private let watchBluetoothServer = WatchBluetoothRemoteServer(logger: { message in
        AppLogger.shared.write(message)
    })
    private let webRemoteClient = WebRemoteRelayClient()
    private let voiceFunctionMapper: RemoteVoiceFunctionMapper
    private let hidRuntimePermissions: () -> Bool
    private lazy var voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
        onStateChange: { [weak self] state in
            self?.handleVoiceInputDestinationState(state)
        }
    )
    private lazy var voiceFnTapSession = VoiceFnTapSessionController(
        destinationReadiness: { [weak self] completion in
            self?.voiceInputDestinationCoordinator.waitUntilReady(completion: completion) ?? .immediate
        },
        setFunctionKeyPressed: { [weak self] in
            KeyboardInjector.setFunctionKeyPressed(
                $0,
                trigger: self?.settings.voiceTriggerKey ?? .fn
            )
        },
        enqueueAudio: { [weak self] samples in
            _ = self?.audioOutput.enqueue(samples: samples)
        },
        drainAudio: { [weak self] completion in
            guard let self else {
                completion()
                return
            }
            self.audioOutput.endSessionAfterDraining(completion: completion)
        },
        onFailure: { [weak self] failure in
            self?.handleVoiceFnTapFailure(failure)
        }
    )
    private var testToneGeneration = 0
    private var phoneVoiceFunctionKeyLatch = VoiceFunctionKeyLatch()
    private var bluetoothVoiceTriggerLatch = VoiceFunctionKeyLatch()
    private var voiceSessionStartedAt: Date?
    private var voiceSessionUsageSource: UsageEventSource?
    private var bluetoothVoiceActive = false
    private var loggedBluetoothVoiceAudioDeviceIdentifier: UUID?
    /// Holder of the single mobile voice channel, or `nil` when it is free.
    ///
    /// Internal rather than private so a test can start from "the iPhone already holds the
    /// channel". Acquiring it for real is not available to a unit test: `startPhoneVoice`
    /// binds the virtual audio device and then latches the system voice key through
    /// `KeyboardInjector`, which on a machine that has the audio driver installed would
    /// press a real modifier. Production only writes this from `startPhoneVoice`,
    /// `stopPhoneVoice` and `stop()`.
    var activeMobileVoiceSource: MobileVoiceSource?
    private var mobileVoiceAudioBatchCount = 0
    private var mobileVoiceAudioEnqueueFailureCount = 0
    private var mobileVoiceAudioSourceMismatchCount = 0
    private var mobileVoiceAudioSignalMetrics = WatchBluetoothAudioSignalMetrics()
    private var longRecordingRequested = false
    private var longRecordingGeneration: UInt64 = 0
    private var longRecordingOpenTimer: DispatchSourceTimer?
    private var longRecordingCloseTimer: DispatchSourceTimer?
    private var phoneApprovalAlert: NSAlert?
    private var webApprovalAlert: NSAlert?
    private var remoteButtonTitles: [String: String] = [:]
    private var mobileButtonGestureRecognizers: [UsageEventSource: RemoteButtonGestureRecognizer] = [:]
    private var mobileDoubleClickTimers: [MobileButtonGestureKey: DispatchSourceTimer] = [:]
    private var mobileLongPressTimers: [MobileButtonGestureKey: DispatchSourceTimer] = [:]
    private var bluetoothBridges: [UUID: XiaomiBluetoothBridge] = [:]
    private var bluetoothBridgeStates: [ObjectIdentifier: BluetoothBridgeState] = [:]
    private var discoveryBluetoothBridge: XiaomiBluetoothBridge?
    // Battery, power and model all arrive before the ATVV handshake completes, and until it
    // does there is no profile to attach them to. Keyed by peripheral identifier, replayed
    // once the remote proves itself real, never persisted if it does not.
    private var pendingRemoteBatteryLevels: [UUID: Int] = [:]
    private var pendingRemotePowerStates: [UUID: RemotePowerState] = [:]
    private var pendingRemoteModels: [UUID: XiaomiRemoteModel] = [:]
    private var activeBluetoothVoiceDeviceIdentifier: UUID?
    private var bluetoothVoiceTraceCounter: UInt64 = 0
    private var activeBluetoothVoiceTraceID: UInt64?
    private var bluetoothVoiceTraceStartedAt: Date?
    private var bluetoothVoiceTraceModel: XiaomiRemoteModel = .unknown
    private var bluetoothVoiceDecodedBatchCount = 0
    private var bluetoothVoiceDecodedSampleCount = 0
    private var bluetoothVoiceEnqueueFailureCount = 0
    private var bluetoothVoiceTraceRoute = "none"
    private let hidEventSuppressor = KeyboardEventSuppressor()
    private var hidMonitors: [String: HIDRemoteMonitor] = [:]
    private var discoveryHIDMonitor: HIDRemoteMonitor?
    private var hidPowerKeySuppressed = false
    private var hidAllowedLocationIDs: Set<UInt32>?
    private var hidMappingRetryWorkItem: DispatchWorkItem?
    private var hidMappingRetryAttempts = 0
    /// Whether `startIfNeeded()` has run.
    ///
    /// Internal rather than private so a test can reach the connection entry points, which
    /// are all gated on it. Running the real `startIfNeeded()` in a unit test is not an
    /// option: it schedules CoreAudio device binding, creates a `CBCentralManager` (which
    /// prompts for Bluetooth access) and can request Input Monitoring or Accessibility.
    /// Production only writes this from `startIfNeeded()` and `stop()`.
    var started = false
    private var terminationObserver: NSObjectProtocol?
    private var completedUpdateHIDRecoveryWorkItem: DispatchWorkItem?
    private let audioPreparationQueue = DispatchQueue(label: "RemoteMic.audioPreparation", qos: .userInitiated)
    private var audioStartupGeneration: UInt64 = 0
    private var audioDeviceRefreshGeneration: UInt64 = 0
    private var audioStartupPending = false
    private let audioHardwareListenerQueue = DispatchQueue(label: "RemoteMic.audioHardware")
    private var observedAudioHardwareAddresses: [AudioObjectPropertyAddress] = []
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var audioRecoveryGeneration: UInt64 = 0
    private var virtualAudioReleaseGeneration: UInt64 = 0
    private var managedDefaultInputTransition: ManagedDefaultInputTransition?
    private lazy var audioHardwareListener: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
        let properties = Self.audioHardwarePropertyNames(count: count, addresses: addresses)
        self?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
    }

    init(
        settings: AppSettings = AppSettings(),
        initialAudioDevices: [AudioDeviceInfo] = [],
        privateFeature: PrivateFeatureIntegration = PrivateFeatureIntegration(),
        macroFeature: MacroFeatureIntegration = MacroFeatureIntegration(),
        voiceFunctionMapper: RemoteVoiceFunctionMapper = RemoteVoiceFunctionMapper(),
        hidRuntimePermissions: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        }
    ) {
        self.voiceFunctionMapper = voiceFunctionMapper
        self.hidRuntimePermissions = hidRuntimePermissions
        self.settings = settings
        self.privateFeature = privateFeature
        self.macroFeature = macroFeature
        audioDevices = initialAudioDevices
        // Every transport callback below is written `@Sendable` on purpose. The phone, watch
        // and web transports deliver on their own queues, but a plain closure literal
        // written inside this `@MainActor` initializer *silently inherits* main-actor
        // isolation — which is exactly how `webRemoteClient.onStateChange` came to publish
        // `webRemoteState` from the transport's thread with the compiler saying nothing.
        // `@Sendable` opts out of that inference, so the hop is now a compiler requirement
        // instead of a convention: remove one and the build fails.
        audioOutput.onConfigurationChange = { @Sendable [weak self] in
            self?.scheduleAudioRecovery(reason: "engine_configuration_change")
        }
        // The one callback that cannot hop: it has to return the answer in the caller's
        // frame, so it can neither `await` nor dispatch. It is therefore the one place that
        // reads `AppSettings` from the transport's thread — safe because
        // `isPhoneIdentityTrusted` answers from a lock-protected snapshot rather than the
        // `@Published` dictionary the main actor replaces. Keep that guarantee in
        // `AppSettings` if this callback is ever rewritten; see
        // Bugs/2026-08-21-published-state-updated-off-the-main-thread.md.
        phoneRemoteServer.isIdentityTrusted = { [weak self] fingerprint in
            self?.settings.isPhoneIdentityTrusted(fingerprint) ?? false
        }
        phoneRemoteServer.onConnectionStateChange = { @Sendable [weak self] connected in
            DispatchQueue.main.async {
                self?.isPhoneRemoteConnected = connected
            }
        }
        phoneRemoteServer.onApprovalCancelled = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.cancelPhoneApproval()
            }
        }
        phoneRemoteServer.onApprovalRequested = { @Sendable [weak self] deviceName, pairingCode, fingerprint, completion in
            DispatchQueue.main.async {
                // Belt-and-braces from the cancel-waiting fix: an approval that arrives
                // after the user stopped listening is refused rather than re-opening the
                // modal. Unlike before, the flag is read here on the main actor.
                guard let self, self.isPhoneRemoteConnectionEnabled else {
                    completion(false)
                    return
                }
                self.requestPhoneApproval(
                    deviceName: deviceName,
                    pairingCode: pairingCode,
                    identityFingerprint: fingerprint,
                    completion: completion
                )
            }
        }
        phoneRemoteServer.onCommand = { @Sendable [weak self] button, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                completion(self?.performPhoneCommand(button, source: .nearbyPhone) ?? false)
            }
        }
        phoneRemoteServer.onButtonEvent = { @Sendable [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .nearbyPhone
                ) ?? false)
            }
        }
        phoneRemoteServer.onButtonEventsReset = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .nearbyPhone)
            }
        }
        phoneRemoteServer.onVoiceStartResult = { @Sendable [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice(source: .nearbyPhone) ?? .unavailable)
            }
        }
        phoneRemoteServer.onVoiceStop = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .nearbyPhone)
            }
        }
        phoneRemoteServer.onAudio = { @Sendable [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .nearbyPhone)
            }
        }
        // Same non-hopping synchronous query as the phone server above: answered in the
        // transport's own frame from the lock-protected snapshot in `AppSettings`.
        watchBluetoothServer.isIdentityTrusted = { [weak self] fingerprint in
            self?.settings.isPhoneIdentityTrusted(fingerprint) ?? false
        }
        watchBluetoothServer.onConnectionStateChange = { @Sendable [weak self] connected in
            DispatchQueue.main.async {
                self?.isWatchRemoteConnected = connected
            }
        }
        watchBluetoothServer.onApprovalCancelled = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.cancelPhoneApproval()
            }
        }
        watchBluetoothServer.onApprovalRequested = { @Sendable [weak self] deviceName, pairingCode, fingerprint, completion in
            DispatchQueue.main.async {
                guard let self, self.isPhoneRemoteConnectionEnabled else {
                    completion(false)
                    return
                }
                self.requestPhoneApproval(
                    deviceName: deviceName,
                    pairingCode: pairingCode,
                    identityFingerprint: fingerprint,
                    completion: completion
                )
            }
        }
        watchBluetoothServer.onCommand = { @Sendable [weak self] button, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                completion(self?.performPhoneCommand(button, source: .nearbyPhone) ?? false)
            }
        }
        watchBluetoothServer.onButtonEvent = { @Sendable [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .nearbyPhone
                ) ?? false)
            }
        }
        watchBluetoothServer.onButtonEventsReset = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .nearbyPhone)
            }
        }
        watchBluetoothServer.onVoiceStartResult = { @Sendable [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice(source: .nearbyWatch) ?? .unavailable)
            }
        }
        watchBluetoothServer.onVoiceStop = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .nearbyWatch)
            }
        }
        watchBluetoothServer.onAudio = { @Sendable [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .nearbyWatch)
            }
        }
        webRemoteClient.onStateChange = { @Sendable [weak self] state in
            DispatchQueue.main.async {
                self?.webRemoteState = state
            }
        }
        webRemoteClient.onApprovalCancelled = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.cancelWebApproval()
            }
        }
        webRemoteClient.onApprovalRequested = { @Sendable [weak self] deviceName, pairingCode, completion in
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }
                self.requestWebApproval(
                    deviceName: deviceName,
                    pairingCode: pairingCode,
                    completion: completion
                )
            }
        }
        webRemoteClient.onCommand = { @Sendable [weak self] button, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue) else {
                    completion(false)
                    return
                }
                completion(self?.performPhoneCommand(button, source: .webRemote) ?? false)
            }
        }
        webRemoteClient.onButtonEvent = { @Sendable [weak self] button, phase, completion in
            DispatchQueue.main.async {
                guard let button = Self.appRemoteButton(rawValue: button.rawValue),
                      let phase = Self.appRemoteButtonPhase(rawValue: phase.rawValue)
                else {
                    completion(false)
                    return
                }
                completion(self?.handleMobileButtonEvent(
                    button,
                    phase: phase,
                    source: .webRemote
                ) ?? false)
            }
        }
        webRemoteClient.onButtonEventsReset = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.resetMobileButtonGestures(source: .webRemote)
            }
        }
        webRemoteClient.onVoiceStart = { @Sendable [weak self] completion in
            DispatchQueue.main.async {
                completion(self?.startPhoneVoice(source: .web) == .started)
            }
        }
        webRemoteClient.onVoiceStop = { @Sendable [weak self] in
            DispatchQueue.main.async {
                self?.stopPhoneVoice(source: .web)
            }
        }
        webRemoteClient.onAudio = { @Sendable [weak self] samples in
            DispatchQueue.main.async {
                self?.receivePhoneAudio(samples, source: .web)
            }
        }
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        startAudioSubsystem()
        applyHIDSettings()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` above is the guarantee. Checking it with `assumeIsolated`
            // rather than hopping matters here: an async hop would let the process exit
            // before the teardown ran.
            MainActor.assumeIsolated { self?.stop() }
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write("APP START version=\(version)")
    }

    func stop() {
        privateFeature.stop()
        macroFeature.stop()
        guard started else { return }
        started = false
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        cancelHIDMappingRetry()
        hidMappingRetryAttempts = 0
        audioStartupGeneration &+= 1
        audioDeviceRefreshGeneration &+= 1
        let shouldStopAudioOnPreparationQueue = audioStartupPending
        audioStartupPending = false
        audioRecoveryGeneration &+= 1
        audioRecoveryWorkItem?.cancel()
        audioRecoveryWorkItem = nil
        stopObservingAudioHardware()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("app.status.stopped"),
            logReason: "app_stop"
        )
        stopLongRecording(reason: "app_stop")
        voiceInputDestinationCoordinator.shutdown()
        voiceFnTapSession.shutdown()
        bluetoothBridges.values.forEach { $0.stop() }
        discoveryBluetoothBridge?.stop()
        bluetoothBridges.removeAll()
        bluetoothBridgeStates.removeAll()
        discoveryBluetoothBridge = nil
        activeBluetoothVoiceDeviceIdentifier = nil
        phoneRemoteServer.stop()
        watchBluetoothServer.stop()
        webRemoteClient.stop()
        isPhoneRemoteConnectionEnabled = false
        isPhoneRemoteConnected = false
        isWatchRemoteConnected = false
        webRemoteState = .disabled
        bluetoothVoiceActive = false
        activeMobileVoiceSource = nil
        voiceSessionUsageSource = nil
        updatePhoneVoiceFunctionKeyState(streaming: false)
        updateBluetoothVoiceTriggerKey(streaming: false)
        stopHIDMonitors()
        isAudioOutputReady = false
        virtualAudioReleaseGeneration &+= 1
        managedDefaultInputTransition = nil
        if shouldStopAudioOnPreparationQueue {
            audioPreparationQueue.async { [weak self] in
                self?.audioOutput.stop()
            }
        } else {
            audioOutput.stop()
        }
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        AppLogger.shared.write("APP STOP")
    }

    /// `nonisolated`: a pure predicate over its arguments, like the other static helpers here.
    nonisolated static func shouldRecoverHIDAfterCompletedUpdate(
        completedUpdate: Bool,
        customMappingEnabled: Bool
    ) -> Bool {
        completedUpdate && customMappingEnabled
    }

    func recoverHIDAfterCompletedUpdate(delay: TimeInterval = 2) {
        guard started, settings.customMappingEnabled else { return }
        completedUpdateHIDRecoveryWorkItem?.cancel()
        stopHIDMonitors()
        AppLogger.shared.write("HID UPDATE RECOVERY scheduled delay_ms=\(Int(delay * 1_000))")
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started, self.settings.customMappingEnabled else { return }
            self.completedUpdateHIDRecoveryWorkItem = nil
            self.applyHIDSettings()
            AppLogger.shared.write("HID UPDATE RECOVERY applied")
        }
        completedUpdateHIDRecoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func reconnect() {
        guard started else { return }
        if bluetoothBridges.isEmpty && discoveryBluetoothBridge == nil {
            AppLogger.shared.write("BLE RECONNECT starting_missing_bridges")
            startBluetoothConnections()
            return
        }
        if let selectedBluetoothBridge {
            selectedBluetoothBridge.reconnectNow()
        } else {
            bluetoothBridges.values.forEach { $0.reconnectNow() }
            discoveryBluetoothBridge?.reconnectNow()
        }
    }

    func refreshRemoteDiscovery() {
        guard started else { return }
        if discoveryBluetoothBridge == nil {
            startBluetoothDiscoveryIfNeeded()
        } else {
            discoveryBluetoothBridge?.reconnectNow()
        }
        AppLogger.shared.write("BLE DISCOVERY refreshed_from_foreground")
    }

    func enablePhoneRemoteConnection() {
        guard started, !isPhoneRemoteConnectionEnabled else { return }
        isPhoneRemoteConnectionEnabled = true
        phoneRemoteServer.start()
        watchBluetoothServer.start()
        AppLogger.shared.write("PHONE REMOTE enabled_by_user")
    }

    func disablePhoneRemoteConnection() {
        guard isPhoneRemoteConnectionEnabled else { return }
        isPhoneRemoteConnectionEnabled = false
        isPhoneRemoteConnected = false
        isWatchRemoteConnected = false
        cancelPhoneApproval()
        phoneRemoteServer.stop()
        watchBluetoothServer.stop()
        AppLogger.shared.write("PHONE REMOTE disabled_by_user")
    }

    func togglePhoneRemoteConnection() {
        if isPhoneRemoteConnectionEnabled {
            disablePhoneRemoteConnection()
        } else {
            enablePhoneRemoteConnection()
        }
    }

    var isWatchRemoteConnectionEnabled: Bool {
        isPhoneRemoteConnectionEnabled
    }

    func enableWatchRemoteConnection() {
        enablePhoneRemoteConnection()
    }

    func toggleWatchRemoteConnection() {
        togglePhoneRemoteConnection()
    }

    func enableWebRemoteConnection() {
        guard started else { return }
        guard let relayURL = WebRemoteConfiguration.relayURL() else {
            webRemoteState = .unavailable
            AppLogger.shared.write("WEB REMOTE unavailable_missing_configuration")
            return
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        webRemoteState = .connecting
        webRemoteClient.start(
            relayURL: relayURL,
            macName: Host.current().localizedName ?? "Mac",
            appVersion: version,
            buttonTitles: remoteButtonTitles
        )
        AppLogger.shared.write("WEB REMOTE enabled_by_user")
    }

    func disableWebRemoteConnection() {
        webRemoteClient.stop()
        AppLogger.shared.write("WEB REMOTE disabled_by_user")
    }

    func updatePhoneRemoteButtonTitles(
        bindings: [RemoteButton: ButtonAction],
        shortcuts: [RemoteButton: CustomKeyboardShortcut],
        applicationProfileIDs: [RemoteButton: UUID] = [:],
        customApplicationProfiles: [CustomApplicationProfile] = [],
        localization: LocalizationStore
    ) {
        var titles: [String: String] = [:]
        for button in RemoteButton.allCases {
            let action = bindings[button] ?? .disabled
            guard action != AppSettings.defaultBindings[button] else { continue }
            let fullTitle: String
            if action == .customShortcut {
                fullTitle = shortcuts[button]?.displayName(using: localization)
                    ?? action.displayName(using: localization)
            } else if action == .openCustomApplication,
                      let profileID = applicationProfileIDs[button],
                      let profile = customApplicationProfiles.first(where: { $0.id == profileID })
            {
                fullTitle = profile.displayName
            } else {
                fullTitle = action.displayName(using: localization)
            }
            titles[button.rawValue] = String(fullTitle.prefix(10))
        }
        remoteButtonTitles = titles
        phoneRemoteServer.updateButtonTitles(titles)
        watchBluetoothServer.updateButtonTitles(titles)
        webRemoteClient.updateButtonTitles(titles)
    }

    func refreshAudioDevices() {
        audioDeviceRefreshGeneration &+= 1
        let generation = audioDeviceRefreshGeneration
        AppLogger.shared.write("AUDIO DEVICES refresh_requested id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let diagnostic = Self.audioDevicesDiagnostic(devices)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.started,
                      self.audioDeviceRefreshGeneration == generation
                else { return }
                self.publishAudioDevices(devices)
                AppLogger.shared.write("AUDIO DEVICES refreshed id=\(generation) \(diagnostic)")
            }
        }
    }

    private func startAudioSubsystem() {
        audioStartupGeneration &+= 1
        let generation = audioStartupGeneration
        let selectedDeviceUID = settings.selectedAudioDeviceUID
        audioStartupPending = true
        AppLogger.shared.write("AUDIO STARTUP scheduled id=\(generation)")
        audioPreparationQueue.async { [weak self] in
            guard let self else { return }
            let devices = CoreAudioDeviceCatalog.outputDevices()
            let devicesDiagnostic = Self.audioDevicesDiagnostic(devices)
            AppLogger.shared.write("AUDIO DEVICES startup id=\(generation) \(devicesDiagnostic)")
            AppLogger.shared.write(
                "AUDIO REBIND begin reason=startup state={\(self.audioOutput.diagnosticState())}"
            )
            let configured = self.audioOutput.configure(deviceUID: selectedDeviceUID)
            let audioStatus = self.audioOutput.status
            let isAudioOutputReady = self.audioOutput.isReadyForTestTone
            let testToneStatus = isAudioOutputReady
                ? LocalizedMessage("audio.test_tone.ready")
                : LocalizedMessage("audio.output.none_or_unavailable")
            let outputState = self.audioOutput.diagnosticState()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.started, self.audioStartupGeneration == generation else {
                    self.audioPreparationQueue.async { [weak self] in
                        self?.audioOutput.stop()
                    }
                    return
                }
                self.audioStartupPending = false
                self.publishAudioDevices(devices)
                self.audioStatus = audioStatus
                self.isAudioOutputReady = isAudioOutputReady
                self.testToneStatus = testToneStatus
                self.startObservingAudioHardware()
                self.startBluetoothConnections()
                AppLogger.shared.write(
                    "AUDIO REBIND finished reason=startup success=\(configured) status=\(audioStatus.key) " +
                        "state={\(outputState)}"
                )
            }
        }
    }

    private func publishAudioDevices(_ devices: [AudioDeviceInfo]) {
        audioDevices = devices
        doubaoAudioStatus = DoubaoAudioDevicePolicy.status(in: devices)
    }

    /// `nonisolated`: a pure function over its argument, called on `audioPreparationQueue`
    /// while the device list is still being gathered off the main thread.
    private nonisolated static func audioDevicesDiagnostic(_ devices: [AudioDeviceInfo]) -> String {
        "outputs={\(CoreAudioDeviceCatalog.outputDevicesDiagnostic(devices))} " +
            CoreAudioDeviceCatalog.routeDiagnostic()
    }

    var hasDoubaoAudioDevice: Bool {
        DoubaoAudioDevicePolicy.device(in: audioDevices) != nil
    }

    func selectDoubaoAudioDevice() {
        guard let device = DoubaoAudioDevicePolicy.device(in: audioDevices) else {
            doubaoAudioStatus = LocalizedMessage(
                "audio.compatibility.device_missing",
                arguments: [DoubaoAudioDevicePolicy.deviceName]
            )
            return
        }
        settings.selectedAudioDeviceUID = device.uid
        applyAudioSettings(reason: "doubao_device_selected")
        doubaoAudioStatus = LocalizedMessage(
            "audio.compatibility.device_selected",
            arguments: [device.name]
        )
    }

    func openDoubaoDriverInstructions(using localization: LocalizationStore) {
        guard let instructions = localization.localizedURL(
            forResource: "DoubaoInputMethodCompatibility",
            withExtension: "md"
        ) else {
            return
        }
        NSWorkspace.shared.open(instructions)
    }

    func applyAudioSettings(reason: String = "settings_change") {
        stopLongRecording(reason: "audio_reconfigure")
        guard shouldKeepVirtualAudioActive else {
            releaseVirtualAudioOutputIfUnused(reason: reason)
            return
        }
        _ = configureVirtualAudioOutput(reason: reason)
    }

    @discardableResult
    private func configureVirtualAudioOutput(reason: String) -> Bool {
        virtualAudioReleaseGeneration &+= 1
        AppLogger.shared.write("AUDIO REBIND begin reason=\(reason) state={\(audioOutput.diagnosticState())}")
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.cancelled_device_changed"),
            logReason: "device_reconfigure"
        )
        let configured = audioOutput.configure(deviceUID: settings.selectedAudioDeviceUID)
        audioStatus = audioOutput.status
        isAudioOutputReady = audioOutput.isReadyForTestTone
        testToneStatus = isAudioOutputReady
            ? LocalizedMessage("audio.test_tone.ready")
            : LocalizedMessage("audio.output.none_or_unavailable")
        AppLogger.shared.write(
            "AUDIO REBIND finished reason=\(reason) success=\(configured) status=\(audioStatus.key) " +
                "state={\(audioOutput.diagnosticState())}"
        )
        if configured {
            restoreManagedDefaultInputIfAppropriate(reason: reason)
        }
        return configured
    }

    private func startObservingAudioHardware() {
        guard observedAudioHardwareAddresses.isEmpty else { return }
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice,
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let result = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
            if result == noErr {
                observedAudioHardwareAddresses.append(address)
            } else {
                AppLogger.shared.write("AUDIO RECOVERY listener_failed selector=\(selector) error=\(result)")
            }
        }
        AppLogger.shared.write("AUDIO ROUTE_MONITOR started properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
    }

    private func stopObservingAudioHardware() {
        for var address in observedAudioHardwareAddresses {
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                audioHardwareListenerQueue,
                audioHardwareListener
            )
        }
        if !observedAudioHardwareAddresses.isEmpty {
            AppLogger.shared.write("AUDIO ROUTE_MONITOR stopped properties=\(Self.audioHardwarePropertyNames(for: observedAudioHardwareAddresses))")
        }
        observedAudioHardwareAddresses.removeAll()
    }

    /// `nonisolated` because both entry points are off the main thread: the
    /// `AVAudioEngineConfigurationChange` notification is observed with `queue: nil` (so it
    /// arrives on whichever thread posts it) and the CoreAudio property listener block runs
    /// on `audioHardwareListenerQueue`. The hop below is therefore load-bearing, and marking
    /// the method `nonisolated` is what makes the compiler check that nothing outside it
    /// touches published state.
    private nonisolated func scheduleAudioRecovery(reason: String, details: String = "") {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            guard !self.settings.selectedAudioDeviceUID.isEmpty else {
                AppLogger.shared.write("AUDIO RECOVERY ignored reason=\(reason) detail=\(details) no_selected_device")
                return
            }
            guard details != "properties=default_input" else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) explicit_output_unchanged"
                )
                return
            }
            guard self.shouldKeepVirtualAudioActive else {
                self.refreshAudioDevices()
                AppLogger.shared.write(
                    "AUDIO RECOVERY ignored reason=\(reason) detail=\(details) virtual_audio_inactive"
                )
                return
            }
            self.audioRecoveryGeneration &+= 1
            let generation = self.audioRecoveryGeneration
            let replacedPendingRecovery = self.audioRecoveryWorkItem != nil
            self.audioRecoveryWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.started,
                      self.audioRecoveryGeneration == generation
                else { return }
                AppLogger.shared.write(
                    "AUDIO RECOVERY begin id=\(generation) reason=\(reason) detail=\(details) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.refreshAudioDevices()
                self.applyAudioSettings(reason: "recovery_\(reason)")
                AppLogger.shared.write(
                    "AUDIO RECOVERY completed id=\(generation) reason=\(reason) " +
                        "state={\(self.audioOutput.diagnosticState())}"
                )
                self.audioRecoveryWorkItem = nil
            }
            self.audioRecoveryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            AppLogger.shared.write(
                "AUDIO RECOVERY scheduled id=\(generation) reason=\(reason) detail=\(details) " +
                    "replaced_pending=\(replacedPendingRecovery) state={\(self.audioOutput.diagnosticState())}"
            )
        }
    }

    /// `nonisolated`: called from the CoreAudio property listener block, which runs on
    /// `audioHardwareListenerQueue`.
    private nonisolated static func audioHardwarePropertyNames(
        count: UInt32,
        addresses: UnsafePointer<AudioObjectPropertyAddress>
    ) -> String {
        guard count > 0 else { return "none" }
        return (0..<Int(count))
            .map { audioHardwarePropertyName(addresses[$0].mSelector) }
            .joined(separator: ",")
    }

    private static func audioHardwarePropertyNames(
        for addresses: [AudioObjectPropertyAddress]
    ) -> String {
        addresses.map { audioHardwarePropertyName($0.mSelector) }.joined(separator: ",")
    }

    private nonisolated static func audioHardwarePropertyName(
        _ selector: AudioObjectPropertySelector
    ) -> String {
        switch selector {
        case kAudioHardwarePropertyDevices:
            return "devices"
        case kAudioHardwarePropertyDefaultInputDevice:
            return "default_input"
        case kAudioHardwarePropertyDefaultOutputDevice:
            return "default_output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice:
            return "default_system_output"
        default:
            return "selector_\(selector)"
        }
    }

    var canSendTestTone: Bool {
        TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        )
    }

    func sendTestTone() {
        guard TestToneGate.canPlay(
            hasSelectedDevice: selectedAudioDeviceIsAvailable,
            isStreaming: isStreaming,
            isPlaying: isPlayingTestTone
        ) else {
            if isStreaming {
                testToneStatus = LocalizedMessage("audio.test_tone.blocked_voice_active")
                AppLogger.shared.write("AUDIO TEST_TONE rejected_streaming")
            } else if isPlayingTestTone {
                testToneStatus = LocalizedMessage("audio.test_tone.already_playing")
            } else {
                testToneStatus = LocalizedMessage("audio.output.none_or_unavailable")
            }
            return
        }

        guard isAudioOutputReady || configureVirtualAudioOutput(reason: "test_tone") else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_configure_failed")
            return
        }

        testToneGeneration &+= 1
        let generation = testToneGeneration
        let started = audioOutput.playTestTone { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTestToneCompletion(generation: generation, finished: finished)
            }
        }
        guard started else {
            testToneStatus = LocalizedMessage("audio.test_tone.device_not_ready")
            releaseVirtualAudioOutputIfUnused(reason: "test_tone_start_failed")
            return
        }
        isPlayingTestTone = true
        testToneStatus = LocalizedMessage("audio.test_tone.playing")
        AppLogger.shared.write("AUDIO TEST_TONE played")
    }

    private func handleTestToneCompletion(generation: Int, finished: Bool) {
        guard generation == testToneGeneration, isPlayingTestTone else { return }
        isPlayingTestTone = false
        testToneStatus = LocalizedMessage(finished ? "audio.test_tone.completed" : "audio.test_tone.cancelled")
        AppLogger.shared.write("AUDIO TEST_TONE \(finished ? "finished" : "cut_short")")
        releaseVirtualAudioOutputIfUnused(reason: "test_tone_finished")
    }

    private func cancelTestToneIfNeeded(statusMessage: LocalizedMessage, logReason: String) {
        guard isPlayingTestTone else { return }
        testToneGeneration &+= 1
        isPlayingTestTone = false
        audioOutput.cancelTestTone()
        testToneStatus = statusMessage
        AppLogger.shared.write("AUDIO TEST_TONE cancelled reason=\(logReason)")
    }

    func applyHIDSettings() {
        if !settings.customMappingEnabled {
            stopLongRecording(reason: "mapping_disabled")
        }
        if !settings.experimentalContinuousRecordingEnabled {
            stopLongRecording(reason: "feature_disabled")
        }

        let trigger = settings.voiceTriggerKey
        let wantsFnTap = VoiceKeyModePolicy.usesFnTapInjection(
            fnTapEnabled: settings.voiceFnTapModeEnabled,
            usesRemoteMicrophone: settings.voiceKeyUsesRemoteMicrophone,
            trigger: trigger
        )
        let wantsModifierInjection = VoiceKeyModePolicy.usesModifierHoldInjection(trigger: trigger)
        if !wantsFnTap, voiceFnTapSession.requiresCleanupBeforeMapping {
            voiceFnTapSession.setEnabled(false) { [weak self] in
                self?.applyHIDSettings()
            }
            return
        }
        // Release any injected modifier before rewriting the HID mapping.
        updateBluetoothVoiceTriggerKey(streaming: false)
        requestNextHIDPermissionIfNeeded(
            voiceFnTapModeRequested: wantsFnTap || wantsModifierInjection
        )
        startHIDMonitors(powerKeySuppressed: writeVoiceFunctionMapping())
    }

    /// Writes the voice-key and power-key mapping, and reports whether the power key ended up
    /// suppressed. The single definition of that decision: the retry path calls it too, and when
    /// the retry re-derived the choice separately the two drifted into shipping the fallback.
    private func writeVoiceFunctionMapping() -> Bool {
        let trigger = settings.voiceTriggerKey
        let wantsFnTap = VoiceKeyModePolicy.usesFnTapInjection(
            fnTapEnabled: settings.voiceFnTapModeEnabled,
            usesRemoteMicrophone: settings.voiceKeyUsesRemoteMicrophone,
            trigger: trigger
        )
        let wantsModifierInjection = VoiceKeyModePolicy.usesModifierHoldInjection(trigger: trigger)
        if wantsFnTap, !KeyboardInjector.isAccessibilityTrusted {
            // Fn-tap needs Accessibility; without it fall back to the hardware Fn hold.
            settings.voiceFnTapModeEnabled = false
            voiceFnTapSession.setEnabled(false)
            return applyVoiceFunctionMapping(neutralizeVoiceKey: false)
        }
        guard wantsFnTap || wantsModifierInjection else {
            voiceFnTapSession.setEnabled(false)
            return applyVoiceFunctionMapping(neutralizeVoiceKey: false)
        }
        // Injection modes neutralize the hardware F5 so it never emits on its own;
        // a modifier trigger is then injected as a held key tied to the ATVV stream
        // and Fn-tap injects taps. This avoids a stuck hardware-remapped modifier.
        let powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
        if voiceFunctionMapper.isVoiceKeyNeutralized {
            voiceFnTapSession.setEnabled(wantsFnTap)
            return powerKeySuppressed
        }
        voiceFnTapSession.setEnabled(false)
        guard voiceFunctionMapper.didReachDevice else {
            // Nothing was reached, so nothing was learned. Falling back here would map the
            // remote's F5 to the very modifier this app also injects: one key, two sources, two
            // release paths — which is how it sticks, and with F5 still live underneath it is
            // also how Cmd+F5 reaches macOS and toggles VoiceOver. Leave the mapping alone and
            // let the retry aim for neutralisation again.
            return powerKeySuppressed
        }
        // The remote was there and neutralisation still did not take, so this hardware cannot do
        // it. Now the fallback is a conclusion rather than a guess.
        settings.voiceFnTapModeEnabled = false
        return applyVoiceFunctionMapping(neutralizeVoiceKey: false)
    }

    private func startHIDMonitors(powerKeySuppressed: Bool) {
        stopHIDMonitors()
        cancelHIDMappingRetry()
        hidPowerKeySuppressed = powerKeySuppressed
        hidAllowedLocationIDs = settings.customMappingEnabled
            ? voiceFunctionMapper.powerSuppressedLocationIDs
            : nil
        guard settings.customMappingEnabled else {
            hidMappingRetryAttempts = 0
            hidStatus = LocalizedMessage("button_mapping.status.system_managed")
            return
        }
        if powerKeySuppressed {
            hidMappingRetryAttempts = 0
        } else {
            scheduleHIDMappingRetryIfNeeded()
        }
        // Skipped without permission: no monitor can run, so the tap would have nothing to
        // suppress, and its callback carries an unretained context. A tap still armed after its
        // owner is freed calls into freed memory.
        if hidRuntimePermissions() {
            _ = hidEventSuppressor.start()
        }
        for profile in settings.remoteDeviceProfiles {
            guard let fingerprint = profile.hidFingerprint else { continue }
            let monitor = makeHIDMonitor(
                profileID: profile.id,
                targetFingerprint: fingerprint
            )
            hidMonitors[fingerprint] = monitor
            monitor.start(
                powerKeySuppressed: powerKeySuppressed,
                allowedLocationIDs: hidAllowedLocationIDs
            )
        }
        startHIDDiscoveryIfNeeded()
    }

    private func cancelHIDMappingRetry() {
        hidMappingRetryWorkItem?.cancel()
        hidMappingRetryWorkItem = nil
    }

    /// Re-runs only the mapping write, then pushes the result into the monitors already running.
    ///
    /// Deliberately not `applyHIDSettings()`. That stops and rebuilds every monitor, which
    /// closes and re-seizes the remote — once per attempt, and the backoff holds at 15 s
    /// forever, so it is a permanent dropout cycle. It also re-entered `deviceDidMatch` while
    /// that callback was still on the stack: the monitor it had just dropped went on to seize
    /// the device, and nothing ever released it, leaving every button dead.
    ///
    /// Because nothing restarts, an already-present device is not re-delivered, so repeated
    /// calls cannot loop and no latch is required.
    func retryPowerKeyMappingWrite(reason: String) {
        guard started, settings.customMappingEnabled, !hidPowerKeySuppressed else { return }
        guard writeVoiceFunctionMapping() else {
            AppLogger.shared.write("HID MAPPING WRITE pending reason=\(reason)")
            scheduleHIDMappingRetryIfNeeded()
            return
        }
        hidPowerKeySuppressed = true
        hidAllowedLocationIDs = voiceFunctionMapper.powerSuppressedLocationIDs
        hidMappingRetryAttempts = 0
        cancelHIDMappingRetry()
        for monitor in hidMonitors.values {
            monitor.updatePowerKeySuppressed(true, allowedLocationIDs: hidAllowedLocationIDs)
        }
        discoveryHIDMonitor?.updatePowerKeySuppressed(
            true,
            allowedLocationIDs: hidAllowedLocationIDs
        )
        AppLogger.shared.write("HID MAPPING WRITE applied reason=\(reason)")
    }

    /// The authoritative answer, read from the bridge states rather than from `isConnected`.
    ///
    /// `isConnected` is published by `refreshBluetoothPresentation()`, which runs at the *end* of
    /// `bluetoothBridge(_:didChange:)` — after `applyHIDSettings()` has already run from the
    /// `.ready` branch. A decision taken during that window sees the previous value, which on a
    /// reconnect is `false`. That is what silently disabled the retry this policy exists for.
    private var hasReadyBluetoothBridge: Bool {
        bluetoothBridgeStates.values.contains { state in
            if case .ready = state { return true }
            return false
        }
    }

    /// The remote's HID service can register after BLE reports ready, so a failed mapping
    /// write is a not-ready-yet state rather than a verdict. Keep re-applying while the
    /// mapping is still wanted and the remote is still connected.
    private func scheduleHIDMappingRetryIfNeeded() {
        guard started else { return }
        guard let delay = HIDMappingRetryPolicy.retryDelayMilliseconds(
            completedAttempts: hidMappingRetryAttempts,
            mappingEnabled: settings.customMappingEnabled,
            mappingApplied: hidPowerKeySuppressed,
            remoteConnected: hasReadyBluetoothBridge
        ) else {
            hidMappingRetryAttempts = 0
            return
        }
        hidMappingRetryAttempts += 1
        cancelHIDMappingRetry()
        // The backoff holds at its last delay with no give-up point, which is right for
        // recovery but would otherwise leave "power button pending" on screen forever. Past the
        // table the write is not merely late, so say so.
        if hidMappingRetryAttempts > HIDMappingRetryPolicy.delaysMilliseconds.count {
            hidStatus = LocalizedMessage("button_mapping.error.power_suppression_failed")
        }
        AppLogger.shared.write(
            "HID MAPPING RETRY scheduled attempt=\(hidMappingRetryAttempts) delay_ms=\(delay)"
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hidMappingRetryWorkItem = nil
            guard self.started, self.settings.customMappingEnabled, self.hasReadyBluetoothBridge else {
                AppLogger.shared.write("HID MAPPING RETRY abandoned reason=preconditions_changed")
                self.hidMappingRetryAttempts = 0
                return
            }
            AppLogger.shared.write("HID MAPPING RETRY attempt=\(self.hidMappingRetryAttempts)")
            self.retryPowerKeyMappingWrite(reason: "backoff")
        }
        hidMappingRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(clamping: delay)),
            execute: workItem
        )
    }

    private func stopHIDMonitors() {
        hidMonitors.values.forEach { $0.stop() }
        discoveryHIDMonitor?.stop()
        hidMonitors.removeAll()
        discoveryHIDMonitor = nil
        hidEventSuppressor.stop()
        activeRemoteButtons = []
    }

    private func startHIDDiscoveryIfNeeded() {
        guard settings.customMappingEnabled, discoveryHIDMonitor == nil else { return }
        let monitor = makeHIDMonitor(
            profileID: nil,
            targetFingerprint: nil,
            excludedFingerprints: { [weak self] in
                guard let self else { return [] }
                return Set(self.hidMonitors.keys)
            }
        )
        discoveryHIDMonitor = monitor
        monitor.start(
            powerKeySuppressed: hidPowerKeySuppressed,
            allowedLocationIDs: hidAllowedLocationIDs
        )
    }

    private func makeHIDMonitor(
        profileID: UUID?,
        targetFingerprint: String?,
        excludedFingerprints: @escaping () -> Set<String> = { [] }
    ) -> HIDRemoteMonitor {
        let monitor = HIDRemoteMonitor(
            settings: settings,
            profileID: profileID,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints,
            eventSuppressor: hidEventSuppressor,
            ownsEventSuppressor: false,
            runtimePermissions: hidRuntimePermissions,
            actionPerformer: { [weak self] _, _, configured in
                self?.performExternalConfiguredAction(configured) ?? false
            },
            overrideActionPerformer: { [weak self] profileID, button, trigger in
                self?.macroFeature.executeBoundMacro(
                    profileID: profileID,
                    button: button,
                    trigger: trigger
                ) == true
            },
            hasOverrideBinding: { [weak self] profileID, button, trigger in
                self?.macroFeature.hasActiveBinding(
                    profileID: profileID,
                    button: button,
                    trigger: trigger
                ) == true
            }
        )
        monitor.onDeviceAppeared = { [weak self] in
            self?.retryPowerKeyMappingWrite(reason: "device_appeared")
        }
        monitor.onStatus = { [weak self, weak monitor] value in
            guard let self, let monitor else { return }
            if monitor.profileID == self.settings.selectedRemoteProfileID || monitor.profileID == nil {
                self.hidStatus = value
            }
        }
        monitor.onActiveButtons = { [weak self] profileID, buttons in
            guard let self, profileID == self.settings.selectedRemoteProfileID else { return }
            self.activeRemoteButtons = buttons
        }
        monitor.onButtonPressed = { [weak self, weak monitor] profileID, fingerprint, button in
            guard let self, let monitor else {
                return profileID.map { ($0, true) }
            }
            self.lastRemoteButtonPress = button
            let existingProfileID = profileID
                ?? self.settings.profileID(forHIDFingerprint: fingerprint)
            let resolvedProfileID = existingProfileID
                ?? self.settings.registerHIDRemote(fingerprint: fingerprint)
            if resolvedProfileID == self.settings.selectedRemoteProfileID {
                self.macroFeature.noteButtonInteraction(button: button)
            }
            let isNewBinding = existingProfileID == nil
            if isNewBinding {
                monitor.assignProfileID(resolvedProfileID)
                self.hidMonitors[fingerprint] = monitor
                if self.discoveryHIDMonitor === monitor {
                    self.discoveryHIDMonitor = nil
                    self.startHIDDiscoveryIfNeeded()
                }
            }
            self.selectRemoteProfile(resolvedProfileID)
            self.settings.recordButtonPress(
                control: .remoteButton(button),
                source: .bluetoothRemote
            )
            return (resolvedProfileID, !self.macroFeature.isEditorActive)
        }
        monitor.onInternalAction = { [weak self] profileID, action in
            guard let self else { return }
            if let profileID { self.selectRemoteProfile(profileID) }
            self.performInternalAction(action)
        }
        return monitor
    }

    func setExperimentalContinuousRecordingEnabled(_ enabled: Bool) {
        if !enabled {
            stopLongRecording(reason: "feature_disabled")
        }
        settings.setExperimentalContinuousRecordingEnabled(enabled)
        applyHIDSettings()
    }

    func setVoiceFnTapModeEnabled(_ enabled: Bool) {
        if enabled {
            enableVoiceFnTapMode()
            return
        }
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false) { [weak self] in
            self?.applyHIDSettings()
        }
    }

    func setVoiceTriggerKey(_ trigger: VoiceTriggerKey) {
        guard settings.voiceTriggerKey != trigger else { return }
        // Release the currently-held trigger using the OLD key before switching;
        // otherwise a held modifier would be released with the new key code and stick.
        updateBluetoothVoiceTriggerKey(streaming: false)
        settings.voiceTriggerKey = trigger
        AppLogger.shared.write("VOICE TRIGGER key=\(trigger.rawValue)")
        applyHIDSettings()
    }

    func setVoiceKeyUsesRemoteMicrophone(_ enabled: Bool) {
        guard settings.voiceKeyUsesRemoteMicrophone != enabled else { return }
        settings.voiceKeyUsesRemoteMicrophone = enabled
        AppLogger.shared.write("VOICE REMOTE_MIC enabled=\(enabled)")
        if !enabled, bluetoothVoiceActive {
            activeBluetoothVoiceDeviceIdentifier = nil
            bluetoothVoiceActive = false
            _ = voiceFnTapSession.stopVoice()
            endVoiceSessionIfNeeded()
        }
        applyHIDSettings()
    }

    private func enableVoiceFnTapMode() {
        guard KeyboardInjector.isAccessibilityTrusted else {
            settings.voiceFnTapModeEnabled = false
            requestNextHIDPermissionIfNeeded(voiceFnTapModeRequested: true)
            applyHIDSettings()
            return
        }

        var powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: true)
        guard voiceFunctionMapper.isVoiceKeyNeutralized else {
            settings.voiceFnTapModeEnabled = false
            voiceFnTapSession.setEnabled(false)
            powerKeySuppressed = applyVoiceFunctionMapping(neutralizeVoiceKey: false)
            startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
            return
        }
        settings.voiceFnTapModeEnabled = true
        voiceFnTapSession.setEnabled(true)
        startHIDMonitors(powerKeySuppressed: powerKeySuppressed)
    }

    private func handleVoiceFnTapFailure(_ failure: VoiceFnTapFailure) {
        AppLogger.shared.write("VOICE FN TAP failed reason=\(failure.rawValue) fallback=hardware_fn")
        settings.voiceFnTapModeEnabled = false
        voiceFnTapSession.setEnabled(false)
        applyHIDSettings()
    }

    private func requestNextHIDPermissionIfNeeded(
        voiceFnTapModeRequested: Bool? = nil
    ) {
        let request = HIDPermissionGate.nextPermissionRequest(
            mappingEnabled: settings.customMappingEnabled,
            voiceFnTapModeEnabled: voiceFnTapModeRequested ?? settings.voiceFnTapModeEnabled,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        switch request {
        case .none:
            break
        case .inputMonitoring:
            _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        case .accessibility:
            _ = KeyboardInjector.requestAccessibilityAccess()
        }
    }

    func requestInputMonitoringPermission() {
        _ = HIDRemoteMonitor.requestInputMonitoringAccess()
        openPrivacyPane("Privacy_ListenEvent")
    }

    func requestAccessibilityPermission() {
        _ = KeyboardInjector.requestAccessibilityAccess()
        openPrivacyPane("Privacy_Accessibility")
    }

    func openLogFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppLogger.shared.logURL])
    }

    func openProjectFolder() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidate = executable.deletingLastPathComponent()
        if candidate.path.contains(".app/Contents/MacOS") {
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(candidate)
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var selectedBluetoothBridge: XiaomiBluetoothBridge? {
        guard let identifier = settings.selectedRemoteProfile?.bluetoothIdentifier else { return nil }
        return bluetoothBridges[identifier]
    }

    private func startBluetoothConnections() {
        let identifiers = Set(settings.remoteDeviceProfiles.compactMap(\.bluetoothIdentifier))
        for identifier in identifiers where bluetoothBridges[identifier] == nil {
            let bridge = XiaomiBluetoothBridge(
                settings: settings,
                delegate: self,
                targetIdentifier: identifier
            )
            bluetoothBridges[identifier] = bridge
            bridge.start()
        }
        startBluetoothDiscoveryIfNeeded()
    }

    private func startBluetoothDiscoveryIfNeeded() {
        guard started, discoveryBluetoothBridge == nil else { return }
        let bridge = XiaomiBluetoothBridge(
            settings: settings,
            delegate: self,
            excludedIdentifiers: { [weak self] in
                guard let self else { return [] }
                return Set(self.bluetoothBridges.keys)
            }
        )
        discoveryBluetoothBridge = bridge
        bridge.start()
    }

    private func registerBluetoothBridgeIfNeeded(_ bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        let profileID = settings.profileID(forBluetoothIdentifier: identifier)
            ?? settings.registerBluetoothRemote(identifier: identifier)
        applyPendingRemoteTelemetry(identifier: identifier, profileID: profileID)
        if discoveryBluetoothBridge === bridge {
            discoveryBluetoothBridge = nil
            bluetoothBridges[identifier] = bridge
            startBluetoothDiscoveryIfNeeded()
        } else if bluetoothBridges[identifier] == nil {
            bluetoothBridges[identifier] = bridge
        }
        return profileID
    }

    private func applyPendingRemoteTelemetry(identifier: UUID, profileID: UUID) {
        if let level = pendingRemoteBatteryLevels.removeValue(forKey: identifier) {
            remoteBatteryLevels[profileID] = min(100, max(0, level))
        }
        if let powerState = pendingRemotePowerStates.removeValue(forKey: identifier) {
            remotePowerStates[profileID] = powerState
        }
        if let model = pendingRemoteModels.removeValue(forKey: identifier) {
            settings.updateRemoteProfileModel(profileID, model: model)
        }
    }

    private func bluetoothIdentifier(for bridge: XiaomiBluetoothBridge) -> UUID? {
        bridge.deviceIdentifier ?? bluetoothBridges.first(where: { $0.value === bridge })?.key
    }

    /// Lookup only. Persisting a profile here would leave one behind for every peripheral that
    /// answers a battery or model read and then never completes the voice handshake — a nearby
    /// `MI RC` advertiser is enough, and the stale card can never be removed from the UI.
    private func remoteProfileID(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let identifier = bluetoothIdentifier(for: bridge) else { return nil }
        return settings.profileID(forBluetoothIdentifier: identifier)
    }

    func selectRemoteProfile(_ profileID: UUID) {
        settings.selectRemoteProfile(profileID)
        refreshBluetoothPresentation()
    }

    private func activateRemoteProfile(for bridge: XiaomiBluetoothBridge) -> UUID? {
        guard let profileID = registerBluetoothBridgeIfNeeded(bridge) else { return nil }
        selectRemoteProfile(profileID)
        return profileID
    }

    private func refreshBluetoothPresentation() {
        let allStates = bluetoothBridgeStates.values
        connectedRemoteProfileIDs = Set(bluetoothBridges.compactMap { identifier, bridge in
            guard let profileID = settings.profileID(forBluetoothIdentifier: identifier),
                  let state = bluetoothBridgeStates[ObjectIdentifier(bridge)],
                  case .ready = state
            else { return nil }
            return profileID
        })
        isConnected = hasReadyBluetoothBridge
        if let selectedBluetoothBridge,
           let state = bluetoothBridgeStates[ObjectIdentifier(selectedBluetoothBridge)] {
            connectionStatus = state.message
        } else if let ready = allStates.first(where: { state in
            if case .ready = state { return true }
            return false
        }) {
            connectionStatus = ready.message
        } else if let state = allStates.first {
            connectionStatus = state.message
        } else {
            connectionStatus = LocalizedMessage("connection.status.searching")
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didChange state: BluetoothBridgeState
    ) {
        let hadReadyBridge = bluetoothBridgeStates.values.contains { existingState in
            if case .ready = existingState { return true }
            return false
        }
        bluetoothBridgeStates[ObjectIdentifier(bridge)] = state
        if case .ready = state {
            _ = registerBluetoothBridgeIfNeeded(bridge)
            voiceFnTapSession.resume()
            if !hadReadyBridge {
                applyHIDSettings()
            }
        } else {
            let identifier = bluetoothIdentifier(for: bridge)
            if let identifier {
                // `.discovering` is published from `didConnect`, before any characteristic is
                // read, and identical states do not re-notify — so this cannot discard a
                // reading from the connection currently being set up. What it does discard is
                // a reading left over from an attempt that never reached the handshake.
                pendingRemoteBatteryLevels.removeValue(forKey: identifier)
                pendingRemotePowerStates.removeValue(forKey: identifier)
                pendingRemoteModels.removeValue(forKey: identifier)
                if let profileID = settings.profileID(forBluetoothIdentifier: identifier) {
                    remoteBatteryLevels.removeValue(forKey: profileID)
                    remotePowerStates.removeValue(forKey: profileID)
                }
            }
            let voiceWasActive = identifier == activeBluetoothVoiceDeviceIdentifier
            if voiceWasActive {
                bluetoothVoiceActive = false
                activeBluetoothVoiceDeviceIdentifier = nil
                endVoiceSessionIfNeeded(flushAudio: false)
            }
            if longRecordingRequested {
                finishLongRecording(reason: "bluetooth_not_ready")
            }
        }
        refreshBluetoothPresentation()
        if isConnected {
            voiceFnTapSession.resume()
            if !isAudioOutputReady {
                _ = configureVirtualAudioOutput(reason: "bluetooth_ready")
            }
        } else {
            updateBluetoothVoiceTriggerKey(streaming: false)
            voiceFnTapSession.suspend { [weak self] in
                self?.releaseVirtualAudioOutputIfUnused(reason: "bluetooth_not_ready")
            }
        }
    }

    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge) {
        // Emit the trigger first: a modifier is injected here (held), while Fn stays a
        // hardware remap handled elsewhere. Runs in both remote-mic and pure-trigger modes.
        updateBluetoothVoiceTriggerKey(streaming: true)
        // Pure-trigger mode: ignore the remote's audio. Returning before setting
        // activeBluetoothVoiceDeviceIdentifier makes didDecode/didStopVoice no-op.
        guard settings.voiceKeyUsesRemoteMicrophone else {
            AppLogger.shared.write("ATVV STREAM trigger_only")
            return
        }
        guard let identifier = bridge.deviceIdentifier else { return }
        let profileID = activateRemoteProfile(for: bridge)
        if let activeBluetoothVoiceDeviceIdentifier,
           activeBluetoothVoiceDeviceIdentifier != identifier {
            _ = bridge.requestMicrophoneClose()
            AppLogger.shared.write("ATVV STREAM rejected_busy")
            return
        }
        activeBluetoothVoiceDeviceIdentifier = identifier
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = true
        let model = profileID
            .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
            ?? .unknown
        bluetoothVoiceTraceCounter &+= 1
        activeBluetoothVoiceTraceID = bluetoothVoiceTraceCounter
        bluetoothVoiceTraceStartedAt = Date()
        bluetoothVoiceTraceModel = model
        bluetoothVoiceDecodedBatchCount = 0
        bluetoothVoiceDecodedSampleCount = 0
        currentVoiceSampleCount = 0
        bluetoothVoiceEnqueueFailureCount = 0
        bluetoothVoiceTraceRoute = "none"
        AppLogger.shared.write(
            "ATVV STREAM accepted trace=\(bluetoothVoiceTraceCounter) model=\(model.rawValue)"
        )
        if longRecordingRequested {
            longRecordingOpenTimer?.cancel()
            longRecordingOpenTimer = nil
            AppLogger.shared.write("LONG RECORDING started")
        }
        _ = voiceFnTapSession.startVoice()
        beginVoiceSessionIfNeeded()
    }

    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge) {
        // Release the injected modifier on every stop, before the active-device guard,
        // so a held trigger key is always released (also in pure-trigger mode).
        updateBluetoothVoiceTriggerKey(streaming: false)
        guard bridge.deviceIdentifier == activeBluetoothVoiceDeviceIdentifier else { return }
        activeBluetoothVoiceDeviceIdentifier = nil
        loggedBluetoothVoiceAudioDeviceIdentifier = nil
        bluetoothVoiceActive = false
        if longRecordingRequested {
            finishLongRecording(reason: "remote_stop")
        } else if longRecordingCloseTimer != nil {
            longRecordingCloseTimer?.cancel()
            longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_confirmed")
        }
        let handledByFnTapMode = voiceFnTapSession.stopVoice()
        let shouldFlushAudio = BluetoothVoiceStopPolicy.shouldFlushAudio(
            handledByFnTapMode: handledByFnTapMode
        )
        let traceID = activeBluetoothVoiceTraceID ?? 0
        let durationMilliseconds = bluetoothVoiceTraceStartedAt.map {
            max(0, Int(Date().timeIntervalSince($0) * 1_000))
        } ?? 0
        let pendingBuffers = audioOutput.pendingVoiceBufferCountForDiagnostics
        AppLogger.shared.write(
            "ATVV STREAM summary trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue) " +
                "duration_ms=\(durationMilliseconds) batches=\(bluetoothVoiceDecodedBatchCount) " +
                "samples=\(bluetoothVoiceDecodedSampleCount) " +
                "enqueue_failures=\(bluetoothVoiceEnqueueFailureCount) " +
                "route=\(bluetoothVoiceTraceRoute) pending_buffers=\(pendingBuffers) " +
                "flush=\(shouldFlushAudio)"
        )
        audioOutput.logWhenPendingVoiceAudioDrains(
            context: "trace=\(traceID) model=\(bluetoothVoiceTraceModel.rawValue)"
        )
        activeBluetoothVoiceTraceID = nil
        bluetoothVoiceTraceStartedAt = nil
        endVoiceSessionIfNeeded(flushAudio: shouldFlushAudio)
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16]) {
        guard let identifier = bridge.deviceIdentifier,
              identifier == activeBluetoothVoiceDeviceIdentifier
        else { return }
        let handledByFnTapMode = voiceFnTapSession.receive(samples)
        let enqueued = handledByFnTapMode || audioOutput.enqueue(samples: samples)
        bluetoothVoiceDecodedBatchCount += 1
        bluetoothVoiceDecodedSampleCount += samples.count
        currentVoiceSampleCount &+= UInt64(samples.count)
        if !enqueued {
            bluetoothVoiceEnqueueFailureCount += 1
        }
        bluetoothVoiceTraceRoute = handledByFnTapMode ? "fn_tap" : "virtual_audio"
        if loggedBluetoothVoiceAudioDeviceIdentifier != identifier {
            loggedBluetoothVoiceAudioDeviceIdentifier = identifier
            let model = settings.profileID(forBluetoothIdentifier: identifier)
                .flatMap { id in settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model }
                ?? .unknown
            AppLogger.shared.write(
                "ATVV AUDIO routed trace=\(activeBluetoothVoiceTraceID ?? 0) " +
                    "model=\(model.rawValue) route=\(bluetoothVoiceTraceRoute) " +
                    "accepted=\(enqueued) first_batch_samples=\(samples.count) " +
                    "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
            )
        }
    }

    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?) {
        guard let profileID = remoteProfileID(for: bridge) else {
            if let identifier = bluetoothIdentifier(for: bridge) {
                // A nil level means the read failed, so it has to clear any buffered value
                // rather than let it survive as the one that gets replayed.
                pendingRemoteBatteryLevels[identifier] = level
            }
            return
        }
        if let level {
            remoteBatteryLevels[profileID] = min(100, max(0, level))
        } else {
            remoteBatteryLevels.removeValue(forKey: profileID)
        }
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didIdentifyRemoteModel model: XiaomiRemoteModel
    ) {
        guard let profileID = remoteProfileID(for: bridge) else {
            if let identifier = bluetoothIdentifier(for: bridge) {
                pendingRemoteModels[identifier] = model
            }
            return
        }
        settings.updateRemoteProfileModel(profileID, model: model)
    }

    func bluetoothBridge(
        _ bridge: XiaomiBluetoothBridge,
        didUpdatePowerState state: RemotePowerState?
    ) {
        guard let profileID = remoteProfileID(for: bridge) else {
            if let identifier = bluetoothIdentifier(for: bridge) {
                pendingRemotePowerStates[identifier] = state
            }
            return
        }
        if let state {
            remotePowerStates[profileID] = state
        } else {
            remotePowerStates.removeValue(forKey: profileID)
        }
    }

    func batteryLevel(for profileID: UUID) -> Int? {
        remoteBatteryLevels[profileID]
    }

    func powerState(for profileID: UUID) -> RemotePowerState? {
        remotePowerStates[profileID]
    }

    func isRemoteConnected(_ profileID: UUID) -> Bool {
        connectedRemoteProfileIDs.contains(profileID)
    }

    /// Every string the connection approval alerts put on screen.
    ///
    /// These are `NSAlert`s rather than SwiftUI views, so they need resolved strings instead
    /// of `Text` keys — which is how they ended up hard-coded in Chinese, showing Chinese to
    /// English users at the one moment they have to decide whether to trust a device.
    ///
    /// Naming the keys here, rather than inline at the assignment, is what makes the missing
    /// key case testable: `referencedKeys` is the list the alerts actually ask for, so a test
    /// can check it against both `Localizable.strings` files. A key that is absent does not
    /// crash — `LocalizationStore.text(_:)` returns the identifier — so the failure mode is a
    /// raw key like `connection.approval.deny` on a button, which only a test will catch.
    enum ConnectionApprovalAlertText {
        static func nearbyTitle(deviceName: String) -> LocalizedMessage {
            LocalizedMessage("connection.approval.nearby.title", arguments: [deviceName])
        }

        static let watchDetail = LocalizedMessage("connection.approval.watch.detail")
        static let phoneDetail = LocalizedMessage("connection.approval.phone.detail")

        static func webTitle(deviceName: String) -> LocalizedMessage {
            LocalizedMessage("connection.approval.web.title", arguments: [deviceName])
        }

        static let webDetail = LocalizedMessage("connection.approval.web.detail")

        static func pairingCodeAccessibility(pairingCode: String) -> LocalizedMessage {
            LocalizedMessage(
                "connection.web.pairing_code_accessibility",
                arguments: [pairingCode]
            )
        }

        static let allow = LocalizedMessage("connection.approval.allow")
        static let deny = LocalizedMessage("connection.approval.deny")
        static let stopWaiting = LocalizedMessage("connection.phone.cancel_waiting")

        /// Keys the alerts resolve at runtime, for the localization parity test.
        static var referencedKeys: [String] {
            [
                nearbyTitle(deviceName: "").key,
                watchDetail.key,
                phoneDetail.key,
                webTitle(deviceName: "").key,
                webDetail.key,
                pairingCodeAccessibility(pairingCode: "").key,
                allow.key,
                deny.key,
                stopWaiting.key,
            ]
        }
    }

    /// Callers hop at the transport boundary, so this runs on the main actor already. The
    /// enabled-check stays immediately before the alert is built: that is the "reject the
    /// late request instead of re-opening the modal" rule from the cancel-waiting fix.
    ///
    /// Internal for test access. A test may only call this while the listener is disabled;
    /// that path answers `false` and returns without building the alert, whereas the
    /// enabled path runs a modal and would block the suite.
    func requestPhoneApproval(
        deviceName: String,
        pairingCode: String,
        identityFingerprint: String?,
        completion: @escaping (Bool) -> Void
    ) {
        guard self.isPhoneRemoteConnectionEnabled else {
            completion(false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let localization = LocalizationStore(settings: settings)
        let alert = NSAlert()
        alert.messageText = ConnectionApprovalAlertText
            .nearbyTitle(deviceName: deviceName)
            .text(using: localization)
        if Self.isAppleWatchDeviceName(deviceName) {
            alert.informativeText = ConnectionApprovalAlertText.watchDetail
                .text(using: localization)
        } else {
            alert.informativeText = ConnectionApprovalAlertText.phoneDetail
                .text(using: localization)
        }
        let codeLabel = NSTextField(labelWithString: pairingCode.map(String.init).joined(separator: " "))
        codeLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        codeLabel.alignment = .center
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        codeLabel.textColor = .controlAccentColor
        codeLabel.setAccessibilityLabel(
            ConnectionApprovalAlertText
                .pairingCodeAccessibility(pairingCode: pairingCode)
                .text(using: localization)
        )
        alert.accessoryView = codeLabel
        alert.addButton(withTitle: ConnectionApprovalAlertText.allow.text(using: localization))
        alert.addButton(withTitle: ConnectionApprovalAlertText.deny.text(using: localization))
        alert.addButton(
            withTitle: ConnectionApprovalAlertText.stopWaiting.text(using: localization)
        )
        phoneApprovalAlert = alert
        let response = alert.runModal()
        guard phoneApprovalAlert === alert else {
            completion(false)
            return
        }
        phoneApprovalAlert = nil
        if response == .alertThirdButtonReturn {
            completion(false)
            disablePhoneRemoteConnection()
            return
        }
        let allowed = response == .alertFirstButtonReturn
        if allowed, let identityFingerprint {
            settings.trustPhoneIdentity(identityFingerprint)
        }
        completion(allowed)
    }

    private func cancelPhoneApproval() {
        guard let alert = phoneApprovalAlert else { return }
        phoneApprovalAlert = nil
        NSApp.abortModal()
        alert.window.orderOut(nil)
    }

    /// Callers hop at the transport boundary, so this runs on the main actor already.
    private func requestWebApproval(
        deviceName: String,
        pairingCode: String,
        completion: @escaping (Bool) -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let localization = LocalizationStore(settings: settings)
        let alert = NSAlert()
        alert.messageText = ConnectionApprovalAlertText
            .webTitle(deviceName: deviceName)
            .text(using: localization)
        alert.informativeText = ConnectionApprovalAlertText.webDetail
            .text(using: localization)
        let codeLabel = NSTextField(
            labelWithString: pairingCode.map(String.init).joined(separator: " ")
        )
        codeLabel.frame = NSRect(x: 0, y: 0, width: 300, height: 44)
        codeLabel.alignment = .center
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        codeLabel.textColor = .controlAccentColor
        codeLabel.setAccessibilityLabel(
            ConnectionApprovalAlertText
                .pairingCodeAccessibility(pairingCode: pairingCode)
                .text(using: localization)
        )
        alert.accessoryView = codeLabel
        alert.addButton(withTitle: ConnectionApprovalAlertText.allow.text(using: localization))
        alert.addButton(withTitle: ConnectionApprovalAlertText.deny.text(using: localization))
        webApprovalAlert = alert
        let allowed = alert.runModal() == .alertFirstButtonReturn
        guard webApprovalAlert === alert else {
            completion(false)
            return
        }
        webApprovalAlert = nil
        completion(allowed)
    }

    private func cancelWebApproval() {
        guard let alert = webApprovalAlert else { return }
        webApprovalAlert = nil
        NSApp.abortModal()
        alert.window.orderOut(nil)
    }

    nonisolated static func appRemoteButton(rawValue: String) -> RemoteButton? {
        RemoteButton(rawValue: rawValue)
    }

    nonisolated static func appRemoteButtonPhase(rawValue: String) -> RemoteButtonPhase? {
        RemoteButtonPhase(rawValue: rawValue)
    }

    nonisolated static func isAppleWatchDeviceName(_ deviceName: String) -> Bool {
        deviceName.range(of: "watch", options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func performPhoneCommand(
        _ button: RemoteButton,
        source: UsageEventSource
    ) -> Bool {
        performMobileConfiguredAction(for: button, trigger: .singleClick, source: source)
    }

    private func handleMobileButtonEvent(
        _ button: RemoteButton,
        phase: RemoteButtonPhase,
        source: UsageEventSource
    ) -> Bool {
        if macroFeature.isEditorActive {
            if phase == .press {
                macroFeature.noteButtonInteraction(button: button)
            }
            return true
        }
        let profileID = settings.selectedRemoteProfileID
        let recognizesDoubleClick = settings.configuredAction(
            for: button,
            trigger: .doubleClick
        ).action != .disabled || macroFeature.hasActiveBinding(
            profileID: profileID,
            button: button,
            trigger: .doubleClick
        )
        let recognizesLongPress = settings.configuredAction(
            for: button,
            trigger: .longPress
        ).action != .disabled || macroFeature.hasActiveBinding(
            profileID: profileID,
            button: button,
            trigger: .longPress
        )

        var recognizer = mobileButtonGestureRecognizers[source] ?? RemoteButtonGestureRecognizer()
        if phase == .press,
           !recognizesDoubleClick,
           !recognizesLongPress,
           !recognizer.isTracking(button) {
            return performMobileConfiguredAction(
                for: button,
                trigger: .singleClick,
                source: source
            )
        }

        let commands = recognizer.handle(
            phase,
            button: button,
            recognizesDoubleClick: recognizesDoubleClick,
            recognizesLongPress: recognizesLongPress
        )
        mobileButtonGestureRecognizers[source] = recognizer
        return processMobileGestureCommands(commands, source: source)
    }

    private func processMobileGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command],
        source: UsageEventSource
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleMobileDoubleClickTimeout(for: button, source: source)
            case let .cancelDoubleClickTimeout(button):
                mobileDoubleClickTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .scheduleLongPressTimeout(button):
                scheduleMobileLongPressTimeout(for: button, source: source)
            case let .cancelLongPressTimeout(button):
                mobileLongPressTimers.removeValue(forKey: .init(
                    source: source,
                    button: button
                ))?.cancel()
            case let .trigger(button, trigger):
                guard performMobileConfiguredAction(
                    for: button,
                    trigger: trigger,
                    source: source
                ) else { return false }
            }
        }
        return true
    }

    private func scheduleMobileDoubleClickTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = MobileButtonGestureKey(source: source, button: button)
        mobileDoubleClickTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            mobileDoubleClickTimers.removeValue(forKey: key)
            guard var recognizer = mobileButtonGestureRecognizers[source] else { return }
            let commands = recognizer.doubleClickTimedOut(button)
            mobileButtonGestureRecognizers[source] = recognizer
            _ = processMobileGestureCommands(commands, source: source)
        }
        mobileDoubleClickTimers[key] = timer
        timer.resume()
    }

    private func scheduleMobileLongPressTimeout(
        for button: RemoteButton,
        source: UsageEventSource
    ) {
        let key = MobileButtonGestureKey(source: source, button: button)
        mobileLongPressTimers.removeValue(forKey: key)?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(550))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            mobileLongPressTimers.removeValue(forKey: key)
            guard var recognizer = mobileButtonGestureRecognizers[source] else { return }
            let commands = recognizer.longPressTimedOut(button)
            mobileButtonGestureRecognizers[source] = recognizer
            _ = processMobileGestureCommands(commands, source: source)
        }
        mobileLongPressTimers[key] = timer
        timer.resume()
    }

    private func resetMobileButtonGestures(source: UsageEventSource) {
        let doubleClickKeys = mobileDoubleClickTimers.keys.filter { $0.source == source }
        doubleClickKeys.forEach {
            mobileDoubleClickTimers.removeValue(forKey: $0)?.cancel()
        }
        let longPressKeys = mobileLongPressTimers.keys.filter { $0.source == source }
        longPressKeys.forEach {
            mobileLongPressTimers.removeValue(forKey: $0)?.cancel()
        }
        mobileButtonGestureRecognizers.removeValue(forKey: source)
    }

    private func performMobileConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        source: UsageEventSource
    ) -> Bool {
        if macroFeature.executeBoundMacro(
            profileID: settings.selectedRemoteProfileID,
            button: button,
            trigger: trigger
        ) {
            settings.recordButtonPress(control: .remoteButton(button), source: source)
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) action=private_feature"
            )
            return true
        }
        let configured = settings.configuredAction(for: button, trigger: trigger)
        if configured.action.isAppInternal {
            let handled = performInternalAction(configured.action)
            if handled {
                settings.recordButtonPress(control: .remoteButton(button), source: source)
            }
            AppLogger.shared.write(
                "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue) handled=\(handled)"
            )
            return handled
        }
        guard KeyboardInjector.isAccessibilityTrusted else {
            _ = KeyboardInjector.requestAccessibilityAccess()
            return false
        }
        guard performExternalConfiguredAction(configured) else {
            return false
        }
        settings.recordButtonPress(control: .remoteButton(button), source: source)
        AppLogger.shared.write(
            "PHONE REMOTE button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                "action=\(configured.action.rawValue)"
        )
        return true
    }

    private func performExternalConfiguredAction(_ configured: ConfiguredButtonAction) -> Bool {
        let applicationProfile = settings.customApplicationProfile(
            id: configured.applicationProfileID
        )
        let requestID = settings.voiceFnTapModeEnabled
            ? VoiceInputDestinationIntent.resolve(
                configured: configured,
                applicationProfile: applicationProfile
            ).map { voiceInputDestinationCoordinator.beginTargetSwitch(intent: $0) }
            : nil
        let handled = KeyboardInjector.send(
            configured.action,
            shortcut: configured.shortcut,
            applicationProfile: applicationProfile
        )
        if !handled, let requestID {
            voiceInputDestinationCoordinator.cancel(requestID: requestID, reason: .actionFailed)
        }
        return handled
    }

    private func handleVoiceInputDestinationState(_ state: VoiceInputDestinationState) {
        guard settings.voiceFnTapModeEnabled else { return }
        switch state {
        case .waiting:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.waiting_for_input")
        case .ready:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_ready")
        case .cancelled:
            voiceShortcutStatus = LocalizedMessage("voice_button.status.input_unavailable")
        }
    }

    @discardableResult
    private func performInternalAction(_ action: ButtonAction) -> Bool {
        guard action == .toggleLongRecording else { return false }
        guard action.isEnabled(
            experimentalContinuousRecordingEnabled: settings.experimentalContinuousRecordingEnabled
        ) else {
            AppLogger.shared.write("LONG RECORDING ignored feature_enabled=false")
            return false
        }
        return toggleLongRecording()
    }

    private func toggleLongRecording() -> Bool {
        if longRecordingRequested {
            stopLongRecording(reason: "button_toggle")
            return true
        }
        guard isConnected,
              isAudioOutputReady,
              !bluetoothVoiceActive,
              activeMobileVoiceSource == nil
        else {
            AppLogger.shared.write(
                "LONG RECORDING rejected connected=\(isConnected) audio_ready=\(isAudioOutputReady) " +
                    "bluetooth_voice=\(bluetoothVoiceActive) mobile_voice=\(activeMobileVoiceSource != nil)"
            )
            return false
        }

        longRecordingGeneration &+= 1
        let generation = longRecordingGeneration
        longRecordingRequested = true
        guard let selectedBluetoothBridge,
              selectedBluetoothBridge.requestMicrophoneOpen()
        else {
            finishLongRecording(reason: "open_rejected")
            return false
        }
        scheduleLongRecordingOpenTimeout(generation: generation)
        AppLogger.shared.write("LONG RECORDING opening generation=\(generation)")
        return true
    }

    private func scheduleLongRecordingOpenTimeout(generation: UInt64) {
        longRecordingOpenTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingOpenTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingRequested,
                  self.longRecordingGeneration == generation,
                  !self.bluetoothVoiceActive
            else { return }
            self.stopLongRecording(reason: "open_timeout")
        }
        longRecordingOpenTimer = timer
        timer.resume()
    }

    private func stopLongRecording(reason: String) {
        guard longRecordingRequested else { return }
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        let closeWritten = selectedBluetoothBridge?.requestMicrophoneClose() ?? false
        if bluetoothVoiceActive {
            scheduleLongRecordingCloseTimeout(generation: longRecordingGeneration)
        }
        AppLogger.shared.write(
            "LONG RECORDING stopping reason=\(reason) close_written=\(closeWritten)"
        )
    }

    private func scheduleLongRecordingCloseTimeout(generation: UInt64) {
        longRecordingCloseTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.longRecordingCloseTimeout)
        timer.setEventHandler { [weak self] in
            guard let self,
                  self.longRecordingGeneration == generation,
                  !self.longRecordingRequested,
                  self.bluetoothVoiceActive
            else { return }
            self.longRecordingCloseTimer = nil
            AppLogger.shared.write("LONG RECORDING close_timeout reconnecting=true")
            self.selectedBluetoothBridge?.reconnectNow()
        }
        longRecordingCloseTimer = timer
        timer.resume()
    }

    private func finishLongRecording(reason: String) {
        longRecordingRequested = false
        longRecordingGeneration &+= 1
        cancelLongRecordingTimers()
        AppLogger.shared.write("LONG RECORDING finished reason=\(reason)")
    }

    private func cancelLongRecordingTimers() {
        longRecordingOpenTimer?.cancel()
        longRecordingOpenTimer = nil
        longRecordingCloseTimer?.cancel()
        longRecordingCloseTimer = nil
    }

    /// Claims the single mobile voice channel for `source`, or reports why it cannot.
    ///
    /// Internal for test access. A test may only call this with the channel already held:
    /// the `.busy` arbitration below is the first gate, so a rejected request touches
    /// neither the audio device nor the voice key, while an admitted one would bind the
    /// virtual device and latch a real modifier.
    func startPhoneVoice(source: MobileVoiceSource) -> RemoteVoiceStartResult {
        guard activeMobileVoiceSource == nil else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=busy requested=\(source.logName) " +
                    "active=\(activeMobileVoiceSource?.logName ?? "none")"
            )
            return .busy
        }
        guard isAudioOutputReady || configureVirtualAudioOutput(reason: "mobile_voice_start") else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=audio_output requested=\(source.logName)"
            )
            releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_configure_failed")
            return .unavailable
        }
        guard updatePhoneVoiceFunctionKeyState(streaming: true) else {
            AppLogger.shared.write(
                "MOBILE VOICE start_rejected reason=function_key requested=\(source.logName)"
            )
            releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_function_key_failed")
            return .unavailable
        }
        activeMobileVoiceSource = source
        mobileVoiceAudioBatchCount = 0
        mobileVoiceAudioEnqueueFailureCount = 0
        mobileVoiceAudioSourceMismatchCount = 0
        mobileVoiceAudioSignalMetrics = WatchBluetoothAudioSignalMetrics()
        beginVoiceSessionIfNeeded()
        AppLogger.shared.write("MOBILE VOICE started source=\(source.logName)")
        return .started
    }

    /// Releases the mobile voice channel, but only for the source that holds it. Internal
    /// for test access.
    func stopPhoneVoice(source: MobileVoiceSource) {
        guard activeMobileVoiceSource == source else {
            AppLogger.shared.write(
                "MOBILE VOICE stop_ignored requested=\(source.logName) " +
                    "active=\(activeMobileVoiceSource?.logName ?? "none")"
            )
            return
        }
        logMobileVoiceAudioSummary(source: source, reason: "voice_stop")
        audioOutput.endSessionAfterDraining { [weak self] in
            guard let self, self.activeMobileVoiceSource == source else { return }
            self.activeMobileVoiceSource = nil
            self.updatePhoneVoiceFunctionKeyState(streaming: false)
            self.endVoiceSessionIfNeeded()
            self.releaseVirtualAudioOutputIfUnused(reason: "mobile_voice_stopped")
            AppLogger.shared.write("MOBILE VOICE stopped source=\(source.logName)")
        }
    }

    private var readyBluetoothBridgeCount: Int {
        bluetoothBridgeStates.values.reduce(into: 0) { count, state in
            if case .ready = state {
                count += 1
            }
        }
    }

    private var shouldKeepVirtualAudioActive: Bool {
        VirtualAudioConnectionLifecyclePolicy.shouldBeActive(
            readyBluetoothBridgeCount: readyBluetoothBridgeCount,
            mobileVoiceActive: activeMobileVoiceSource != nil,
            testToneActive: isPlayingTestTone
        )
    }

    private var selectedAudioDeviceIsAvailable: Bool {
        let selectedUID = settings.selectedAudioDeviceUID
        return !selectedUID.isEmpty && audioDevices.contains { $0.uid == selectedUID }
    }

    /// Mirrors the guards inside `switchDefaultInputToFallbackIfNeeded`, so the release
    /// gate can tell whether skipping that call would drop real cleanup work.
    private var defaultInputFallbackWouldRun: Bool {
        guard managedDefaultInputTransition == nil else { return false }
        let selectedUID = settings.selectedAudioDeviceUID
        guard !selectedUID.isEmpty else { return false }
        return CoreAudioDeviceCatalog.defaultInputDevice()?.uid == selectedUID
    }

    /// True when every effect of a release has already happened. The cheap in-memory
    /// facts are evaluated first: in the pathological bluetooth reconnect loop they all
    /// hold, so at most one CoreAudio property read happens per call instead of the ~9
    /// that `diagnosticState()` performs for the diagnostic line.
    private var virtualAudioReleaseHasNothingToDo: Bool {
        VirtualAudioReleaseGate.hasNothingToRelease(
            engineHoldsDevice: audioOutput.selectedDevice != nil,
            pendingVoiceBufferCount: audioOutput.pendingVoiceBufferCountForDiagnostics,
            publishedAudioReady: isAudioOutputReady,
            publishedStatusAlreadyReleased: testToneStatus == Self.releasedTestToneStatus,
            defaultInputFallbackWouldRun: { [self] in defaultInputFallbackWouldRun }
        )
    }

    private static let releasedTestToneStatus = LocalizedMessage("audio.output.none_or_unavailable")

    private func releaseVirtualAudioOutputIfUnused(reason: String) {
        guard !shouldKeepVirtualAudioActive else {
            AppLogger.shared.write(
                "AUDIO RELEASE skipped reason=\(reason) still_required=true",
                foldKey: "AUDIO RELEASE skipped reason=\(reason)"
            )
            return
        }
        // Idempotence gate: the engine is already gone, nothing is queued, the published
        // state already reflects a released output and the default-input fallback would
        // be a no-op. Running the teardown again would only emit the diagnostic line.
        guard !virtualAudioReleaseHasNothingToDo else { return }
        virtualAudioReleaseGeneration &+= 1
        let generation = virtualAudioReleaseGeneration
        switchDefaultInputToFallbackIfNeeded(reason: reason)
        audioOutput.endSessionAfterDraining { [weak self] in
            guard let self,
                  self.virtualAudioReleaseGeneration == generation,
                  !self.shouldKeepVirtualAudioActive
            else { return }
            self.audioOutput.stop()
            self.isAudioOutputReady = false
            self.testToneStatus = Self.releasedTestToneStatus
            AppLogger.shared.write(
                "AUDIO RELEASE completed reason=\(reason) state={\(self.audioOutput.diagnosticState())}",
                foldKey: "AUDIO RELEASE completed reason=\(reason)"
            )
        }
    }

    private func switchDefaultInputToFallbackIfNeeded(reason: String) {
        guard managedDefaultInputTransition == nil else { return }
        let selectedUID = settings.selectedAudioDeviceUID
        guard !selectedUID.isEmpty,
              CoreAudioDeviceCatalog.defaultInputDevice()?.uid == selectedUID
        else { return }
        guard let fallback = CoreAudioDeviceCatalog.preferredFallbackInput(excludingUID: selectedUID) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) no_candidate")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(fallback)
        guard result == noErr else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT fallback_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))} error=\(result)"
            )
            return
        }
        managedDefaultInputTransition = ManagedDefaultInputTransition(
            virtualUID: selectedUID,
            fallbackUID: fallback.uid
        )
        AppLogger.shared.write(
            "AUDIO DEFAULT_INPUT fallback_applied reason=\(reason) " +
                "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(fallback))}"
        )
    }

    private func restoreManagedDefaultInputIfAppropriate(reason: String) {
        guard let transition = managedDefaultInputTransition else { return }
        let currentDefault = CoreAudioDeviceCatalog.defaultInputDevice()
        guard DefaultInputFallbackPolicy.shouldRestoreVirtualInput(
            managedVirtualUID: transition.virtualUID,
            selectedVirtualUID: settings.selectedAudioDeviceUID,
            managedFallbackUID: transition.fallbackUID,
            currentDefaultUID: currentDefault?.uid
        ) else {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_skipped reason=\(reason) current={\(CoreAudioDeviceCatalog.deviceDiagnostic(currentDefault))}"
            )
            return
        }
        guard let virtualInput = CoreAudioDeviceCatalog.inputDevices().first(where: {
            $0.uid == transition.virtualUID
        }) else {
            AppLogger.shared.write("AUDIO DEFAULT_INPUT restore_failed reason=\(reason) virtual_unavailable")
            return
        }
        let result = CoreAudioDeviceCatalog.setDefaultInputDevice(virtualInput)
        if result == noErr {
            managedDefaultInputTransition = nil
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_applied reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))}"
            )
        } else {
            AppLogger.shared.write(
                "AUDIO DEFAULT_INPUT restore_failed reason=\(reason) " +
                    "target={\(CoreAudioDeviceCatalog.deviceDiagnostic(virtualInput))} error=\(result)"
            )
        }
    }

    /// Accepts audio only from the source that holds the channel. Internal for test access.
    func receivePhoneAudio(_ samples: [Int16], source: MobileVoiceSource) {
        guard activeMobileVoiceSource == source else {
            mobileVoiceAudioSourceMismatchCount += 1
            if mobileVoiceAudioSourceMismatchCount == 1 ||
                mobileVoiceAudioSourceMismatchCount.isMultiple(of: 20) {
                AppLogger.shared.write(
                    "MOBILE VOICE audio_dropped reason=source_mismatch requested=\(source.logName) " +
                        "active=\(activeMobileVoiceSource?.logName ?? "none") " +
                        "count=\(mobileVoiceAudioSourceMismatchCount)"
                )
            }
            return
        }
        mobileVoiceAudioBatchCount += 1
        mobileVoiceAudioSignalMetrics.append(samples)
        let accepted = audioOutput.enqueue(samples: samples)
        if !accepted { mobileVoiceAudioEnqueueFailureCount += 1 }
        if mobileVoiceAudioBatchCount == 1 || mobileVoiceAudioBatchCount.isMultiple(of: 20) {
            AppLogger.shared.write(
                "MOBILE VOICE audio source=\(source.logName) batches=\(mobileVoiceAudioBatchCount) " +
                    "samples=\(mobileVoiceAudioSignalMetrics.sampleCount) " +
                    "nonzero=\(mobileVoiceAudioSignalMetrics.nonZeroSampleCount) " +
                    "peak=\(mobileVoiceAudioSignalMetrics.peak) rms=\(mobileVoiceAudioSignalMetrics.rms) " +
                    "accepted=\(accepted) enqueue_failures=\(mobileVoiceAudioEnqueueFailureCount) " +
                    "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
            )
        }
    }

    private func logMobileVoiceAudioSummary(source: MobileVoiceSource, reason: String) {
        AppLogger.shared.write(
            "MOBILE VOICE audio_summary source=\(source.logName) reason=\(reason) " +
                "batches=\(mobileVoiceAudioBatchCount) " +
                "samples=\(mobileVoiceAudioSignalMetrics.sampleCount) " +
                "nonzero=\(mobileVoiceAudioSignalMetrics.nonZeroSampleCount) " +
                "peak=\(mobileVoiceAudioSignalMetrics.peak) rms=\(mobileVoiceAudioSignalMetrics.rms) " +
                "enqueue_failures=\(mobileVoiceAudioEnqueueFailureCount) " +
                "source_mismatches=\(mobileVoiceAudioSourceMismatchCount) " +
                "pending_buffers=\(audioOutput.pendingVoiceBufferCountForDiagnostics)"
        )
    }

    private func beginVoiceSessionIfNeeded() {
        guard !isStreaming else { return }
        privateFeature.startVoiceSession()
        cancelTestToneIfNeeded(
            statusMessage: LocalizedMessage("audio.test_tone.blocked_voice_active"),
            logReason: "voice_start"
        )
        let startedAt = Date()
        let source = currentVoiceUsageSource
        settings.recordButtonPress(control: .voice, source: source, at: startedAt)
        voiceSessionStartedAt = startedAt
        voiceSessionUsageSource = source
        isStreaming = true
    }

    private func endVoiceSessionIfNeeded(flushAudio: Bool = true) {
        guard !bluetoothVoiceActive, activeMobileVoiceSource == nil, isStreaming else { return }
        if let voiceSessionStartedAt {
            let endedAt = Date()
            settings.recordVoiceDuration(
                endedAt.timeIntervalSince(voiceSessionStartedAt),
                startedAt: voiceSessionStartedAt,
                source: voiceSessionUsageSource ?? .unknown,
                at: endedAt
            )
            self.voiceSessionStartedAt = nil
        }
        voiceSessionUsageSource = nil
        isStreaming = false
        if flushAudio {
            audioOutput.endSession()
        }
        privateFeature.finishVoiceSession()
    }

    private var currentVoiceUsageSource: UsageEventSource {
        if bluetoothVoiceActive { return .bluetoothRemote }
        switch activeMobileVoiceSource {
        case .nearbyPhone, .nearbyWatch: return .nearbyPhone
        case .web: return .webRemote
        case nil: return .unknown
        }
    }

    @discardableResult
    private func applyVoiceFunctionMapping(neutralizeVoiceKey: Bool) -> Bool {
        let applied = voiceFunctionMapper.apply(
            suppressPowerKey: settings.customMappingEnabled,
            neutralizeVoiceKey: neutralizeVoiceKey,
            trigger: settings.voiceTriggerKey
        )
        if !isStreaming {
            isVoiceTriggerEnabled = applied
            voiceShortcutStatus = LocalizedMessage(
                applied ? "voice_button.status.fn_enabled" : "voice_button.status.waiting"
            )
        }
        return !settings.customMappingEnabled || voiceFunctionMapper.isPowerKeySuppressed
    }

    @discardableResult
    private func updatePhoneVoiceFunctionKeyState(streaming: Bool) -> Bool {
        guard let transition = phoneVoiceFunctionKeyLatch.transition(streaming: streaming) else {
            return true
        }
        let shouldHold = transition == .press
        guard KeyboardInjector.setFunctionKeyPressed(
            shouldHold,
            trigger: settings.voiceTriggerKey
        ) else {
            phoneVoiceFunctionKeyLatch.rollback(transition)
            AppLogger.shared.write(
                "PHONE VOICE FN \(shouldHold ? "DOWN" : "UP") failed"
            )
            return false
        }
        isVoiceTriggerEnabled = !shouldHold
        voiceShortcutStatus = LocalizedMessage(
            shouldHold ? "voice_button.status.fn_pressed" : "voice_button.status.fn_released"
        )
        AppLogger.shared.write(
            "PHONE VOICE FN \(shouldHold ? "DOWN" : "UP")"
        )
        return true
    }

    @discardableResult
    private func updateBluetoothVoiceTriggerKey(streaming: Bool) -> Bool {
        guard VoiceKeyModePolicy.usesModifierHoldInjection(trigger: settings.voiceTriggerKey) else {
            return true
        }
        guard let transition = bluetoothVoiceTriggerLatch.transition(streaming: streaming) else {
            return true
        }
        let shouldHold = transition == .press
        guard KeyboardInjector.setFunctionKeyPressed(
            shouldHold,
            trigger: settings.voiceTriggerKey
        ) else {
            bluetoothVoiceTriggerLatch.rollback(transition)
            AppLogger.shared.write(
                "VOICE TRIGGER INJECT \(shouldHold ? "DOWN" : "UP") failed " +
                    "key=\(settings.voiceTriggerKey.rawValue)"
            )
            return false
        }
        AppLogger.shared.write(
            "VOICE TRIGGER INJECT \(shouldHold ? "DOWN" : "UP") key=\(settings.voiceTriggerKey.rawValue)"
        )
        return true
    }
}
