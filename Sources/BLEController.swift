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

    // Live telemetry decoded from the lock's status/info packet (command 0x0A).
    @Published private(set) var infoUptime: UInt32?
    @Published private(set) var infoRSSIpkt: Int?
    @Published private(set) var accelG: SIMD3<Double>?
    @Published private(set) var infoExtra: Int?
    @Published private(set) var infoRaw: String?
    @Published private(set) var infoAt: Date?

    // Raw response captured after a READ-setting request (for decoding).
    // The device replies with an ACK frame first and (for value reads) a
    // second data frame. We capture EVERY frame for a short window so the
    // value frame is not lost behind the ack.
    @Published private(set) var lastReadHex: String?
    @Published private(set) var lastReadLabel: String?
    @Published private(set) var readFrames: [String] = []
    @Published private(set) var decodedReadValue: String?
    private var awaitingRead: String?
    private var readDeadline: Date?

    /// Firmware revision read from the standard Device Information Service (0x2A26).
    @Published private(set) var fwRevision: String?

    /// Parse a LINKA LockInfoPacket (byte[1] == 0x0A). Layout (little-endian):
    /// [3]=rssi(int8), [4..7]=uptime(u32), [8..9]/[10..11]/[12..13]=accel x/y/z
    /// (int16 × 6.3e-5 ≈ g), [14..15]=extra(int16).
    private func parseInfoPacket(_ d: [UInt8]) {
        guard d.count >= 16, d[1] == 0x0A else { return }
        func le16(_ i: Int) -> Int {
            let v = Int(d[i]) | (Int(d[i + 1]) << 8)
            return v >= 0x8000 ? v - 0x10000 : v
        }
        func le32(_ i: Int) -> UInt32 {
            UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
        }
        infoRSSIpkt = Int(Int8(bitPattern: d[3]))
        infoUptime = le32(4)
        let s = 6.3e-5
        accelG = SIMD3(Double(le16(8)) * s, Double(le16(10)) * s, Double(le16(12)) * s)
        infoExtra = le16(14)
        infoRaw = LinkaCrypto.toHex(d)
        infoAt = Date()
    }

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

    deinit {
        central?.stopScan()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
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
            // The motor log reports the real actuation → trust it for live state.
            if s.contains("Motor Open")  { liveLocked = false }
            if s.contains("Motor Close") { liveLocked = true }
        }
    }

    private func add(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 300 { log.removeLast() }
    }

    private var intentionalStop = false

    func start() {
        guard subkey.count == 16, mac.count == 6 else {
            add("Config onvolledig (key \(subkey.count)B, mac \(mac.count)B)."); return
        }
        guard central.state == .poweredOn else { add("Bluetooth niet aan."); return }
        intentionalStop = false
        state = "scannen"; ready = false
        add("Scannen naar slot…")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        intentionalStop = true
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

    // MARK: Lock settings (parameter indices confirmed from the official app)

    func setAutolock(_ on: Bool) {
        sendPayload(LinkaCrypto.settingPayload(idx: 102, value: on ? 20 : 0),
                    name: on ? "Auto-lock aan" : "Auto-lock uit")
    }
    func setQuickLock(_ on: Bool) {
        sendPayload(LinkaCrypto.settingPayload(idx: 55, value: on ? 1 : 0),
                    name: on ? "Quick-lock aan" : "Quick-lock uit")
    }
    func setBumpThreshold(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 10, value: v), name: "Bump-gevoeligheid \(v)")
    }
    func setStall(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 5, value: v), name: "Stall-delay \(v)")
    }
    func setRollAngle(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 28, value: v), name: "Roll-hoek \(v)°")
    }
    func setTiltAngle(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 29, value: v), name: "Tilt-hoek \(v)°")
    }
    func setJostle(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 14, value: v), name: "Jostle \(v)")
    }
    func setAlarmDelay(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 7, value: v), name: "Alarm-delay \(v)")
    }
    func setAlarmTime(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 37, value: v), name: "Alarm-tijd \(v)")
    }
    func setLockSleep(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 17, value: v), name: "Lock-sleep \(v)")
    }
    /// Unlock sleep: the official app writes both index 30 and 50. The lock
    /// hands us a fresh counter after the first, so send the second shortly after.
    func setUnlockSleep(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 30, value: v), name: "Unlock-sleep \(v)")
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sendPayload(LinkaCrypto.settingPayload(idx: 50, value: v), name: "Unlock-sleep (2) \(v)")
        }
    }
    /// Raw parameter write — for advanced/experimental settings.
    func writeSetting(idx: Int, value: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: idx, value: value), name: "Param \(idx) = \(value)")
    }

    func setAccelDataRate(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 16, value: v), name: "Accel-datarate \(v)")
    }
    func setPulseTap(_ v: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 13, value: v), name: "Pulse-tap \(v)")
    }

    // MARK: Commands (opcodes from the firmware command map)
    func reboot()          { sendPayload([31, 0], name: "Herstart") }
    func sleepLock()       { sendPayload([9, 0],  name: "Slaapstand") }
    func statePing()       { sendPayload([27, 7], name: "State-ping") }
    func defaultSettings() { sendPayload([12, 0], name: "Standaardinstellingen herstellen") }
    func deleteBonds()     { sendPayload([13, 0], name: "Bluetooth-koppelingen wissen") }

    // MARK: Reads — response is encrypted; captured raw for decoding.
    func readPAC()        { beginRead("PAC", idx: 1) }
    func readActuations() { beginRead("Actuations", idx: 2) }

    private func beginRead(_ label: String, idx: UInt8) {
        awaitingRead = label
        lastReadHex = nil; lastReadLabel = label
        decodedReadValue = nil
        readFrames = []
        readDeadline = Date().addingTimeInterval(1.5)
        sendPayload(LinkaCrypto.readPayload(idx: idx), name: "Lees \(label)")
        // Close the capture window after 1.5 s and try to decode a value frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.awaitingRead == label else { return }
            self.awaitingRead = nil
            self.readDeadline = nil
            self.finishRead(label)
        }
    }

    /// After the capture window, pick the frame that is NOT the ack template
    /// and expose it. The ack is `14 02 04 .. .. 0d 11 04 00..00 1c 00 crc`.
    private func finishRead(_ label: String) {
        let frames = readFrames.map { $0.replacingOccurrences(of: " ", with: "") }
        func isAck(_ h: String) -> Bool {
            guard h.count == 40, h.hasPrefix("1402") else { return false }
            // bytes 5..17 are a fixed template in the status ack frame
            let mid = String(Array(h)[10..<36])
            return mid == "0d110400000000000400001c00"
        }
        let value = frames.first(where: { !isAck($0) && $0.count >= 8 })
        if let value {
            decodedReadValue = value
            lastReadHex = value
            add("READ(\(label)) waarde-frame: \(value)")
        } else if let only = frames.first {
            lastReadHex = only
            decodedReadValue = nil
            add("READ(\(label)): alleen ack ontvangen (\(frames.count) frame(s)) — geen los waarde-frame.")
        } else {
            add("READ(\(label)): geen respons ontvangen.")
        }
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
        Task { @MainActor in state = "services"; peripheral.discoverServices([LinkaBLE.service, CBUUID(string: "180A")]) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            ready = false; state = "verbroken"; add("Verbinding verbroken.")
            // Auto-reconnect unless the user intentionally stopped.
            if !intentionalStop, subkey.count == 16, mac.count == 6 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if !intentionalStop && !ready { start() }
            }
        }
    }
}

