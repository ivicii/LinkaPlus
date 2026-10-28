import Foundation
import CoreBluetooth

/// Phase-2 open/close over Bluetooth. Reads the live counter from the lock's
/// context frame (0x12-prefixed, encVer 2) and builds the command with the
/// access key used directly as the subkey (mirrors the app's setSubkey path).
@MainActor
final class BLEController: NSObject, ObservableObject {

    @Published private(set) var state = "idle"
    @Published private(set) var ready = false
    @Published private(set) var ctxEncVer: Int?
    @Published private(set) var ctxCounter: UInt32?
    @Published private(set) var log: [String] = []

    private var subkey: [UInt8] = []
    private var mac: [UInt8] = []
    private var priv: LinkaCrypto.Priv = .admin
    private var nameHint: String?

    /// 0 = D31E0002 (legacy), 1 = D31E0016 (newer V2 channel).
    var channel = 0
    var counterOffset = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var write0002: CBCharacteristic?
    private var write0016: CBCharacteristic?

    func configure(keyHex: String, admin: Bool, serial: String, nameHint: String?) {
        subkey = LinkaCrypto.hex(keyHex)
        mac = LinkaCrypto.macBytes(serial) ?? []
        priv = admin ? .admin : .user
        self.nameHint = nameHint
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func fullLog() -> String { log.reversed().joined(separator: "\n") }

    private func add(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 300 { log.removeLast() }
    }

    func start() {
        guard subkey.count == 16, mac.count == 6 else {
            add("Config onvolledig (key \(subkey.count)B, mac \(mac.count)B)."); return
        }
        guard central.state == .poweredOn else { add("Bluetooth niet aan."); return }
        state = "scannen"; ready = false
        add("Scannen naar slot…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        state = "gestopt"; ready = false
    }

    func unlock() { send(cmd: 0, name: "UNLOCK") }
    func lock()   { send(cmd: 1, name: "LOCK") }

    private func send(cmd: UInt8, name: String) {
        let ch = (channel == 1) ? write0016 : write0002
        guard let ch = ch else { add("Geen write-characteristic voor kanaal \(channel == 1 ? "0016" : "0002")."); return }
        guard let c = ctxCounter else { add("Nog geen context-teller ontvangen (wacht op 0x12-frame)."); return }
        let useCounter = UInt32(truncatingIfNeeded: Int(c) + counterOffset)
        let frame = LinkaCrypto.commandFrame(mac: mac, payload: [cmd, 0], subkey: subkey, priv: priv, counter: useCounter)
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        add("→ \(name) via \(channel == 1 ? "0016" : "0002") (ctr \(useCounter)): \(LinkaCrypto.toHex(frame))")
        peripheral?.writeValue(Data(frame), for: ch, type: type)
    }
}

extension BLEController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in if central.state != .poweredOn { add("BT status \(central.state.rawValue)") } }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        Task { @MainActor in
            guard let name = name else { return }
            let hint = nameHint?.lowercased()
            let isLock = name.lowercased().contains("linka") || name.lowercased().contains("leo")
            let match = hint.map { name.lowercased().contains($0) } ?? false
            if (match || isLock), state == "scannen" {
                state = "verbinden"
                self.peripheral = peripheral
                peripheral.delegate = self
                central.stopScan()
                central.connect(peripheral, options: nil)
                add("Verbinden met \(name)…")
            }
        }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in state = "services"; peripheral.discoverServices([LinkaBLE.service]) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in ready = false; state = "verbroken"; add("Verbinding verbroken.") }
    }
}

extension BLEController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in peripheral.services ?? [] where s.uuid == LinkaBLE.service {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == LinkaBLE.dataRX { write0002 = c }
                if c.uuid.uuidString.uppercased().hasPrefix("D31E0016") { write0016 = c }
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            ready = (write0002 != nil || write0016 != nil)
            state = ready ? "klaar" : "verbonden (geen write-char)"
            add(ready ? "Klaar. Wacht op context-frame (0x12)…" : "Geen write-characteristic.")
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = [UInt8](characteristic.value ?? Data())
        let uuid = characteristic.uuid.uuidString
        Task { @MainActor in
            // The command context is the 0x12-prefixed frame (encVer 2).
            if data.count >= 7, data[0] == 0x12 {
                ctxEncVer = Int(data[2])
                ctxCounter = UInt32(data[3]) | (UInt32(data[4]) << 8) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 24)
                add("CONTEXT: encVer \(ctxEncVer!), teller \(ctxCounter!)  [\(LinkaCrypto.toHex(data))]")
            } else {
                add("← \(uuid.prefix(8)): \(LinkaCrypto.toHex(data))")
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in add(error == nil ? "✓ commando geschreven" : "✗ schrijven mislukt: \(error!.localizedDescription)") }
    }
}
