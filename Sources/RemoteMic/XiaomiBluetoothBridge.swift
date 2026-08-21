import CoreBluetooth
import Foundation

enum BluetoothBridgeState: Equatable {
    case stopped
    case bluetoothUnavailable(LocalizedMessage)
    case scanning
    case connecting
    case discovering
    case ready(String)
    case reconnecting
    case failed(LocalizedMessage)

    var message: LocalizedMessage {
        switch self {
        case .stopped: return LocalizedMessage("common.status.stopped")
        case .bluetoothUnavailable(let reason): return reason
        case .scanning: return LocalizedMessage("connection.status.searching")
        case .connecting: return LocalizedMessage("connection.status.connecting")
        case .discovering: return LocalizedMessage("connection.status.initializing_voice")
        case .ready: return LocalizedMessage("connection.status.connected_to_device")
        case .reconnecting: return LocalizedMessage("connection.status.reconnecting")
        case .failed(let reason): return reason
        }
    }
}

protocol XiaomiBluetoothBridgeDelegate: AnyObject {
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didChange state: BluetoothBridgeState)
    func bluetoothBridgeDidStartVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridgeDidStopVoice(_ bridge: XiaomiBluetoothBridge)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didDecode samples: [Int16])
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdateBatteryLevel level: Int?)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didIdentifyRemoteModel model: XiaomiRemoteModel)
    func bluetoothBridge(_ bridge: XiaomiBluetoothBridge, didUpdatePowerState state: RemotePowerState?)
}

private final class XiaomiPeripheralDelegateProxy: NSObject, CBPeripheralDelegate {
    let generation: UInt64
    weak var owner: XiaomiBluetoothBridge?