extension BLEController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in peripheral.services ?? [] {
                // LINKA service + standard Device Information Service (0x180A).
                if s.uuid == LinkaBLE.service || s.uuid == CBUUID(string: "180A") {
                    peripheral.discoverCharacteristics(nil, for: s)
                }
            }
        }
    }
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == LinkaBLE.dataRX { write0002 = c }
                if c.uuid.uuidString.uppercased().hasPrefix("D31E0016") { write0016 = c }
                // Firmware Revision String (0x2A26) in the Device Information Service.
                if c.uuid == CBUUID(string: "2A26") { peripheral.readValue(for: c) }
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
            // Device Information Service — firmware revision string.
            if characteristic.uuid == CBUUID(string: "2A26") {
                fwRevision = String(bytes: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                add("Firmware-revisie: \(fwRevision ?? "?")")
                return
            }
            // Decode live telemetry from any status/info packet (command 0x0A).
            parseInfoPacket(data)
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
                if let label = awaitingRead {
                    // Capture EVERY frame in the window; the value frame may be
                    // the 2nd notification after the ack.
                    let hex = LinkaCrypto.toHex(data)
                    readFrames.append(hex)
                    lastReadHex = hex
                    lastReadLabel = label
                    add("READ(\(label)) frame \(readFrames.count): \(hex)")
                } else {
                    add("← \(uuid.prefix(8)): \(LinkaCrypto.toHex(data))")
                }
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
