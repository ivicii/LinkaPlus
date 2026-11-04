import SwiftUI
import UIKit

// MARK: - Reusable rows (values are READ from the lock, not remembered)

/// Stepper for a numeric lock setting. Shows what the lock reports, lets you
/// edit a draft, and applies it with one tap; the lock is read back afterwards.
struct SettingStepperRow: View {
    let title: String
    let unit: String
    let icon: String
    let idx: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    @ObservedObject var ble: BLEController
    let enabled: Bool
    let apply: (Int) -> Void

    @State private var draft = 0
    @State private var edited = false

    var body: some View {
        let current = ble.settingValues[idx]
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(current.map { "\($0) \(unit)" } ?? "nog niet gelezen")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Stepper(value: Binding(get: { draft }, set: { draft = $0; edited = ($0 != current) }),
                        in: range, step: step) {
                    Text("\(draft) \(unit)").monospacedDigit().font(.callout)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Button("Toepassen") { apply(draft); edited = false }
                    .buttonStyle(.bordered)
                    .disabled(!enabled || current == nil || draft == current)
            }
        }
        .padding(.vertical, 2)
        .onAppear { draft = min(max(current ?? range.lowerBound, range.lowerBound), range.upperBound) }
        .onChange(of: current) { v in
            if let v, !edited { draft = min(max(v, range.lowerBound), range.upperBound) }
        }
        .onChange(of: ble.commandResult) { _ in
            // After a write (accepted or not) show what the lock really has.
            if !edited, let c = current { draft = min(max(c, range.lowerBound), range.upperBound) }
        }
    }
}

/// On/off setting backed by a 0/1 lock parameter, with read-back verification.
struct SettingToggleRow: View {
    let title: String
    let icon: String
    let idx: Int
    @ObservedObject var ble: BLEController
    let enabled: Bool
    let apply: (Bool) -> Void

    @State private var local: Bool?

    var body: some View {
        let current = ble.settingValues[idx].map { $0 != 0 }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { local ?? current ?? false },
                set: { v in local = v; apply(v) }
            )) { Label(title, systemImage: icon) }
            .disabled(!enabled)
            if let local, let current, local != current {
                Label("Slot meldt “\(current ? "aan" : "uit")” — nog niet overgenomen.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.warn)
            } else if let current {
                Text("Slot meldt: \(current ? "aan" : "uit") ✓").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Nog niet uitgelezen").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: current) { v in if v != nil, local == v { local = nil } }
        .onChange(of: ble.reading) { r in if !r { local = nil } }
    }
}

// MARK: - Settings pages

/// One page of lock settings. The settings menu is split into small, focused
/// pages instead of one long scroll.
struct SlotSettingsPage: View {
    enum Kind { case security, behaviour, sensitivity, maintenance }

    let kind: Kind
    @ObservedObject var ble: BLEController
    let serial: String?

    @State private var pacInput = ""
    @State private var rawIdx = ""
    @State private var rawVal = ""
    @State private var showDefaultConfirm = false
    @State private var showBondsConfirm = false
    @State private var showAntiTheft = false
    @State private var copied = false

    private var connected: Bool { ble.ready }

    /// Which parameters this page shows (read automatically when it opens).
    private var indices: [Int] {
        switch kind {
        case .security:    return [1, 106, 7, 37]
        case .behaviour:   return [55, 11, 12, 102, 17, 30]
        case .sensitivity: return [10, 14, 13, 28, 29, 15, 16]
        case .maintenance: return [5, 45]
        }
    }

    private var title: String {
        switch kind {
        case .security:    return "Beveiliging & alarm"
        case .behaviour:   return "Gedrag & geluid"
        case .sensitivity: return "Gevoeligheid"
        case .maintenance: return "Onderhoud & uitlezen"
        }
    }

    private static let counterNames: [(Int, String)] = [
        (2, "Actuaties (totaal)"), (3, "Slotfouten"), (31, "Foute-PAC limiet (idx 31)"),
        (32, "Foute-versleuteling limiet (idx 32)"), (33, "Tamper-bits (idx 33)"),
    ]
    private static let allIdx = [1, 2, 3, 5, 7, 10, 11, 12, 13, 14, 15, 16, 17, 28, 29, 30, 31, 32, 33, 37, 45, 55, 102, 106]

