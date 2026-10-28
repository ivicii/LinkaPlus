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
    @Published private(set) var lockStateRaw: Int?
    @Published private(set) var liveLocked: Bool?
    @Published private(set) var movementAlarmOn: Bool?
    @Published private(set) var rssi: Int?
    @Published private(set) var lastEvent: String = "–"
    @Published private(set) var commandResult: CommandResult?
    @Published private(set) var winner: String?
    @Published private(set) var testing = false
    @Published private(set) var log: [String] = []

    enum CommandResult: Equatable {
        case success(String)   // actuated
        case rejected          // wrong key/counter
        case blocked(String)   // accepted but no actuation → motion/stall
        case timeout
    }

    /// Set by the firmware ASCII log after a command.
    private var encAccepted: Bool?
    private var vstateChanged = false

    static func stateText(_ v: Int?) -> String {
        switch v {
        case 0: return "Startup"; case 1: return "Sluiten…"; case 2: return "Openen…"
        case 3: return "Dicht"; case 4: return "Open"; case 5: return "Fout"
        case 6: return "Geblokkeerd"; case 7: return "Dicht (PAC)"; case 8: return "Open (PAC)"
        default: return v.map { "onbekend (\($0))" } ?? "–"
        }
    }

    private var subkey: [UInt8] = []
    private var mac: [UInt8] = []
    private var priv: LinkaCrypto.Priv = .admin
    private var nameHint: String?
    private var allKeys: AccessKeys?

    /// 0 = D31E0002 (legacy), 1 = D31E0016 (newer V2 channel).
    var channel = 0
    var counterOffset = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var write0002: CBCharacteristic?
    private var write0016: CBCharacteristic?

    func configure(keys: AccessKeys, serial: String, nameHint: String?) {
        allKeys = keys
        mac = LinkaCrypto.macBytes(serial) ?? []
        self.nameHint = nameHint
        if let ck = keys.commandKey {
            subkey = LinkaCrypto.hex(ck.hex)
            priv = ck.admin ? .admin : .user
        }
    }

    struct KeyVariant { let name: String; let hex: String; let priv: LinkaCrypto.Priv }

    private func keyVariants() -> [KeyVariant] {
        guard let k = allKeys else { return [] }
        var out: [KeyVariant] = []
        func put(_ n: String, _ s: String?, _ p: LinkaCrypto.Priv) {
            if let s = s, !s.isEmpty { out.append(KeyVariant(name: n, hex: s, priv: p)) }
        }
        put("v2_admin2", k.v2_access_key_admin_2, .admin)
        put("v2_user2",  k.v2_access_key_user_2,  .user)
        put("admin2",    k.access_key_admin_2,    .admin)
        put("user2",     k.access_key_user_2,     .user)
        put("master2",   k.access_key_master_2,   .admin)
        put("master",    k.access_key_master,     .admin)
        return out
    }

    /// Sweeps key variants × channels × counter offsets. Sends the command that
    /// would CHANGE the current lock state and auto-detects when the lock flips —
    /// then records the winning combination and locks the Open/Sluit buttons to it.
    func autoTest() {
        guard !testing else { return }
        let variants = keyVariants()
        guard !variants.isEmpty, mac.count == 6 else { add("Auto-test: geen sleutels/mac."); return }
        testing = true
        winner = nil
        Task {
            // Detection is via the firmware log: "EncAdmin"/"EncUser" = accepted.
            // Counter must be the live context value, so only off=0 is valid.
            add("== Auto-test == stuurt een UNLOCK met elke sleutel × kanaal (live teller). Detecteert 'EncAdmin'.")
            let channels = [0, 1]
            let total = variants.count * channels.count
            var idx = 0
            outer: for v in variants {
                for ch in channels {
                    if !testing { break outer }
                    idx += 1
                    guard let c = ctxCounter else {
                        add("[\(idx)/\(total)] wacht op teller…"); try? await Task.sleep(nanoseconds: 1_200_000_000); continue
                    }
                    let chr = (ch == 1) ? write0016 : write0002
                    guard let chr = chr else { continue }
                    encAccepted = nil
                    let frame = LinkaCrypto.commandFrame(mac: mac, payload: [0, 0],
                                                         subkey: LinkaCrypto.hex(v.hex), priv: v.priv, counter: c)
                    add("[TEST \(idx)/\(total)] key=\(v.name) ch=\(ch == 1 ? "0016" : "0002") ctr=\(c)")
                    let type: CBCharacteristicWriteType = chr.properties.contains(.write) ? .withResponse : .withoutResponse
                    peripheral?.writeValue(Data(frame), for: chr, type: type)
                    // Wait for the firmware verdict (~2s).
                    for _ in 0..<8 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if encAccepted == true {
                            winner = "key=\(v.name) ch=\(ch == 1 ? "0016" : "0002")"
                            subkey = LinkaCrypto.hex(v.hex); priv = v.priv; channel = ch; counterOffset = 0
                            add("✓✓ GELUKT! \(winner!) geaccepteerd. Open/Sluit staan nu vast op deze combinatie.")
                            testing = false
                            break outer
                        }
                        if encAccepted == false { break }  // rejected, next combo
                    }
                }
            }
            if winner == nil { add("== Auto-test klaar (\(idx) pogingen), geen acceptatie gedetecteerd ==") }
            testing = false
        }
    }

    func stopTest() { testing = false }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func fullLog() -> String { log.reversed().joined(separator: "\n") }

    /// Interpret the firmware ASCII debug log.
    private func handleEvent(_ s: String) {
        if s.contains("EncAdmin") || s.contains("EncUser") {
            encAccepted = true; lastEvent = "commando geaccepteerd"
        } else if s.localizedCaseInsensitiveContains("Bad enc") {
            encAccepted = false; lastEvent = "geweigerd (sleutel/teller)"
        } else if s.contains("VState Change") {
            vstateChanged = true; lastEvent = "slotstand gewijzigd"
        } else if s.localizedCaseInsensitiveContains("stall") {
            lastEvent = "geblokkeerd / beweging (stall)"
        } else if s.contains("Motor Open") || s.contains("Motor Close") {
            lastEvent = s
        }
    }

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
        state = "gestopt"; ready = false; rssi = nil
    }

    private func startRSSIPolling() {
        Task {
            while ready, let p = peripheral {
                p.readRSSI()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// Rough distance estimate from RSSI (no UWB, so approximate).
    var estimatedMeters: Double? {
        guard let r = rssi else { return nil }
        let txPower = -59.0   // typical RSSI at 1 m
        let n = 2.5           // path-loss exponent
        return pow(10.0, (txPower - Double(r)) / (10.0 * n))
    }

    func unlock() { sendPayload([0, 0], name: "Openen", expectActuation: true) { self.liveLocked = false } }
    func lock()   { sendPayload([1, 0], name: "Sluiten", expectActuation: true) { self.liveLocked = true } }
    func sirenOn()  { sendPayload([14, 60], name: "Sirene") }
    func sirenOff() { sendPayload([20, 0], name: "Sirene uit") }
    func setPAC(_ code: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 1, value: code), name: "PAC-code instellen")
    }
    func setMovementAlarm(_ on: Bool) {
        sendPayload(LinkaCrypto.settingPayload(idx: 106, value: on ? 5 : 0),
                    name: on ? "Beweeg-alarm aan" : "Beweeg-alarm uit") { self.movementAlarmOn = on }
    }

    private func sendPayload(_ payload: [UInt8], name: String, expectActuation: Bool = false, onSuccess: (() -> Void)? = nil) {
        let ch = (channel == 1) ? write0016 : write0002
        guard let ch = ch else { add("Geen write-characteristic."); return }
        guard let c = ctxCounter else { add("Nog geen context-teller (wacht op 0x12-frame)."); return }
        let useCounter = UInt32(truncatingIfNeeded: Int(c) + counterOffset)
        let frame = LinkaCrypto.commandFrame(mac: mac, payload: payload, subkey: subkey, priv: priv, counter: useCounter)
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        encAccepted = nil; vstateChanged = false; commandResult = nil
        add("→ \(name) (ctr \(useCounter)): \(LinkaCrypto.toHex(frame))")
        peripheral?.writeValue(Data(frame), for: ch, type: type)
        Task {
            for _ in 0..<16 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if encAccepted == false { commandResult = .rejected; return }
                if expectActuation {
                    if vstateChanged { commandResult = .success(name); onSuccess?(); return }
                } else if encAccepted == true {
                    commandResult = .success(name); onSuccess?(); return
                }
            }
            if expectActuation && encAccepted == true { commandResult = .blocked(name) }
            else { commandResult = .timeout }
        }
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
            if ready { startRSSIPolling() }
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
            } else if characteristic.uuid == LinkaBLE.leoLog {
                // D31E0014 firmware debug log (ASCII) — the reliable signal.
                let s = String(bytes: data, encoding: .utf8) ?? LinkaCrypto.toHex(data)
                handleEvent(s)
                add("· \(s)")
            } else {
                add("← \(uuid.prefix(8)): \(LinkaCrypto.toHex(data))")
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in add(error == nil ? "✓ commando geschreven" : "✗ schrijven mislukt: \(error!.localizedDescription)") }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        Task { @MainActor in if error == nil { rssi = RSSI.intValue } }
    }
}
