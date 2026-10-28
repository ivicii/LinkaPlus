import Foundation
import CoreBluetooth

/// Known LINKA / LEO 2 GATT identifiers (from the original app).
enum LinkaBLE {
    static let service  = CBUUID(string: "d31e0470-416b-499b-95aa-5db239a0bfbe") // main service
    static let dataTX   = CBUUID(string: "d31e0003-416b-499b-95aa-5db239a0bfbe") // lock → app (notify/indicate)
    static let dataRX   = CBUUID(string: "d31e0002-416b-499b-95aa-5db239a0bfbe") // app → lock (write)
    static let leoLog   = CBUUID(string: "d31e0014-416b-499b-95aa-5db239a0bfbe")
    static let battery  = CBUUID(string: "4424d2f5-9f9c-4e4a-a8a0-bf2d9bf545b8") // battery (mV)
    static let uartSvc  = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") // Nordic UART
}

/// Connects to a LINKA lock and inventories its GATT profile + incoming
/// packets, so we can verify the protocol against the decompiled app before
/// building command writes (Phase 2).
@MainActor
final class BLEManager: NSObject, ObservableObject {

    enum State: String {
        case idle, poweredOff, unauthorized, scanning, connecting, discovering, connected, disconnected
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var discovered: [(name: String, rssi: Int)] = []
    @Published private(set) var log: [String] = []
    /// Service UUID → list of "charUUID  [properties]".
    @Published private(set) var profile: [String: [String]] = [:]
    @Published private(set) var lastPacketHex: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var targetName: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func add(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 120 { log.removeLast() }
    }

    func startScan(nameHint: String?) {
        targetName = nameHint
        discovered = []; profile = [:]; lastPacketHex = nil
        guard central.state == .poweredOn else {
            add("Bluetooth niet aan (\(central.state.rawValue)).")
            return
        }
        state = .scanning
        add("Scannen…")
        // Scan broadly (some locks don't advertise the 128-bit service UUID).
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        if state == .scanning { state = .idle }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        add("Verbinden met \(p.name ?? p.identifier.uuidString)…")
        central.connect(p, options: nil)
    }

    private func props(_ c: CBCharacteristic) -> String {
        var out: [String] = []
        let p = c.properties
        if p.contains(.read) { out.append("read") }
        if p.contains(.write) { out.append("write") }
        if p.contains(.writeWithoutResponse) { out.append("writeNR") }
        if p.contains(.notify) { out.append("notify") }
        if p.contains(.indicate) { out.append("indicate") }
        return out.joined(separator: ",")
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: add("Bluetooth klaar.")
            case .poweredOff: state = .poweredOff; add("Bluetooth staat uit.")
            case .unauthorized: state = .unauthorized; add("Geen Bluetooth-toestemming.")
            default: add("Bluetooth status: \(central.state.rawValue)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        Task { @MainActor in
            guard let name = advName, !name.isEmpty else { return }
            if !discovered.contains(where: { $0.name == name }) {
                discovered.append((name, RSSI.intValue))
            }
            // Auto-connect to a LINKA/LEO lock, or to the hinted name.
            let hint = targetName?.lowercased()
            let looksLikeLock = name.lowercased().contains("linka") || name.lowercased().contains("leo")
            let matchesHint = hint.map { name.lowercased().contains($0) } ?? false
            if (matchesHint || looksLikeLock), state == .scanning {
                connect(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            state = .discovering
            add("Verbonden. Services ontdekken…")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in add("Verbinden mislukt: \(error?.localizedDescription ?? "?")"); state = .disconnected }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in state = .disconnected; add("Verbinding verbroken.") }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in peripheral.services ?? [] {
                profile[s.uuid.uuidString] = []
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            var lines: [String] = []
            for c in service.characteristics ?? [] {
                lines.append("\(c.uuid.uuidString)  [\(props(c))]")
                // Subscribe to the lock's status/notify channels.
                if c.uuid == LinkaBLE.dataTX || (c.properties.contains(.notify) || c.properties.contains(.indicate)) {
                    peripheral.setNotifyValue(true, for: c)
                }
                // Read static/readable values (battery, firmware).
                if c.properties.contains(.read) {
                    peripheral.readValue(for: c)
                }
            }
            profile[service.uuid.uuidString] = lines
            state = .connected
            add("Service \(service.uuid.uuidString): \(lines.count) characteristics.")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value ?? Data()
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let uuid = characteristic.uuid.uuidString
        Task { @MainActor in
            if characteristic.uuid == LinkaBLE.dataTX { lastPacketHex = hex }
            add("← \(uuid): \(hex.isEmpty ? "(leeg)" : hex)")
        }
    }
}
