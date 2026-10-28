import Foundation
import CoreBluetooth

/// Connects to the lock and sends encrypted open/close commands (Phase 2).
/// Reads the live counter/encVer from the lock's status frames and builds the
/// command packet with LinkaCrypto, then writes it to the data-RX characteristic.
@MainActor
final class BLEController: NSObject, ObservableObject {

    @Published private(set) var state = "idle"
    @Published private(set) var ready = false        // connected + write char found
    @Published private(set) var encVer: Int?
    @Published private(set) var counter: UInt32?
    @Published private(set) var log: [String] = []

    // Config (set before connecting)
    private var masterKey: [UInt8] = []
    private var mac: [UInt8] = []
    private var priv: LinkaCrypto.Priv = .admin
    private var nameHint: String?
    var slot = 0            // 0 = SLOT1 (adjustable while iterating)
    var counterOffset: Int = 0   // try +0 / +1 while iterating

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse

    func configure(keyHex: String, admin: Bool, serial: String, nameHint: String?) {
        masterKey = LinkaCrypto.hex(keyHex)
        mac = LinkaCrypto.macBytes(serial) ?? []
        priv = admin ? .admin : .user
        self.nameHint = nameHint
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private func add(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 200 { log.removeLast() }
    }

    func start() {
        guard masterKey.count == 16, mac.count == 6 else {
            add("Config onvolledig (key \(masterKey.count)B, mac \(mac.count)B)."); return
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
        guard ready, let ch = writeChar, let c = counter, let ev = encVer else {
            add("Niet klaar (geen statusframe/teller ontvangen)."); return
        }
        let useCounter = UInt32(Int(c) + counterOffset)
        let frame = LinkaCrypto.commandFrame(
            mac: mac, payload: [cmd, 0], masterKey: masterKey,
            priv: priv, slot: slot, encVer: ev, counter: useCounter)
        add("→ \(name) (ctr \(useCounter), encVer \(ev), slot \(slot)): \(LinkaCrypto.toHex(frame))")
        peripheral?.writeValue(Data(frame), for: ch, type: writeType)
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
            let lock = name.lowercased().contains("linka") || name.lowercased().contains("leo")
            let match = hint.map { name.lowercased().contains($0) } ?? false
            if (match || lock), state == "scannen" {
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
                if c.uuid == LinkaBLE.dataRX {           // D31E0002 — write commands here
                    writeChar = c
                    writeType = c.properties.contains(.write) ? .withResponse : .withoutResponse
                }
                if c.uuid == LinkaBLE.dataTX || c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)   // status frames
                }
            }
            ready = (writeChar != nil)
            state = ready ? "klaar" : "verbonden (geen write-char)"
            add(ready ? "Klaar. Wacht op statusframe voor teller…" : "Geen write-characteristic gevonden.")
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = [UInt8](characteristic.value ?? Data())
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == LinkaBLE.dataTX, let parsed = LinkaCrypto.parseStatus(data) {
                encVer = parsed.encVer
                counter = parsed.counter
                add("status: encVer \(parsed.encVer), teller \(parsed.counter)  [\(LinkaCrypto.toHex(data))]")
            } else {
                add("← \(uuid.uuidString.prefix(8)): \(LinkaCrypto.toHex(data))")
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in add(error == nil ? "✓ commando geschreven" : "✗ schrijven mislukt: \(error!.localizedDescription)") }
    }
}