    init(generation: UInt64, owner: XiaomiBluetoothBridge) {
        self.generation = generation
        self.owner = owner
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.handleDiscoveredServices(
            peripheral: peripheral,
            generation: generation,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        owner?.handleDiscoveredCharacteristics(
            peripheral: peripheral,
            generation: generation,
            service: service,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleNotificationState(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.handleCharacteristicValue(
            peripheral: peripheral,
            generation: generation,
            characteristic: characteristic,
            error: error
        )
    }
}

final class XiaomiBluetoothBridge: NSObject {
    private let settings: AppSettings
    private weak var delegate: XiaomiBluetoothBridgeDelegate?
    private let targetIdentifier: UUID?
    private let excludedIdentifiers: () -> Set<UUID>
    private var central: CBCentralManager?
    private var centralGeneration: UInt64?
    private var peripheral: CBPeripheral?
    private var peripheralDelegateProxy: XiaomiPeripheralDelegateProxy?
    private var transmitCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var batteryStatusCharacteristic: CBCharacteristic?
    private var subscribedUUIDs = Set<CBUUID>()
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingConnectDeadlineWorkItem: DispatchWorkItem?
    private var initializationTimeoutWorkItem: DispatchWorkItem?
    private var capabilitiesRequested = false
    private var requestedReconnectDelay: TimeInterval?
    private var generationCounter: UInt64 = 0
    private var lifecycle: BluetoothLifecyclePhase = .stopped
    private var shouldRun = false
    /// Everything about the voice session itself. Kept free of CoreBluetooth so the
    /// protocol handling can be replayed by tests; this bridge is the adapter that owns
    /// the radio and applies the effects the core returns.
    private let session = ATVVVoiceSessionCore()

    private let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let batteryLevelStatusUUID = CBUUID(string: "2BED")
    private let deviceInformationServiceUUID = CBUUID(string: "180A")
    private let modelNumberUUID = CBUUID(string: "2A24")

    var deviceIdentifier: UUID? {
        peripheral?.identifier ?? targetIdentifier
    }

    private(set) var state: BluetoothBridgeState = .stopped {
        didSet {
            guard oldValue != state else { return }
            delegate?.bluetoothBridge(self, didChange: state)
        }
    }

    init(
        settings: AppSettings,
        delegate: XiaomiBluetoothBridgeDelegate,
        targetIdentifier: UUID? = nil,
        excludedIdentifiers: @escaping () -> Set<UUID> = { [] }
    ) {
        self.settings = settings
        self.delegate = delegate
        self.targetIdentifier = targetIdentifier
        self.excludedIdentifiers = excludedIdentifiers
        super.init()
    }

    func start() {
        shouldRun = true
        reconnectWorkItem?.cancel()
        beginConnectionCycle()
    }

    func stop() {
        shouldRun = false
        reconnectWorkItem?.cancel()
        central?.stopScan()
        closeMicrophoneIfNeeded()
        if let central, let peripheral, peripheral.state != .disconnected {
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
        }
        // Release synchronously rather than waiting for a disconnect callback: a request
        // that never completed may never produce one, and that would retain the central.
        finishAttempt(reconnectAfter: nil)
        resetSession()
        state = .stopped
    }

    func reconnectNow() {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()
        central?.stopScan()
        if let central, let peripheral, peripheral.state != .disconnected {
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
        }
        state = .reconnecting
        finishAttempt(reconnectAfter: 0.1)
    }

    private func beginConnectionCycle() {
        guard shouldRun, !hasConnectionCycleInFlight else { return }
        generationCounter &+= 1
        let generation = generationCounter
        lifecycle = .scanning(generation)
        // One central for the bridge's lifetime. Rebuilding it per cycle discards the
        // pending `connect()` that the Bluetooth controller would have completed on its
        // own, and misses a remote that appears while the bridge is between centrals.
        let manager = central ?? CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        central = manager
        centralGeneration = generation
        if manager.state == .poweredOn {
            discoverOrScan(using: manager, generation: generation)
        }
    }

    /// True while a cycle owns the central. This is the old `central == nil` guard
    /// restated as a phase check, now that the central outlives a single cycle:
    /// `finishAttempt` only ever leaves `.stopped` or `.waitingReconnect` behind.
    private var hasConnectionCycleInFlight: Bool {
        switch lifecycle {
        case .stopped, .waitingReconnect:
            return false
        default:
            return true
        }
    }

    /// Tears the central down. Only the stop path reaches this; every other caller keeps
    /// it so an outstanding connection request stays registered with the controller.
    private func releaseCentral() {
        central?.stopScan()
        central?.delegate = nil
        central = nil
        centralGeneration = nil
    }

    @discardableResult
    func requestMicrophoneOpen() -> Bool {
        session.requestMicrophoneOpen(phase: lifecycle) { self.write($0) }
    }

    @discardableResult
    func requestMicrophoneExtend() -> Bool {
        session.requestMicrophoneExtend { self.write($0) }
    }

    @discardableResult
    func requestMicrophoneClose() -> Bool {
        session.requestMicrophoneClose { self.write($0) }
    }

    private func discoverOrScan(using central: CBCentralManager, generation: UInt64) {
        guard shouldRun,
              self.central === central,
              lifecycle == .scanning(generation),
              central.state == .poweredOn
        else { return }
        resetPeripheral()

        if let identifier = targetIdentifier,
           let saved = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            connect(saved, using: central, generation: generation, source: "target_identifier")
            return
        }

        if targetIdentifier == nil,
           let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
            .first(where: { isCandidate($0) && !excludedIdentifiers().contains($0.identifier) }) {
            connect(connected, using: central, generation: generation, source: "connected_peripheral")
            return
        }

        state = .scanning
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        AppLogger.shared.write("BLE SCANNING")
    }

    private func connect(
        _ candidate: CBPeripheral,
        using central: CBCentralManager,
        generation: UInt64,
        source: String
    ) {
        guard shouldRun,
              self.central === central,
              peripheral == nil,
              lifecycle == .scanning(generation)
        else { return }
        central.stopScan()
        peripheral = candidate
        let proxy = XiaomiPeripheralDelegateProxy(generation: generation, owner: self)
        peripheralDelegateProxy = proxy
        candidate.delegate = proxy
        lifecycle = .connecting(generation)
        state = .connecting
        startPendingConnectDeadline(generation: generation)
        central.connect(candidate, options: nil)
        AppLogger.shared.write("BLE CONNECTING source=\(source) name=\(candidate.name ?? "unknown")")
    }

    private func isCandidate(_ candidate: CBPeripheral) -> Bool {
        XiaomiVoiceRemoteNameMatcher.matches(candidate.name)
    }

    private func resetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        peripheralDelegateProxy = nil
        transmitCharacteristic = nil
        audioCharacteristic = nil
        controlCharacteristic = nil
        batteryCharacteristic = nil
        batteryStatusCharacteristic = nil
        subscribedUUIDs.removeAll()
        pendingConnectDeadlineWorkItem?.cancel()
        pendingConnectDeadlineWorkItem = nil
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        capabilitiesRequested = false
        apply(session.resetForNewConnection())
    }

    private func isCurrent(_ candidate: CBPeripheral) -> Bool {
        guard let peripheral else { return false }
        return peripheral === candidate
    }

    private func currentGeneration() -> UInt64? {
        lifecycle.generation
    }

    private func startInitializationTimeout(generation: UInt64) {
        initializationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.currentGeneration() == generation,
                  self.lifecycle == .discovering(generation) ||
                    self.lifecycle == .awaitingCapabilities(generation)
            else { return }
            self.failInitialization(LocalizedMessage("connection.error.voice_service_timeout"))
        }
        initializationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func startPendingConnectDeadline(generation: UInt64) {
        pendingConnectDeadlineWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.currentGeneration() == generation,
                  self.lifecycle == .connecting(generation)
            else { return }
            guard let retryDelay = BluetoothReconnectPolicy
                .retryDelayAfterPendingConnectDeadline()
            else {
                // The request stays with the Bluetooth controller, which completes it
                // when the remote comes back into range. Only the label changes, and the
                // phase stays `.connecting` so that completion is still accepted.
                self.state = .reconnecting
                AppLogger.shared.write("BLE CONNECT PENDING waiting_for_remote")
                return
            }
            AppLogger.shared.write("BLE CONNECT TIMEOUT")
            self.state = .reconnecting
            if let central = self.central,
               let peripheral = self.peripheral,
               peripheral.state != .disconnected {
                central.cancelPeripheralConnection(peripheral)
            }
            self.finishAttempt(reconnectAfter: retryDelay)
        }
        pendingConnectDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BluetoothReconnectPolicy.pendingConnectDeadline,
            execute: work
        )
    }

    private func resetSession() {
        apply(session.reset())
    }

    private func scheduleReconnect(discardCachedIdentity: Bool = false) {
        guard shouldRun else { return }
        reconnectWorkItem?.cancel()
        state = .reconnecting
        if let central, let peripheral, peripheral.state != .disconnected {
            requestedReconnectDelay = BluetoothReconnectPolicy.failureRetryDelay
            lifecycle = .disconnecting(lifecycle.generation ?? generationCounter)
            central.cancelPeripheralConnection(peripheral)
            return
        }
        finishAttempt(reconnectAfter: BluetoothReconnectPolicy.failureRetryDelay)
    }

    private func finishAttempt(reconnectAfter delay: TimeInterval?) {
        let finishedGeneration = lifecycle.generation ?? generationCounter
        central?.stopScan()
        requestedReconnectDelay = nil
        resetPeripheral()

        guard shouldRun, let delay else {
            releaseCentral()
            lifecycle = .stopped
            return
        }

        state = .reconnecting
        lifecycle = .waitingReconnect(finishedGeneration)
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.shouldRun,
                  self.lifecycle == .waitingReconnect(finishedGeneration)
            else { return }
            self.beginConnectionCycle()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @discardableResult
    private func write(_ data: Data) -> Bool {
        guard let peripheral, let transmitCharacteristic else { return false }
        let type: CBCharacteristicWriteType = transmitCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        peripheral.writeValue(data, for: transmitCharacteristic, type: type)
        return true
    }

    private func closeMicrophoneIfNeeded() {
        _ = requestMicrophoneClose()
    }

    private func requestCapabilitiesIfPossible() {
        guard let generation = currentGeneration(),
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        guard transmitCharacteristic != nil,
              let audioCharacteristic,
              let controlCharacteristic,
              subscribedUUIDs.contains(audioCharacteristic.uuid),
              subscribedUUIDs.contains(controlCharacteristic.uuid),
              let peripheral
        else { return }
        guard !capabilitiesRequested else { return }
        capabilitiesRequested = true
        write(ATVVProtocol.getCapabilitiesV10)
        lifecycle = .awaitingCapabilities(generation)
        state = .discovering
        AppLogger.shared.write("ATVV CAPABILITIES requested name=\(peripheral.name ?? "MI RC")")
    }

    /// Performs, in order, what the session core decided.
    ///
    /// Order matters and mirrors what shipped before the core was extracted: the delegate
    /// hears about a stream before the matching log line is written (the delegate logs
    /// too), and `scheduleReconnect` always comes last so the teardown is visible before
    /// the connection goes away.
    private func apply(_ effects: [ATVVVoiceSessionCore.Effect]) {
        for effect in effects {
            switch effect {
            case .voiceDidStart(let sessionID, let implicitFromAudio):
                delegate?.bluetoothBridgeDidStartVoice(self)
                AppLogger.shared.write("ATVV STREAM START session=\(sessionID)")
                if implicitFromAudio {
                    AppLogger.shared.write("ATVV STREAM implicit_audio_race")
                }
            case .voiceDidStop(let sessionID):
                delegate?.bluetoothBridgeDidStopVoice(self)
                AppLogger.shared.write("ATVV STREAM STOP session=\(sessionID)")
            case .voiceDidAbort:
                delegate?.bluetoothBridgeDidStopVoice(self)
            case .decoded(let samples):
                delegate?.bluetoothBridge(self, didDecode: samples)
            case .capabilitiesAccepted:
                confirmCapabilities()
            case .failed(let message):
                state = .failed(message)
            case .scheduleReconnect:
                scheduleReconnect(discardCachedIdentity: true)
            }
        }
    }

    private func confirmCapabilities() {
        guard let generation = currentGeneration() else { return }
        initializationTimeoutWorkItem?.cancel()
        initializationTimeoutWorkItem = nil
        lifecycle = .ready(generation)
        if let peripheral {
            state = .ready(peripheral.name ?? "MI RC")
            AppLogger.shared.write("BLE READY name=\(peripheral.name ?? "MI RC")")
        }
    }

    private func failInitialization(_ message: LocalizedMessage) {
        state = .failed(message)
        session.resetDecodeState()
        scheduleReconnect(discardCachedIdentity: true)
    }
}