    var body: some View {
        List {
            if !connected {
                Section {
                    Label("Niet verbonden — ga dichtbij je slot. Wijzigen kan pas als het slot verbonden is.",
                          systemImage: "antenna.radiowaves.left.and.right.slash")
                        .font(.footnote).foregroundStyle(Theme.warn)
                }
            }
            if let r = ble.commandResult { Section { resultLabel(r) } }
            content
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if ble.reading { ProgressView() }
                else {
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!connected)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: ble.ready) { r in if r { load() } }
        .alert("Standaardinstellingen herstellen?", isPresented: $showDefaultConfirm) {
            Button("Annuleer", role: .cancel) {}
            Button("Herstellen", role: .destructive) { ble.defaultSettings() }
        } message: { Text("Dit zet alle slotinstellingen terug naar fabrieksstandaard.") }
        .alert("Koppelingen wissen?", isPresented: $showBondsConfirm) {
            Button("Annuleer", role: .cancel) {}
            Button("Wissen", role: .destructive) { ble.deleteBonds() }
        } message: { Text("Dit verwijdert alle Bluetooth-koppelingen van het slot. Je moet daarna opnieuw verbinden.") }
        .confirmationDialog("Anti-diefstal", isPresented: $showAntiTheft, titleVisibility: .visible) {
            Button("Anti-diefstal uitzetten") { ble.antiTheft(reset: false) }
            Button("Anti-diefstal resetten") { ble.antiTheft(reset: true) }
            Button("Annuleer", role: .cancel) {}
        } message: { Text("Officiële commando’s van de LINKA-app (command 21).") }
    }

    private func load() {
        guard connected else { return }
        ble.readSettings(indices)
    }

    @ViewBuilder
    private func resultLabel(_ r: BLEController.CommandResult) -> some View {
        switch r {
        case .success(let n):
            Label("\(n) gelukt", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.callout)
        case .rejected:
            Label("Geweigerd — probeer opnieuw", systemImage: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.callout)
        case .blocked(let n):
            Label("\(n): niet gelukt", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.callout)
        case .timeout:
            Label("Geen reactie van het slot", systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary).font(.callout)
        }
    }

    @ViewBuilder
    private func stepper(_ title: String, unit: String, icon: String, idx: Int,
                         range: ClosedRange<Int>, step: Int = 1, apply: @escaping (Int) -> Void) -> some View {
        SettingStepperRow(title: title, unit: unit, icon: icon, idx: idx, range: range, step: step,
                          ble: ble, enabled: connected, apply: apply)
    }

