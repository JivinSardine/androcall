import CoreBluetooth
import Foundation
import AndroCallCore

/// The CoreBluetooth central that talks to the Android companion.
///
/// The Mac is the GATT **client**; the phone runs the GATT server. This class
/// implements the `Transport` protocol so the protocol layer never talks to
/// CoreBluetooth directly.
public final class BluetoothManager: NSObject, Transport {

    // MARK: - Transport

    public var onFrame: ((Data) -> Void)?
    public var onStateChange: ((TransportState) -> Void)?

    public var maximumPayloadSize: Int {
        guard let peripheral = connectedPeripheral else { return 23 }
        return peripheral.maximumWriteValueLength(for: .withResponse)
    }

    public var peerName: String? {
        connectedPeripheral?.name ?? discoveredPeripheral?.name
    }

    // MARK: - Discovery

    /// A phone discovered while scanning.
    public struct DiscoveredDevice: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int

        public var displayName: String {
            name.isEmpty ? "Unknown Android phone" : name
        }
    }

    @Published public private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published public private(set) var bluetoothState: CBManagerState = .unknown
    @Published public private(set) var connectedDeviceName: String?
    @Published public private(set) var signalStrength: Int?

    /// The reason the connection ended, shown to the user.
    @Published public private(set) var lastDisconnectReason: String?

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var discoveredPeripheral: CBPeripheral?

    private var controlCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private var bulkCharacteristic: CBCharacteristic?

    private let queue = DispatchQueue(label: "dev.androcall.bluetooth")
    private var isScanning = false
    private var shouldReconnect = false

    /// Bulk flow control: the number of frames the peer may still have in flight.
    private var bulkWindow = ProtocolConstants.bulkWindow
    private var pendingBulkSends: [Data] = []
    private var pendingBulkTimer: Timer?

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [
            CBCentralManagerOptionShowPowerAlertKey: false,
        ])
    }

    // MARK: - Transport implementation

    public func start() {
        queue.async {
            self.shouldReconnect = true
            self.scan()
        }
    }

    public func stop() {
        queue.async {
            self.shouldReconnect = false
            self.stopScan()
            if let peripheral = self.connectedPeripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    public func send(_ data: Data) throws {
        try queue.sync {
            guard let peripheral = connectedPeripheral,
                  let characteristic = controlCharacteristic else {
                throw TransportError.notConnected
            }
            guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                throw TransportError.payloadTooLarge(maximum: peripheral.maximumWriteValueLength(for: .withResponse))
            }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    /// Send a frame on the bulk characteristic (used for large payloads).
    func sendBulk(_ data: Data) throws {
        try queue.sync {
            guard let peripheral = connectedPeripheral,
                  let characteristic = bulkCharacteristic else {
                throw TransportError.notConnected
            }
            guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
                throw TransportError.payloadTooLarge(maximum: peripheral.maximumWriteValueLength(for: .withResponse))
            }
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    /// Ask the phone to acknowledge outstanding bulk frames.
    func acknowledgeBulk(_ count: Int) {
        bulkWindow = min(ProtocolConstants.bulkWindow, bulkWindow + count)
    }

    // MARK: - Scanning

    private func scan() {
        guard central.state == .poweredOn else { return }
        guard !isScanning else { return }
        isScanning = true
        central.scanForPeripherals(
            withServices: [GATTIdentifiers.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DiagnosticsLog.shared.log("Scanning for androcall companions")
    }

    private func stopScan() {
        guard isScanning else { return }
        isScanning = false
        central.stopScan()
    }

    /// Connect to a discovered phone.
    public func connect(to device: DiscoveredDevice) {
        queue.async {
            guard let peripheral = self.central
                .retrievePeripherals(withIdentifiers: [device.id])
                .first else { return }
            self.discoveredPeripheral = peripheral
            self.stopScan()
            self.central.connect(peripheral, options: nil)
        }
    }

    /// Disconnect from the current phone.
    public func disconnect() {
        queue.async {
            self.shouldReconnect = false
            if let peripheral = self.connectedPeripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    /// Forget the paired phone.
    public func forget() {
        queue.async {
            self.shouldReconnect = false
            if let peripheral = self.connectedPeripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            if let identifier = UserDefaults.standard.string(forKey: "dev.androcall.pairedDeviceIdentifier"),
               let uuid = UUID(uuidString: identifier) {
                let peripheral = self.central.retrievePeripherals(withIdentifiers: [uuid]).first
                if let peripheral = peripheral {
                    self.central.retrieveConnectedPeripherals(withServices: [GATTIdentifiers.service])
                    self.central.cancelPeripheralConnection(peripheral)
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        let reason: String
        switch central.state {
        case .poweredOn:
            reason = "Bluetooth is on"
            if shouldReconnect { scan() }
        case .poweredOff:
            reason = "Bluetooth is turned off. Turn it on in System Settings › Bluetooth."
            shouldReconnect = false
        case .unauthorized:
            reason = "androcall is not allowed to use Bluetooth. Grant the permission in System Settings › Privacy & Security › Bluetooth."
            shouldReconnect = false
        case .unsupported:
            reason = "This Mac does not support Bluetooth Low Energy."
            shouldReconnect = false
        case .resetting:
            reason = "Bluetooth is restarting."
        case .unknown:
            reason = "Bluetooth state is unknown."
        @unknown default:
            reason = "Bluetooth is unavailable."
        }
        DiagnosticsLog.shared.log(reason, level: central.state == .poweredOn ? .info : .warning)
        onStateChange?(
            central.state == .poweredOn
                ? .discovering
                : .failed(reason: reason)
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if !discoveredDevices.contains(where: { $0.id == device.id }) {
            discoveredDevices.append(device)
            DispatchQueue.main.async {
                self.discoveredDevices = self.discoveredDevices
            }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DiagnosticsLog.shared.log("Connected to \(peripheral.name ?? "the phone")")
        connectedPeripheral = peripheral
        connectedDeviceName = peripheral.name
        peripheral.delegate = self
        peripheral.discoverServices([GATTIdentifiers.service])
        DispatchQueue.main.async {
            self.connectedDeviceName = peripheral.name
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let reason = error?.localizedDescription ?? "The connection attempt failed."
        DiagnosticsLog.shared.log("Failed to connect: \(reason)", level: .error)
        lastDisconnectReason = reason
        onStateChange?(.failed(reason: reason))
        DispatchQueue.main.async { self.lastDisconnectReason = reason }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let reason = error?.localizedDescription ?? "The phone disconnected."
        DiagnosticsLog.shared.log("Disconnected: \(reason)", level: .warning)
        connectedPeripheral = nil
        controlCharacteristic = nil
        eventCharacteristic = nil
        bulkCharacteristic = nil
        lastDisconnectReason = reason
        onStateChange?(.disconnected(reason: reason))
        DispatchQueue.main.async { self.lastDisconnectReason = reason }
        if shouldReconnect {
            queue.asyncAfter(deadline: .now() + 2) { self.scan() }
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // State restoration is not used: androcall always performs a fresh
        // handshake, so a restored connection is treated as a new one.
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            DiagnosticsLog.shared.log("Service discovery failed: \(error.localizedDescription)", level: .error)
            onStateChange?(.failed(reason: "Service discovery failed: \(error.localizedDescription)"))
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == GATTIdentifiers.service }) else {
            DiagnosticsLog.shared.log("The phone does not offer the androcall service", level: .error)
            onStateChange?(.failed(reason: "This device is not an androcall companion."))
            return
        }
        peripheral.discoverCharacteristics(
            [GATTIdentifiers.control, GATTIdentifiers.event, GATTIdentifiers.bulk],
            for: service
        )
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            DiagnosticsLog.shared.log("Characteristic discovery failed: \(error.localizedDescription)", level: .error)
            onStateChange?(.failed(reason: "Characteristic discovery failed: \(error.localizedDescription)"))
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case GATTIdentifiers.control:
                controlCharacteristic = characteristic
            case GATTIdentifiers.event:
                eventCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case GATTIdentifiers.bulk:
                bulkCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        guard controlCharacteristic != nil else {
            onStateChange?(.failed(reason: "The phone does not offer the androcall control channel."))
            return
        }
        DiagnosticsLog.shared.log("androcall service ready (MTU \(peripheral.maximumWriteValueLength(for: .withResponse)))")
        onStateChange?(.connected)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            DiagnosticsLog.shared.log("Read failed: \(error.localizedDescription)", level: .warning)
            return
        }
        guard let value = characteristic.value else { return }
        onFrame?(value)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            DiagnosticsLog.shared.log("Write failed: \(error.localizedDescription)", level: .warning)
        }
    }
}
