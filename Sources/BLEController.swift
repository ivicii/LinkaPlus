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
    @Published private(set) var liveLocked: Bool?
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
    @Published private(set) var infoTempC: Int?
    @Published private(set) var infoRaw: String?
    @Published private(set) var infoAt: Date?

    // Setting values read back from the lock (GET_SETTING, opcode 4 — the reply
    // is a plaintext type-3/4 frame: value = bytes[3..6] LE32).
    @Published private(set) var settingValues: [Int: Int] = [:]
    @Published private(set) var settingValues2: [Int: Int] = [:]
    /// Cellular info the lock pushes (type 0x1A): operator name and CSQ (0–31).
    @Published private(set) var netOperator: String?
    @Published private(set) var netCSQ: Int?
    @Published private(set) var reading = false
    @Published private(set) var readFrames: [String] = []
    @Published private(set) var lastReadLabel: String?
    private var awaitingRead: String?
    private var pendingReadIdx: Int?
    private var replyReceived = false

    /// Firmware revision read from the standard Device Information Service (0x2A26).
    @Published private(set) var fwRevision: String?
    /// Battery level (%) — from the lock's status frame (byte[6]), which matches
    /// the official app, or the standard Battery Service as a fallback. Works
    /// without the cloud.
    @Published private(set) var batteryLevelBLE: Int?
    /// Battery voltage (V) decoded from the status frame: (byte[4]|byte[5]<<8)/1000.
    @Published private(set) var batteryVoltageBLE: Double?
    /// Live status flags decoded from the status frame (bytes[12..15], bitfield).
    @Published private(set) var statusFlags: [String] = []
    @Published private(set) var isChargingBLE = false
    /// Lock state read from the status frame (byte[2]); nil until a frame arrives.
    @Published private(set) var lockStateText: String?
    private var prevFlagSet: Set<String> = []
    private var selfSirenUntil = Date.distantPast
    /// Status "reason" byte[16] (rc/d). The official app unlocks on reason 10
    /// (Linka.updateFromStatusData → doUnlock) when auto-unlock is on.
    @Published private(set) var lockReason: Int?
    /// Opt-in: unlock when the lock's button is pressed while this phone is connected.
    @Published var autoUnlockEnabled = false
    /// Proximity auto-unlock (like the official Linka.updateRSSI/doAutoUnlock):
    /// latch "away" when locked and the signal drops very low or the link is lost;
    /// unlock once when you come back within range. Opt-in.
    @Published var proximityUnlockEnabled = false
    var proximityThreshold = -70
    @Published private(set) var awayLatched = false
    private var nearCount = 0
    private var lastAutoUnlock = Date.distantPast
    /// Motor in motion per status frame (1 = locking, 2 = unlocking), like the
    /// official CircleView (pulses while isLocking/isUnlocking).
    enum Motion: Equatable { case locking, unlocking }
    @Published private(set) var motion: Motion?
    /// Measured motor time (s) from state 1/2 to 3/4, remembered across runs.
    @Published private(set) var motorDuration: Double = {
        let v = UserDefaults.standard.double(forKey: "motorDuration"); return v > 0 ? v : 1.5
    }()
    private var motionStart: Date?

    /// Flags that warrant a push notification, with their notification text.
    private static let notifyFlags: [String: (String, String)] = [
        "Foute PAC ingevoerd":     ("Beveiliging", "Er is een foute PAC-code op je slot ingevoerd."),
        "Ongeldige PAC ingesteld": ("Beveiliging", "Er is een ongeldige PAC-code ingesteld."),
        "Sirene actief":           ("Alarm", "De sirene van je slot gaat af."),
        "Alarm":                   ("Alarm", "Je slot slaat alarm."),
        "Alarm: hameren":          ("Alarm", "Je slot detecteert hameren (inbraakpoging?)."),
        "Alarm: schudden":         ("Alarm", "Je slot wordt geschud."),
        "Motor vastgelopen":       ("Slot", "De motor van je slot is vastgelopen."),
        "Batterij laag":           ("Batterij", "De batterij van je slot is bijna leeg."),
    ]

    /// Status-flag bitfield → Dutch labels. Reverse-engineered from the official
    /// app (rc.e.b). Internal/obvious bits are intentionally not surfaced.
    private static let flagLabels: [(UInt32, String)] = [
        (0x000002, "Tracking (tether)"),
        (0x000004, "Opladen"),
        (0x000008, "Volgeladen"),
        (0x000010, "Batterij laag"),
        (0x000020, "Motor vastgelopen"),
        (0x000040, "Stoot gedetecteerd"),
        (0x000080, "Aanraking"),
        (0x000100, "Alarm"),
        (0x000200, "Gekanteld"),
        (0x001000, "Testmodus"),
        (0x004000, "Hall-sensor afwijking"),
        (0x008000, "Alarm: hameren"),
        (0x010000, "Alarm: schudden"),
        (0x020000, "Sirene actief"),
        (0x040000, "Ongeldige PAC ingesteld"),
        (0x080000, "Foute PAC ingevoerd"),
        (0x100000, "Beeper aan"),
        (0x400000, "Lage temperatuur"),
    ]

    /// Parse a LINKA LockInfoPacket (byte[1] == 0x0A). Layout (little-endian):
    /// [3]=rssi(int8), [4..7]=uptime(u32), [8..9]/[10..11]/[12..13]=accel x/y/z
    /// (int16 × 6.3e-5 ≈ g), [14..15]=extra(int16).
    /// Decode battery % and cell voltage from a status frame (type byte [1]==0x02).
    /// Field layout reverse-engineered from the official app (pc.f / pc.j):
    /// byte[6] = battery %, (byte[4]|byte[5]<<8)/1000 = voltage (V).
    private func parseStatusFrame(_ d: [UInt8]) {
        guard d.count >= 7, d[0] == 0x14, d[1] == 0x02 else { return }
        let pct = Int(d[6])
        if pct >= 0 && pct <= 100 { batteryLevelBLE = pct }
        let mv = Int(d[4]) | (Int(d[5]) << 8)
        let v = Double(mv) / 1000.0
        if v > 1.0 && v < 6.0 { batteryVoltageBLE = v }
        // Lock state (byte[2], rc/b mapping). Shown as a diagnostic only — not yet
        // validated against a physical lock/unlock, so it does NOT drive liveLocked
        // (which stays authoritative from motor events + user actions).
        // rc/b mapping (confirmed from APK packed-switch 0..8):
        // Like the official app (Linka.updateFromStatusData): 3/7 = locked, 4/8 = unlocked.
        switch Int(d[2]) {
        case 1: if motion != .locking { motion = .locking; motionStart = Date() }
        case 2: if motion != .unlocking { motion = .unlocking; motionStart = Date() }
        case 3, 7, 4, 8:
            if let s = motionStart {
                let t = Date().timeIntervalSince(s)
                if t > 0.3 && t < 8 {
                    motorDuration = t
                    UserDefaults.standard.set(t, forKey: "motorDuration")
                }
            }
            motionStart = nil; motion = nil
            liveLocked = (d[2] == 3 || d[2] == 7)
        default: motion = nil; motionStart = nil
        }
        switch Int(d[2]) {
        case 0: lockStateText = "Opstarten"
        case 1: lockStateText = "Vergrendelen…"
        case 2: lockStateText = "Ontgrendelen…"
        case 3: lockStateText = "Vergrendeld"
        case 4: lockStateText = "Ontgrendeld"
        case 5: lockStateText = "Fout"
        case 6: lockStateText = "Vastgelopen (stall)"
        case 7: lockStateText = "Vergrendeld (PAC)"
        case 8: lockStateText = "Ontgrendeld (PAC)"
        default: lockStateText = "Onbekend (\(d[2]))"
        }
        // Reason byte[16]: rising edge of 10 = button press asking for unlock.
        if d.count >= 17 {
            let r = Int(d[16])
            if r != lockReason {
                add("Status-reden: \(r)")
                if r == 10, autoUnlockEnabled, Date().timeIntervalSince(lastAutoUnlock) > 10 {
                    lastAutoUnlock = Date()
                    add("Auto-unlock: knopdruk gedetecteerd → openen")
                    unlock()
                }
                lockReason = r
            }
        }
        // Status flags bitfield at bytes[12..15] (little-endian).
        if d.count >= 16 {
            let flags = UInt32(d[12]) | (UInt32(d[13]) << 8) | (UInt32(d[14]) << 16) | (UInt32(d[15]) << 24)
            let active = Self.flagLabels.filter { flags & $0.0 != 0 }.map { $0.1 }
            statusFlags = active
            isChargingBLE = (flags & 0x04) != 0   // 0x04=Opladen (0x08=Volgeladen is niet 'opladen')
            // Notify on the rising edge of any critical flag.
            let now = Set(active)
            for flag in now.subtracting(prevFlagSet) {
                if flag == "Sirene actief", Date() < selfSirenUntil { continue }   // started by this app
                if let (title, body) = Self.notifyFlags[flag] {
                    LockNotifier.shared.notify(title: title, body: body, id: flag)
                }
            }
            prevFlagSet = now
        }
    }

    /// Setting reply, e.g. `11 04 05 00000000 f4010000 673e6d2e 87de` (17 bytes):
    /// [0]=length, [1]=type 3/4, [2]=idx, [3..6]=value, [7..10]=value2,
    /// [11..14]=next counter, CRC. Byte[0] is the frame LENGTH, not always 0x14.
    private func parseSettingReply(_ d: [UInt8]) {
        guard d.count >= 11, Int(d[0]) == d.count, d[1] == 0x03 || d[1] == 0x04, crcOK(d) else { return }
        let raw = UInt32(d[3]) | (UInt32(d[4]) << 8) | (UInt32(d[5]) << 16) | (UInt32(d[6]) << 24)
        let raw2 = UInt32(d[7]) | (UInt32(d[8]) << 8) | (UInt32(d[9]) << 16) | (UInt32(d[10]) << 24)
        let idx = Int(d[2])
        settingValues[idx] = Int(Int32(bitPattern: raw))
        settingValues2[idx] = Int(Int32(bitPattern: raw2))
        if pendingReadIdx == nil || pendingReadIdx == idx { replyReceived = true }
    }

    /// Modem info (type 0x1A): sub 4 = operator name (ASCII from [4]), sub 3 = CSQ at [4].
    private func parseModemInfo(_ d: [UInt8]) {
        guard d.count >= 6, Int(d[0]) == d.count, d[1] == 0x1A, crcOK(d) else { return }
        switch d[2] {
        case 4:
            let bytes = d[4..<(d.count - 2)].prefix { $0 != 0 }
            if let s = String(bytes: bytes, encoding: .ascii), !s.isEmpty { netOperator = s }
        case 3:
            let v = Int(d[4]); if v <= 31 { netCSQ = v }
        default: break
        }
    }

    /// CRC-16 (big-endian in the last two bytes) as pc.f.d verifies it.
    private func crcOK(_ d: [UInt8]) -> Bool {
        guard d.count >= 4 else { return false }
        let c = LinkaCrypto.crc16(d, d.count - 2)
        return d[d.count - 2] == UInt8((c >> 8) & 0xff) && d[d.count - 1] == UInt8(c & 0xff)
    }

    /// The official app takes the NEXT counter from setting replies (bytes 11..14)
    /// and ACK/NAK frames (bytes 7..10), not only from 0x12 context frames.
    /// Only CRC-valid frames are trusted. NAK/ACK also release a waiting read.
    private func updateCounterFromReply(_ d: [UInt8]) {
        guard d.count >= 12, Int(d[0]) == d.count, crcOK(d) else { return }
        func le32(_ i: Int) -> UInt32 {
            UInt32(d[i]) | (UInt32(d[i+1]) << 8) | (UInt32(d[i+2]) << 16) | (UInt32(d[i+3]) << 24)
        }
        switch d[1] {
        case 3, 4:
            if d.count >= 15 { let c = le32(11); if c != 0 { ctxCounter = c } }
        case 6, 7:
            let c = le32(7)
            if c != 0 { ctxCounter = c }
            let idx = Int(le32(3) & 0xff)
            add(d[1] == 6 ? "ACK cmd \(d[2]) idx \(idx)" : "NAK cmd \(d[2]) idx \(idx)")
            if d[1] == 7 { replyReceived = true }
        default: break
        }
    }

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
        // Byte[17] = temperature in °C (confirmed: pc/h.toString "Temp %ddeg").
        if d.count >= 18 { infoTempC = Int(d[17]) }
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
    private var didInitialStatusPing = false
    private var lastUsedCounter: UInt32?   // anti-replay: last IV counter sent

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

    /// Tries the access-key variants one by one (known-good key first) on the
    /// real channel. Lockout-safe: max 4 attempts, a fresh context counter for
    /// every attempt, 1.5 s between attempts, and it aborts after 2 rejections
    /// in a row so the lock's bad-encryption counter cannot trip a lockout.
    func autoTest() {
        guard !testing else { return }
        var variants = keyVariants()
        let current = LinkaCrypto.toHex(subkey)
        let good = variants.filter { $0.hex.lowercased() == current }
        let rest = variants.filter { $0.hex.lowercased() != current }
        variants = Array((good + rest).prefix(4))
        guard !variants.isEmpty, mac.count == 6 else { add("Auto-test: geen sleutels/mac."); return }
        guard write0002 != nil else { add("Auto-test: geen schrijfkanaal."); return }
        testing = true
        winner = nil
        Task {
            add("== Auto-test == max. 4 pogingen, stopt na 2 weigeringen (lockout-veilig).")
            var rejects = 0
            var idx = 0
            outer: for v in variants {
                if !testing { break }
                idx += 1
                var waited = 0
                while (ctxCounter == nil || ctxCounter == lastUsedCounter) && waited < 12 {
                    try? await Task.sleep(nanoseconds: 250_000_000); waited += 1
                }
                guard let c = ctxCounter, c != lastUsedCounter, let chr = write0002 else {
                    add("Auto-test gestopt: geen verse teller van het slot."); break
                }
                encAccepted = nil
                let frame = LinkaCrypto.commandFrame(mac: mac, payload: [27, 7],
                                                     subkey: LinkaCrypto.hex(v.hex), priv: v.priv, counter: c)
                add("[TEST \(idx)/\(variants.count)] key=\(v.name) ctr=\(c)")
                lastUsedCounter = c
                let type: CBCharacteristicWriteType = chr.properties.contains(.write) ? .withResponse : .withoutResponse
                peripheral?.writeValue(Data(frame), for: chr, type: type)
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if encAccepted == true {
                        winner = "key=\(v.name)"
                        subkey = LinkaCrypto.hex(v.hex); priv = v.priv; channel = 0; counterOffset = 0
                        add("✓✓ GELUKT! \(winner!) geaccepteerd.")
                        break outer
                    }
                    if encAccepted == false { break }
                }
                if encAccepted == false {
                    rejects += 1
                    if rejects >= 2 { add("Auto-test gestopt na 2 weigeringen (lockout-bescherming)."); break }
                } else { rejects = 0 }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if winner == nil { add("== Auto-test klaar (\(idx) pogingen), geen acceptatie ==") }
            testing = false
        }
    }

    func stopTest() { testing = false }
    func clearCommandResult() { commandResult = nil }

    private func handleProximity(_ r: Int) {
        guard proximityUnlockEnabled, liveLocked == true else { nearCount = 0; return }
        if r < -95 { if !awayLatched { add("Nabijheid: buiten bereik (\(r) dBm)") }; awayLatched = true; nearCount = 0; return }
        guard awayLatched, r >= proximityThreshold, ctxCounter != nil else { nearCount = 0; return }
        nearCount += 1
        if nearCount >= 3 {
            awayLatched = false; nearCount = 0
            add("Nabijheid: terug binnen bereik (\(r) dBm) → auto-unlock")
            unlock()
        }
    }

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
        // Avoid overlapping scans/connects from auto-reconnect + UI buttons.
        guard state != "scannen", state != "verbinden", state != "services" else { return }
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

    private var rssiPolling = false
    private func startRSSIPolling() {
        guard !rssiPolling else { return }
        rssiPolling = true
        Task {
            while ready, let p = peripheral {
                p.readRSSI()
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            rssiPolling = false
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

    // MARK: Lock settings (indices from the official app's pc/i table)

    /// Write one setting, then read it back so the UI shows what the lock really has.
    private func put(_ idx: Int, _ value: Int, _ name: String) {
        sendPayload(LinkaCrypto.settingPayload(idx: idx, value: value), name: name)
        Task { try? await Task.sleep(nanoseconds: 1_200_000_000); readSettings([idx]) }
    }

    /// Quick Lock as the official app does it (LockController.doSetAutolock): idx 102 = 20 / 0.
    func setQuickLock(_ on: Bool)   { put(102, on ? 20 : 0, on ? "Quick-lock aan" : "Quick-lock uit") }
    /// VLSO_SETTING_ALLOW_UNCONN_LOCK (idx 55): allow locking without a connected phone.
    func setAllowUnconnLock(_ on: Bool) { put(55, on ? 1 : 0, on ? "Sluiten zonder verbinding aan" : "Sluiten zonder verbinding uit") }
    /// Movement notification (official doSetMovementNotification): idx 106 = 5 / 0.
    func setMovementAlarm(_ on: Bool) { put(106, on ? 5 : 0, on ? "Bewegingsmelding aan" : "Bewegingsmelding uit") }
    func setAudio(_ on: Bool)       { put(12, on ? 3 : 0, on ? "Geluid aan" : "Geluid uit") }
    /// VLSO_SETTING_RSSI_UNLOCK_MIN (idx 11): phone must be at least this strong (-dBm) for a button unlock.
    func setUnlockRSSIMin(_ v: Int) { put(11, v, "Min. signaal knop-ontgrendeling -\(v) dBm") }
    func setBumpThreshold(_ v: Int) { put(10, v, "Bump-drempel \(v) mg") }
    func setStallCurrent(_ v: Int)  { put(5, v, "Stall-stroom \(v) mA") }
    func setStallDelay(_ v: Int)    { put(45, v, "Stall-vertraging \(v)") }
    func setHammer(_ v: Int)        { put(15, v, "Hamer-drempel \(v)") }
    func setAlarmTimeout(_ v: Int)  { put(8, v, "Alarm-timeout \(v)") }
    func setRollAngle(_ v: Int)     { put(28, v, "Roll-hoek \(v)°") }
    func setTiltAngle(_ v: Int)     { put(29, v, "Pitch-hoek \(v)°") }
    func setJostle(_ v: Int)        { put(14, v, "Jostle \(v)") }
    func setAlarmDelay(_ v: Int)    { put(7, v, "Alarm-vertraging \(v) s") }
    func setAlarmTime(_ v: Int)     { put(37, v, "Alarm-duur \(v) s") }
    func setLockSleep(_ v: Int)     { put(17, max(600, v), "Lock-sleep \(max(600, v)) s") }
    func setAccelDataRate(_ v: Int) { put(16, v, "Accel-datarate \(v)") }
    func setPulseTap(_ v: Int)      { put(13, v, "Pulse-drempel \(v) mg") }
    func setPAC(_ code: Int)        { put(1, code, "PAC-code instellen") }
    /// Unlock sleep: the official app writes both index 30 and 50. The lock
    /// hands us a fresh counter after the first, so send the second shortly after.
    func setUnlockSleep(_ v: Int) {
        let v = max(600, v)
        sendPayload(LinkaCrypto.settingPayload(idx: 30, value: v), name: "Unlock-sleep \(v) s")
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            sendPayload(LinkaCrypto.settingPayload(idx: 50, value: v), name: "Unlock-sleep (2) \(v) s")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            readSettings([30])
        }
    }
    /// Power mode like the official SettingsBatteryFragment: writes locked sleep (17)
    /// and unlocked sleep (30 + 50) with the same value. 600 = power saving,
    /// 36000 = high performance.
    func setPowerMode(seconds s: Int) {
        sendPayload(LinkaCrypto.settingPayload(idx: 17, value: s), name: "Slaap (dicht) \(s) s")
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            setUnlockSleep(s)
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            readSettings([17, 30])
        }
    }
    /// Raw parameter write — for advanced/experimental settings.
    func writeSetting(idx: Int, value: Int) {
        // Never expose identity / key / bonding / bootloader / motor-code slots.
        let blocked: Set<Int> = [0, 4, 19, 21, 22, 23, 24, 25, 26, 34, 46, 54]
        guard !blocked.contains(idx) else { add("Param \(idx) is geblokkeerd (veiligheid)."); return }
        put(idx, value, "Param \(idx) = \(value)")
    }

    // MARK: Commands (opcodes from the firmware command map)
    func sirenOn()         { selfSirenUntil = Date().addingTimeInterval(75); sendPayload([14, 60], name: "Sirene") }
    func sirenOff()        { sendPayload([20, 0], name: "Sirene uit") }
    func reboot()          { sendPayload([31, 0], name: "Herstart") }
    func sleepLock()       { sendPayload([9, 0],  name: "Slaapstand") }
    func statePing()       { sendPayload([27, 7], name: "State-ping") }
    func defaultSettings() { sendPayload([12, 0], name: "Standaardinstellingen herstellen") }
    func deleteBonds()     { sendPayload([13, 0], name: "Bluetooth-koppelingen wissen") }
    /// Official anti-theft command 21: param 5 = off, 17 = reset.
    func antiTheft(reset: Bool) { sendPayload([21, reset ? 17 : 5], name: reset ? "Anti-diefstal reset" : "Anti-diefstal uit") }

    // MARK: Reads — GET_SETTING (opcode 4); reply is plaintext.

    /// Reads settings one by one (each command needs the fresh counter the lock
    /// hands out after the previous one). Results land in `settingValues`.
    func readSettings(_ idxs: [Int]) {
        guard ready, !reading else { return }
        reading = true
        Task {
            for idx in idxs {
                guard ready else { break }
                pendingReadIdx = idx
                replyReceived = false
                awaitingRead = "Param \(idx)"
                lastReadLabel = "Param \(idx)"
                sendPayload(LinkaCrypto.readPayload(idx: idx), name: "Lees param \(idx)", quiet: true)
                var t = 0
                while !replyReceived && t < 16 { try? await Task.sleep(nanoseconds: 250_000_000); t += 1 }
                awaitingRead = nil
                pendingReadIdx = nil
            }
            reading = false
        }
    }

    func readPAC()        { readSettings([1]) }
    func readActuations() { readSettings([2]) }
    var lockPAC: Int? { settingValues[1] }
    var actuations: Int? { settingValues[2] }

    private func sendPayload(_ payload: [UInt8], name: String, expectActuation: Bool = false, quiet: Bool = false, retry: Int = 0, onSuccess: (() -> Void)? = nil) {
        let ch = (channel == 1) ? write0016 : write0002
        guard let ch = ch else { add("Geen write-characteristic."); return }
        guard let c = ctxCounter else { add("Nog geen context-teller (wacht op 0x12-frame)."); return }
        let useCounter = UInt32(truncatingIfNeeded: Int(c) + counterOffset)
        // Anti-replay: the counter is the AES IV. Reusing it makes the firmware
        // reject the command as "Bad enc" and increments its bad-enc counter, so
        // refuse rather than send a stale frame — wait for a fresh 0x12 context.
        if useCounter == lastUsedCounter {
            // Wait (up to ~2 s) for the lock to hand out a fresh counter, then retry.
            if retry < 8 {
                Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    sendPayload(payload, name: name, expectActuation: expectActuation, quiet: quiet,
                                retry: retry + 1, onSuccess: onSuccess)
                }
                return
            }
            add("Geen verse context-teller van het slot ontvangen — \(name) niet verstuurd.")
            if !quiet { commandResult = .timeout }
            return
        }
        let frame = LinkaCrypto.commandFrame(mac: mac, payload: payload, subkey: subkey, priv: priv, counter: useCounter)
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        if !quiet { encAccepted = nil; vstateChanged = false; commandResult = nil }
        add("→ \(name) (ctr \(useCounter)): \(LinkaCrypto.toHex(frame))")
        lastUsedCounter = useCounter
        peripheral?.writeValue(Data(frame), for: ch, type: type)
        if quiet { return }
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
        Task { @MainActor in
            if central.state == .poweredOn {
                // Bluetooth came back on — resume unless the user stopped on purpose.
                if !intentionalStop, !ready, subkey.count == 16, mac.count == 6 { start() }
            } else {
                add("BT status \(central.state.rawValue)")
            }
        }
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
        Task { @MainActor in state = "services"; peripheral.discoverServices([LinkaBLE.service, CBUUID(string: "180A"), CBUUID(string: "180F")]) }
    }
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            ready = false; state = "verbroken"; add("Verbinding verbroken.")
            didInitialStatusPing = false
            lastUsedCounter = nil
            if proximityUnlockEnabled, liveLocked == true { awayLatched = true; nearCount = 0 }
            ctxCounter = nil; ctxEncVer = nil
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
                // LINKA service + standard Device Info (0x180A) + Battery (0x180F).
                if s.uuid == LinkaBLE.service
                    || s.uuid == CBUUID(string: "180A")
                    || s.uuid == CBUUID(string: "180F") {
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
                // Standard Battery Level (0x2A19) — read once + subscribe if possible.
                if c.uuid == CBUUID(string: "2A19") {
                    peripheral.readValue(for: c)
                    add("Battery Service (0x2A19) gevonden — lokaal batterij uitlezen.")
                }
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
            // Standard Battery Level (0x2A19): single byte 0–100 %.
            if characteristic.uuid == CBUUID(string: "2A19") {
                if let b = data.first { batteryLevelBLE = Int(b); add("Batterij (BLE): \(b)%") }
                return
            }
            // Decode live telemetry: 0x0A motion/info packet, 0x02 status frame.
            parseInfoPacket(data)
            parseSettingReply(data)
            parseModemInfo(data)
            updateCounterFromReply(data)
            parseStatusFrame(data)
            // The command context is the 0x12-prefixed frame (encVer 2).
            if data.count >= 7, data[0] == 0x12, data[1] == 0x0B, crcOK(data) {
                ctxEncVer = Int(data[2])
                ctxCounter = UInt32(data[3]) | (UInt32(data[4]) << 8) | (UInt32(data[5]) << 16) | (UInt32(data[6]) << 24)
                add("CONTEXT: encVer \(ctxEncVer!), teller \(ctxCounter!)  [\(LinkaCrypto.toHex(data))]")
                // Once we have the context counter, ask for a status frame so
                // battery % and voltage populate automatically (once per connect).
                if !didInitialStatusPing {
                    didInitialStatusPing = true
                    Task { try? await Task.sleep(nanoseconds: 400_000_000); statePing() }
                }
            } else if characteristic.uuid == LinkaBLE.leoLog {
                // D31E0014 firmware debug log (ASCII) — the reliable signal.
                let s = String(bytes: data, encoding: .utf8) ?? LinkaCrypto.toHex(data)
                handleEvent(s)
                add("· \(s)")
            } else {
                if awaitingRead != nil || (data.count > 1 && data[1] != 0x0A && data[1] != 0x02) {
                    let label = awaitingRead ?? "frame"
                    // Capture EVERY frame in the window; the value frame may be
                    // the 2nd notification after the ack.
                    let hex = LinkaCrypto.toHex(data)
                    readFrames.append("\(label): \(hex)")
                    if readFrames.count > 40 { readFrames.removeFirst() }
                    lastReadLabel = label
                    add("READ(\(label)): \(hex)")
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
        Task { @MainActor in
            guard error == nil else { return }
            rssi = RSSI.intValue
            handleProximity(RSSI.intValue)
        }
    }
}