    private var pacText: String {
        if let p = ble.lockPAC { return String(format: "%04d", p) }
        if let s = LockPrefs.pac(serial: serial) { return String(format: "%04d", s) + " (laatst ingesteld)" }
        return "–"
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .security:
            Section {
                HStack {
                    Label("PAC-code op slot", systemImage: "number.square")
                    Spacer()
                    Text(pacText).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack {
                    TextField("nieuwe 4 cijfers", text: $pacInput)
                        .keyboardType(.numberPad)
                        .onChange(of: pacInput) { v in pacInput = String(v.filter(\.isNumber).prefix(4)) }
                    Button("Instellen") {
                        if let code = Int(pacInput) {
                            ble.setPAC(code)
                            LockPrefs.setPAC(code, serial: serial)
                            pacInput = ""
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!connected || pacInput.count < 4)
                }
            } header: { Text("PAC-code") } footer: {
                Text("De tapcode om het slot zonder telefoon te openen. De app leest hem rechtstreeks uit het slot (GET_SETTING).")
            }
            Section {
                SettingToggleRow(title: "Bewegingsmelding", icon: "bell.badge", idx: 106,
                                 ble: ble, enabled: connected) { ble.setMovementAlarm($0) }
            } footer: {
                Text("Het slot meldt beweging terwijl het dicht is (officiële instelling, index 106).")
            }
            Section {
                stepper("Alarm-vertraging", unit: "s", icon: "timer", idx: 7, range: 0...60) { ble.setAlarmDelay($0) }
                stepper("Alarm-duur (experimenteel)", unit: "s", icon: "alarm", idx: 37, range: 0...255) { ble.setAlarmTime($0) }
            } header: { Text("Alarm") } footer: {
                Text("Index 37 staat niet in de officiële tabel — de uitleesregel hierboven laat zien of het slot de waarde echt overneemt.")
            }

        case .behaviour:
            Section {
                SettingToggleRow(title: "Quick-lock", icon: "bolt.horizontal", idx: 55,
                                 ble: ble, enabled: connected) { ble.setAllowUnconnLock($0) }
                SettingToggleRow(title: "Geluid & pieptonen", icon: "speaker.wave.2", idx: 12,
                                 ble: ble, enabled: connected) { ble.setAudio($0) }
            } header: { Text("Knop & geluid") } footer: {
                Text("Quick-lock: knop 1,5 s ingedrukt houden sluit het slot, ook zonder telefoon (index 55, volgens LINKA-documentatie).\nMet je telefoon verbonden opent én sluit dezelfde knop. 4 s vasthouden (LED paars) = PAC-code invoeren.")
            }
            Section {
                stepper("Min. signaal telefoon", unit: "-dBm", icon: "wifi", idx: 11, range: 40...100) { ble.setUnlockRSSIMin($0) }
            } header: { Text("Openen met knop") } footer: {
                Text("Met je telefoon verbonden opent lang drukken het slot. Dit bepaalt hoe dichtbij je telefoon moet zijn (firmware RSSI_UNLOCK_MIN, index 11): lager getal = dichterbij nodig. ±60 ≈ 1–2 m, ±75 ≈ 5 m, ±90 ≈ 10+ m. Zet hem laag, anders kan iemand anders je slot openen terwijl jij met je telefoon in de buurt bent.")
            }
            Section {
                Toggle(isOn: Binding(
                    get: { ble.proximityUnlockEnabled },
                    set: { v in ble.proximityUnlockEnabled = v; LockPrefs.setBool(v, key: "proximityUnlock", serial: serial) }
                )) { Label("Auto-unlock (nabijheid)", systemImage: "figure.walk.arrival") }
                if ble.proximityUnlockEnabled {
                    Label(ble.awayLatched ? "Buiten bereik geweest — opent bij terugkomst" : "Wacht tot je weggaat",
                          systemImage: ble.awayLatched ? "arrow.uturn.backward.circle" : "clock")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Auto-unlock") } footer: {
                Text("Slot dicht → je loopt weg (verbinding weg of signaal zwak) → komt terug binnen ±5 m → de app opent het slot één keer. Werkt alleen als LinkaPlus actief verbonden is; op de achtergrond kan iOS het scannen beperken. Standaard uit — een slot dat vanzelf opengaat is minder veilig.")
            }
            Section {
                SettingToggleRow(title: "Autolock", icon: "lock.badge.clock", idx: 102,
                                 ble: ble, enabled: connected) { ble.setQuickLock($0) }
            } header: { Text("Autolock") } footer: {
                Text("Volgens de LINKA-documentatie: het slot sluit zichzelf na een periode zonder beweging (index 102; de officiële app schrijft 20 = aan). Werkt alleen als de beugel vrij kan sluiten — laat hem uit als je je fiets vaak even open laat staan.")
            }
            Section {
                stepper("Lock-sleep", unit: "s", icon: "moon.zzz", idx: 17, range: 600...86400, step: 60) { ble.setLockSleep($0) }
                stepper("Unlock-sleep", unit: "s", icon: "moon", idx: 30, range: 600...86400, step: 60) { ble.setUnlockSleep($0) }
            } header: { Text("Slaapstand") } footer: {
                Text("Hoe lang het slot wacht voordat het in slaap valt. Langer = sneller reageren, meer batterijverbruik.")
            }

        case .sensitivity:
            Section {
                stepper("Bump-drempel", unit: "mg", icon: "waveform.path", idx: 10, range: 0...255) { ble.setBumpThreshold($0) }
                stepper("Pulse-drempel", unit: "mg", icon: "hand.tap", idx: 13, range: 0...255) { ble.setPulseTap($0) }
                stepper("Hamer-drempel", unit: "mG", icon: "hammer", idx: 15, range: 0...2000, step: 10) { ble.setHammer($0) }
                stepper("Jostle-venster", unit: "×100 ms", icon: "waveform", idx: 14, range: 0...50) { ble.setJostle($0) }
            } header: { Text("Schokken & trillingen") } footer: {
                Text("Drempels in milli-g: lager = gevoeliger.")
            }
            Section {
                stepper("Roll-alarm", unit: "°", icon: "rotate.3d", idx: 28, range: 0...90) { ble.setRollAngle($0) }
                stepper("Pitch-alarm", unit: "°", icon: "gyroscope", idx: 29, range: 0...90) { ble.setTiltAngle($0) }
                stepper("Sensor-datarate", unit: "", icon: "speedometer", idx: 16, range: 0...10) { ble.setAccelDataRate($0) }
            } header: { Text("Kanteling") } footer: {
                Text("Hoek waarbij het alarm afgaat. Datarate bepaalt hoe vaak de sensor meet.")
            }

        case .maintenance:
            Section {
                Button { ble.statePing() } label: { Label("Status opvragen", systemImage: "dot.radiowaves.up.forward") }
                Button { ble.sleepLock() } label: { Label("Slaapstand", systemImage: "moon.zzz") }
                Button { ble.reboot() } label: { Label("Herstart slot", systemImage: "arrow.clockwise.circle") }
            } header: { Text("Acties") }
            .disabled(!connected)

            Section {
                stepper("Stall-motorstroom", unit: "mA", icon: "bolt.fill", idx: 5, range: 0...2000, step: 10) { ble.setStallCurrent($0) }
                stepper("Stall-vertraging", unit: "×100 ms", icon: "hourglass", idx: 45, range: 0...50) { ble.setStallDelay($0) }
            } header: { Text("Motor") } footer: {
                Text("Wanneer het slot de motor als ‘vastgelopen’ beschouwt. Alleen aanpassen als het slot onbetrouwbaar sluit.")
            }

            Section {
                Button {
                    ble.readSettings(Self.allIdx)
                } label: {
                    HStack {
                        Label("Alles uitlezen", systemImage: "square.and.arrow.down")
                        if ble.reading { Spacer(); ProgressView() }
                    }
                }
                .disabled(!connected || ble.reading)
                ForEach(Self.counterNames, id: \.0) { item in
                    HStack {
                        Text(item.1)
                        Spacer()
                        Text(ble.settingValues[item.0].map { String($0) } ?? "–").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if !ble.settingValues.isEmpty {
                    Button {
                        UIPasteboard.general.string = ble.settingValues.sorted { $0.key < $1.key }
                            .map { "idx \($0.key) = \($0.value)  (v2 \(ble.settingValues2[$0.key] ?? 0))" }.joined(separator: "\n")
                        Haptic.tap(.light); copied = true
                    } label: {
                        Label(copied ? "Gekopieerd ✓" : "Kopieer alle waarden", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
            } header: { Text("Uitlezen") } footer: {
                Text("Actuaties en veiligheidstellers (foute PAC- en versleutelingspogingen) rechtstreeks uit het slot.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = ble.fullLog()
                    Haptic.tap(.light)
                } label: { Label("Kopieer volledige log", systemImage: "doc.on.doc") }
            } footer: { Text("Plak de log in de chat als iets niet werkt (bijv. instellingen lezen).") }

            if !ble.readFrames.isEmpty {
                Section("Laatste frames (diagnose)") {
                    ForEach(Array(ble.readFrames.suffix(8).enumerated()), id: \.offset) { _, f in
                        Text(f).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = ble.readFrames.joined(separator: "\n")
                        Haptic.tap(.light)
                    } label: { Label("Kopieer frames", systemImage: "doc.on.doc") }
                }
            }

            Section {
                HStack {
                    TextField("index", text: $rawIdx).keyboardType(.numberPad).frame(width: 70)
                    Divider()
                    TextField("waarde", text: $rawVal).keyboardType(.numbersAndPunctuation)
                    Button("Schrijf") {
                        if let i = Int(rawIdx), let v = Int(rawVal) { ble.writeSetting(idx: i, value: v) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!connected || Int(rawIdx) == nil || Int(rawVal) == nil)
                }
            } header: { Text("Parameter schrijven") } footer: {
                Text("Schrijf elke index + waarde rechtstreeks; daarna wordt hij teruggelezen. ⚠︎ Onbekende indexen op eigen risico.")
            }

            Section {
                Button(role: .destructive) { showAntiTheft = true } label: {
                    Label("Anti-diefstal uit / reset", systemImage: "shield.slash")
                }
                Button(role: .destructive) { showDefaultConfirm = true } label: {
                    Label("Standaardinstellingen herstellen", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) { showBondsConfirm = true } label: {
                    Label("Bluetooth-koppelingen wissen", systemImage: "trash")
                }
            } header: { Text("Gevaarlijk") } footer: {
                Text("Deze acties resetten instellingen of ontkoppelen apparaten. Gebruik met beleid.")
            }
            .disabled(!connected)
        }
    }
}