extension XiaomiBluetoothBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central, let generation = centralGeneration else { return }
        switch central.state {
        case .poweredOn:
            if shouldRun { discoverOrScan(using: central, generation: generation) }
        case .poweredOff:
            resetPeripheral()
            lifecycle = .scanning(generation)
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.off"))
        case .unauthorized:
            resetPeripheral()
            lifecycle = .scanning(generation)
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.permission_denied"))
        case .unsupported:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unsupported"))
        case .resetting:
            resetPeripheral()
            lifecycle = .scanning(generation)
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.resetting"))
        case .unknown:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.initializing"))
        @unknown default:
            state = .bluetoothUnavailable(LocalizedMessage("bluetooth.status.unavailable"))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.central === central else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceMatch = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .contains(serviceUUID) == true
        guard let generation = centralGeneration,
              lifecycle == .scanning(generation),
              self.peripheral == nil,
              !excludedIdentifiers().contains(peripheral.identifier),
              targetIdentifier == nil || peripheral.identifier == targetIdentifier,
              serviceMatch || isCandidate(peripheral) || XiaomiVoiceRemoteNameMatcher.matches(advertisedName)
        else { return }
        connect(peripheral, using: central, generation: generation, source: "scan")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.central === central else { return }
        guard shouldRun else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidConnect(generation: generation)
        else { return }
        pendingConnectDeadlineWorkItem?.cancel()
        pendingConnectDeadlineWorkItem = nil
        lifecycle = .discovering(generation)
        state = .discovering
        startInitializationTimeout(generation: generation)
        peripheral.discoverServices([
            serviceUUID,
            batteryServiceUUID,
            deviceInformationServiceUUID,
        ])
        AppLogger.shared.write("BLE CONNECTED name=\(peripheral.name ?? "unknown")")
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDidFailToConnect(generation: generation)
        else { return }
        AppLogger.shared.write("BLE CONNECT FAILED error=\(error?.localizedDescription ?? "unknown")")
        let delay = shouldRun ? (requestedReconnectDelay ?? BluetoothReconnectPolicy.failureRetryDelay) : nil
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        guard self.central === central,
              isCurrent(peripheral),
              let generation = centralGeneration,
              lifecycle.acceptsDisconnect(generation: generation)
        else { return }
        handleDisconnect(error: error)
    }

    private func handleDisconnect(error: Error?) {
        let shouldDiscardCachedIdentity: Bool
        switch lifecycle {
        case .connecting, .discovering, .awaitingCapabilities:
            shouldDiscardCachedIdentity = true
        default:
            shouldDiscardCachedIdentity = false
        }
        AppLogger.shared.write(
            "BLE DISCONNECTED phase=\(lifecycle) cached_identifier_cleared=\(shouldDiscardCachedIdentity) " +
                "error=\(error?.localizedDescription ?? "none")"
        )
        let delay = shouldRun ? (requestedReconnectDelay ?? BluetoothReconnectPolicy.failureRetryDelay) : nil
        finishAttempt(reconnectAfter: delay)
        if !shouldRun { state = .stopped }
    }
}

