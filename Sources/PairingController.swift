import Foundation
import CoreBluetooth

/// Adds (pairs) a new LEO2 lock, following the official app's flow
/// (SetupLinka2 → LinkaAccessKey.tryRegisterLock → startLinkaResettingMasterKeys):
///   check_key_status → upsert_lock → gen_master_key → BLE: write master key #1
///   (MK slot 1, 2 halves) → register_lock_with_master_keys → write master key #2
///   (slot 2) → done. Extra safety vs the official app: an encrypted test READ
///   before any key write, and the new master keys are stored on the phone first.
@MainActor
final class PairingController: NSObject, ObservableObject {

    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
        let mac: String?
        var rssi: Int
        static func == (a: Found, b: Found) -> Bool { a.id == b.id && a.rssi == b.rssi }
    }

    @Published private(set) var found: [Found] = []
    @Published private(set) var scanning = false
    @Published private(set) var steps: [String] = []
    @Published private(set) var busy = false
    @Published private(set) var finished = false
    @Published private(set) var error: String?
    /// Set when master key #1 was written but a later step failed → resumable.
    @Published private(set) var canResume = false
    @Published private(set) var needsPermissionRequest = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var connected = false
    private var servicesReady = false

    // Live protocol state
    private var encVer: Int?
    private var counter: UInt32?
    private var ackSeen = false
    private var nakSeen = false
    private var badEnc = false
    private var replies: [Int: Int] = [:]

    private let api = APIClient()
    private var auth: Identity?
    private var target: Found?
    private var mac: [UInt8] = []
    private var gen: GenMasterKey?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Scan

    func startScan() {
        guard central.state == .poweredOn else { error = "Zet Bluetooth aan."; return }
        found = []; peripherals = [:]; error = nil
        scanning = true
        central.scanForPeripherals(withServices: [LinkaBLE.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScan() { central.stopScan(); scanning = false }

    /// Embedded MAC from the manufacturer record (type 0xC2/0xC3, MAC at +15 of the
    /// record data, big-endian) — iOS hides the real Bluetooth address.
    static func macFromAdvert(_ data: Data?) -> String? {
        guard let d = data.map({ [UInt8]($0) }), d.count >= 8 else { return nil }
        for start in 0..<min(3, d.count) where d[start] == 0xC2 || d[start] == 0xC3 {
            let m = start + 15
            if d.count >= m + 6 {
                return d[m..<(m + 6)].map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return nil
    }

    // MARK: Pair

    private func log(_ s: String) { steps.append(s) }

    private func wait(_ seconds: Double, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    private static func pendingKey(_ mac: String) -> String { "pair_master_\(mac)" }

    func pair(_ f: Found, auth: Identity) {
        guard !busy else { return }
        guard let macStr = f.mac, let macBytes = LinkaCrypto.macBytes(macStr) else {
            error = "Kon het MAC-adres van dit slot niet uit de advertentie lezen."; return
        }
        stopScan()
        self.auth = auth; target = f; mac = macBytes
        busy = true; finished = false; error = nil; steps = []; canResume = false; needsPermissionRequest = false
        Task { await runPairing(serial: macStr) }
    }

    private func fail(_ msg: String) {
        error = msg; busy = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    private func runPairing(serial: String) async {
        guard let auth, let target else { return }
        do {
            log("Status bij LINKA opvragen…")
            let ks = try await api.checkKeyStatus(serial: serial, auth: auth)
            if ks.ownsKey == true, let k = ks.key, k.commandKey != nil {
                LockCache.saveKeys(k, serial: serial)
                log("✓ Je hebt al toegang tot dit slot — toegevoegd.")
                finished = true; busy = false; return
            }
            if ks.hasAdmin == true {
                log("Dit slot heeft al een eigenaar.")
                needsPermissionRequest = true
                fail("Dit slot is al gekoppeld aan een ander account. Je kunt de eigenaar om toegang vragen.")
                return
            }

            log("Slot registreren…")
            try await api.upsertLock(name: target.name, serial: serial, auth: auth)
            log("Nieuwe sleutels laten aanmaken…")
            let g = try await api.genMasterKey(serial: serial, auth: auth)
            guard let m1 = g.access_key_master, let m2 = g.access_key_master_2,
                  let origin = g.access_key_origin_v2 ?? g.access_key_origin,
                  LinkaCrypto.hex(m1).count == 16, LinkaCrypto.hex(m2).count == 16,
                  LinkaCrypto.hex(origin).count == 16 else {
                fail("Server gaf geen geldige sleutels terug. Er is niets naar het slot geschreven."); return
            }
            gen = g
            // Never overwrite keys from an interrupted earlier attempt: they may be
            // the only copy of what is in the lock now.
            if let old = Keychain.get(Self.pendingKey(serial)) {
                Keychain.set(old, for: Self.pendingKey(serial) + "_prev_\(Int(Date().timeIntervalSince1970))")
            }
            // Safety: keep the new master keys on the phone BEFORE touching the lock.
            if let data = try? JSONEncoder().encode(g), let s = String(data: data, encoding: .utf8) {
                Keychain.set(s, for: Self.pendingKey(serial))
            }
            log("Sleutels veilig op deze telefoon bewaard.")

            guard await connectAndWaitContext() else { return }
            let originMaster = LinkaCrypto.invertedKey(origin)

            // Pre-check: an encrypted READ with the origin key. No key is written if this fails.
            log("Controleren of het slot de startsleutel accepteert…")
            replies[2] = nil; badEnc = false; nakSeen = false
            guard sendFrame(LinkaCrypto.readPayload(idx: 2), master: originMaster, slotF: 0) else { return }
            let readOK = await wait(5) { replies[2] != nil || badEnc || nakSeen }
            guard readOK, replies[2] != nil, !badEnc, !nakSeen else {
                fail("Het slot accepteert de startsleutel niet (al eerder gekoppeld?). Er is NIETS geschreven; het slot is onveranderd.")
                return
            }
            log("✓ Startsleutel geaccepteerd.")

            // Order like the official app with encVer field f=0 (l()==1): first = master_2 → slot 1.
            let first = LinkaCrypto.hex(m2), second = LinkaCrypto.hex(m1)
            log("Sleutel 1 schrijven — blijf bij het slot…")
            guard await writeMasterKey(first, lowIdx: 21, highIdx: 22, with: originMaster, slotF: 0) else {
                fail("Schrijven van sleutel 1 niet bevestigd. Probeer opnieuw; de sleutels staan bewaard op je telefoon.")
                canResume = true; return
            }
            log("✓ Sleutel 1 in het slot.")
            try await finishFromFirst(serial: serial, first: first, second: second, m1: m1, m2: m2)
        } catch {
            fail("Fout: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            if gen != nil, steps.contains(where: { $0.hasPrefix("✓ Sleutel 1") }) { canResume = true }
        }
    }

    /// Steps after master key #1 is in the lock: server register, then key #2.
    private func finishFromFirst(serial: String, first: [UInt8], second: [UInt8], m1: String, m2: String) async throws {
        guard let auth else { return }
        log("Registreren bij LINKA…")
        let keys = try await api.registerLockWithMasterKeys(serial: serial, master: m1, master2: m2, auth: auth)
        LockCache.saveKeys(keys, serial: serial)
        log("✓ Toegangssleutels ontvangen.")

        log("Sleutel 2 schrijven…")
        guard await writeMasterKey(second, lowIdx: 23, highIdx: 24, with: first, slotF: 1) else {
            fail("Sleutel 2 niet bevestigd. Het slot werkt met sleutel 1; probeer ‘Hervatten’."); canResume = true; return
        }
        log("✓ Sleutel 2 in het slot.")
        // Keep the master keys permanently (useful for any future re-pair).
        if let s = Keychain.get(Self.pendingKey(serial)) { Keychain.set(s, for: "master_\(serial)") }
        Keychain.delete(Self.pendingKey(serial))
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        log("✓ Klaar — slot toegevoegd.")
        finished = true; busy = false; canResume = false
    }

    /// Resume after key #1 was written but a later step failed.
    func resume() {
        guard !busy, let target, let serial = target.mac,
              let s = Keychain.get(Self.pendingKey(serial)), let data = s.data(using: .utf8),
              let g = try? JSONDecoder().decode(GenMasterKey.self, from: data),
              let m1 = g.access_key_master, let m2 = g.access_key_master_2 else {
            error = "Geen bewaarde sleutels om te hervatten."; return
        }
        busy = true; error = nil; canResume = false
        Task {
            // Keep "Hervatten" available if the reconnect fails: key 1 is already in the lock.
            guard await connectAndWaitContext() else { canResume = true; return }
            do {
                try await finishFromFirst(serial: serial, first: LinkaCrypto.hex(m2), second: LinkaCrypto.hex(m1), m1: m1, m2: m2)
            } catch {
                fail("Fout: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"); canResume = true
            }
        }
    }

    func requestAccess(auth: Identity) {
        guard let serial = target?.mac else { return }
        Task {
            do {
                try await api.requestUserPermission(serial: serial, auth: auth)
                log("✓ Toegangsverzoek verstuurd naar de eigenaar.")
                needsPermissionRequest = false; error = nil
            } catch {
                self.error = "Verzoek mislukt: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
    }

    // MARK: BLE helpers

    private func connectAndWaitContext() async -> Bool {
        guard let id = target?.id, let p = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            fail("Slot niet meer gevonden — druk op de knop van het slot en probeer opnieuw."); return false
        }
        log("Verbinden met het slot…")
        peripheral = p; p.delegate = self
        connected = false; servicesReady = false; counter = nil; encVer = nil
        central.connect(p, options: nil)
        guard await wait(15, until: { servicesReady }) else {
            fail("Verbinden mislukt. Er is niets naar het slot geschreven."); return false
        }
        guard await wait(8, until: { counter != nil }) else {
            fail("Het slot reageert niet. Druk op de knop van het slot en probeer opnieuw."); return false
        }
        guard let v = encVer, v == 2 || v == 3 else {
            fail("Onverwachte encryptieversie (\(encVer.map(String.init) ?? "–")); alleen LEO2 wordt ondersteund."); return false
        }
        log("✓ Verbonden (encVer \(v)).")
        return true
    }

    private func sendFrame(_ payload: [UInt8], master: [UInt8], slotF: Int) -> Bool {
        guard let p = peripheral, let ch = writeChar, let c = counter, let v = encVer else {
            fail("Verbinding met het slot verbroken. Probeer opnieuw."); return false
        }
        let frame = LinkaCrypto.masterFrame(mac: mac, payload: payload, masterKey: master, slotF: slotF,
                                            priv: .admin, encVer: v, counter: c)
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        p.writeValue(Data(frame), for: ch, type: type)
        return true
    }

    /// One 16-byte key = LOWER (bytes 0–7) then UPPER (8–15), each confirmed by an Ack.
    private func writeMasterKey(_ key: [UInt8], lowIdx: Int, highIdx: Int, with master: [UInt8], slotF: Int) async -> Bool {
        for (idx, half) in [(lowIdx, Array(key[0..<8])), (highIdx, Array(key[8..<16]))] {
            ackSeen = false; nakSeen = false; badEnc = false
            let before = counter
            guard sendFrame(LinkaCrypto.masterKeyPayload(idx: idx, half: half), master: master, slotF: slotF) else { return false }
            let ok = await wait(6) { ackSeen || nakSeen || badEnc }
            guard ok, ackSeen, !nakSeen, !badEnc else { return false }
            // Next frame must use the fresh counter from the Ack.
            _ = await wait(2) { counter != before }
        }
        return true
    }

    private func crcOK(_ d: [UInt8]) -> Bool {
        guard d.count >= 4 else { return false }
        let c = LinkaCrypto.crc16(d, d.count - 2)
        return d[d.count - 2] == UInt8((c >> 8) & 0xff) && d[d.count - 1] == UInt8(c & 0xff)
    }

    private func handle(_ d: [UInt8], uuid: CBUUID) {
        if uuid == LinkaBLE.leoLog {
            let s = String(bytes: d, encoding: .utf8) ?? ""
            if s.localizedCaseInsensitiveContains("Bad enc") { badEnc = true }
            return
        }
        guard d.count >= 7, Int(d[0]) == d.count, crcOK(d) else { return }
        func le32(_ i: Int) -> UInt32 {
            UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
        }
        switch d[1] {
        case 0x0B where d[0] == 0x12:
            encVer = Int(d[2]); counter = le32(3)
        case 3, 4:
            guard d.count >= 15 else { return }
            replies[Int(d[2])] = Int(Int32(bitPattern: le32(3)))
            let c = le32(11); if c != 0 { counter = c }
        case 6:
            if d.count >= 11 { let c = le32(7); if c != 0 { counter = c } }
            ackSeen = true
        case 7:
            if d.count >= 11 { let c = le32(7); if c != 0 { counter = c } }
            nakSeen = true
        default: break
        }
    }
}

extension PairingController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let r = RSSI.intValue
        Task { @MainActor in
            guard name == "LK-LEO2" || name == "RPB-STD" else { return }
            peripherals[peripheral.identifier] = peripheral
            let mac = Self.macFromAdvert(mfg)
            if let i = found.firstIndex(where: { $0.id == peripheral.identifier }) {
                found[i].rssi = r
            } else {
                found.append(Found(id: peripheral.identifier, name: name, mac: mac, rssi: r))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connected = true
            peripheral.discoverServices([LinkaBLE.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in connected = false; servicesReady = false }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == LinkaBLE.dataRX { writeChar = c }
                if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: c)
                }
            }
            if writeChar != nil { servicesReady = true }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let d = [UInt8](characteristic.value ?? Data())
        let u = characteristic.uuid
        Task { @MainActor in handle(d, uuid: u) }
    }
}