extension XiaomiBluetoothBridge {
    fileprivate func handleDiscoveredServices(
        peripheral: CBPeripheral,
        generation: UInt64,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_service_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            state = .failed(LocalizedMessage("connection.error.voice_service_missing"))
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        peripheral.discoverCharacteristics(
            [transmitUUID, audioUUID, controlUUID],
            for: service
        )
        if let batteryService = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) {
            peripheral.discoverCharacteristics(
                [batteryLevelUUID, batteryLevelStatusUUID],
                for: batteryService
            )
        }
        if let deviceInformationService = peripheral.services?.first(where: {
            $0.uuid == deviceInformationServiceUUID
        }) {
            peripheral.discoverCharacteristics([modelNumberUUID], for: deviceInformationService)
        }
    }

    fileprivate func handleDiscoveredCharacteristics(
        peripheral: CBPeripheral,
        generation: UInt64,
        service: CBService,
        error: Error?
    ) {
        let isOptionalService = service.uuid == batteryServiceUUID ||
            service.uuid == deviceInformationServiceUUID
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              isOptionalService
                ? lifecycle.acceptsNotificationUpdate(generation: generation)
                : lifecycle.acceptsInitializationCallback(generation: generation)
        else { return }
        if service.uuid == batteryServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY characteristic_discovery_failed error=\(error.localizedDescription)"
                )
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            guard let characteristics = service.characteristics else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
                return
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelUUID }) {
                batteryCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            }
            if let characteristic = characteristics.first(where: { $0.uuid == batteryLevelStatusUUID }) {
                batteryStatusCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            } else {
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            }
            return
        }
        if service.uuid == deviceInformationServiceUUID {
            if let error {
                AppLogger.shared.write(
                    "BLE MODEL characteristic_discovery_failed error=\(error.localizedDescription)"
                )
                return
            }
            guard let characteristic = service.characteristics?.first(where: { $0.uuid == modelNumberUUID }) else {
                return
            }
            peripheral.readValue(for: characteristic)
            return
        }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_discovery_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case transmitUUID:
                transmitCharacteristic = characteristic
            case audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                continue
            }
        }
        guard transmitCharacteristic != nil,
              audioCharacteristic != nil,
              controlCharacteristic != nil
        else {
            state = .failed(LocalizedMessage("connection.error.voice_channel_incomplete"))
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleNotificationState(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation,
              lifecycle.acceptsNotificationUpdate(generation: generation)
        else { return }
        let isOptionalCharacteristic = characteristic.uuid == batteryLevelUUID ||
            characteristic.uuid == batteryLevelStatusUUID
        if isOptionalCharacteristic {
            if let error {
                AppLogger.shared.write(
                    "BLE BATTERY notification_failed uuid=\(characteristic.uuid.uuidString) " +
                        "error=\(error.localizedDescription)"
                )
            }
            return
        }
        if let error {
            state = .failed(
                LocalizedMessage(
                    "connection.error.voice_channel_subscription_failed",
                    arguments: [error.localizedDescription]
                )
            )
            scheduleReconnect(discardCachedIdentity: true)
            return
        }
        guard characteristic.uuid == audioUUID || characteristic.uuid == controlUUID else {
            return
        }
        guard characteristic.isNotifying else {
            subscribedUUIDs.remove(characteristic.uuid)
            failInitialization(LocalizedMessage("connection.error.voice_channel_subscription_inactive"))
            return
        }
        subscribedUUIDs.insert(characteristic.uuid)
        requestCapabilitiesIfPossible()
    }

    fileprivate func handleCharacteristicValue(
        peripheral: CBPeripheral,
        generation: UInt64,
        characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard shouldRun,
              isCurrent(peripheral),
              currentGeneration() == generation
        else { return }
        if let error {
            if characteristic.uuid == batteryLevelUUID {
                AppLogger.shared.write("BLE BATTERY read_failed error=\(error.localizedDescription)")
                delegate?.bluetoothBridge(self, didUpdateBatteryLevel: nil)
            } else if characteristic.uuid == batteryLevelStatusUUID {
                AppLogger.shared.write("BLE POWER read_failed error=\(error.localizedDescription)")
                delegate?.bluetoothBridge(self, didUpdatePowerState: nil)
            } else if characteristic.uuid == modelNumberUUID {
                AppLogger.shared.write("BLE MODEL read_failed error=\(error.localizedDescription)")
            }
            return
        }
        guard let data = characteristic.value else { return }
        if characteristic.uuid == batteryLevelUUID {
            let level = data.first.map(Int.init)
            AppLogger.shared.write("BLE BATTERY level=\(level.map(String.init) ?? "unknown")")
            delegate?.bluetoothBridge(self, didUpdateBatteryLevel: level)
            return
        }
        if characteristic.uuid == batteryLevelStatusUUID {
            let powerState = RemotePowerState.decodeBatteryLevelStatus(data)
            AppLogger.shared.write("BLE POWER state=\(String(describing: powerState))")
            delegate?.bluetoothBridge(self, didUpdatePowerState: powerState)
            return
        }
        if characteristic.uuid == modelNumberUUID {
            guard let modelNumber = String(data: data, encoding: .utf8),
                  let model = XiaomiRemoteModel.identified(by: modelNumber)
            else {
                AppLogger.shared.write("BLE MODEL unrecognized")
                return
            }
            AppLogger.shared.write("BLE MODEL identified=\(model.rawValue)")
            delegate?.bluetoothBridge(self, didIdentifyRemoteModel: model)
            return
        }
        if characteristic.uuid == controlUUID {
            apply(session.handleControlValue(
                data,
                phase: lifecycle,
                callbackGeneration: generation,
                write: { self.write($0) }
            ))
        } else if characteristic.uuid == audioUUID {
            apply(session.handleAudioValue(
                data,
                phase: lifecycle,
                callbackGeneration: generation,
                gainDB: settings.gainDB
            ))
        }
    }
}
