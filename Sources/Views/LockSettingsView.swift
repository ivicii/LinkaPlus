import SwiftUI
import UIKit

/// Full lock-settings screen. Parameter indices reverse-engineered from the
/// official app's LockController (confirmed against the working 106/5 = movement
/// alarm). Writes go over Bluetooth; the lock must be connected.
struct LockSettingsView: View {
    @ObservedObject var ble: BLEController
    let serial: String?
    @Environment(\.dismiss) var dismiss

    // On/off settings (remembered per lock)
    @State private var autoLock = false
    @State private var quickLock = false

    // Numeric settings (value sent on "Schrijf")
    @State private var bump = 5
    @State private var stall = 3
    @State private var alarmDelay = 5
    @State private var alarmTime = 30
    @State private var lockSleep = 30
    @State private var unlockSleep = 30
    @State private var rollAngle = 45
    @State private var tiltAngle = 45
    @State private var jostle = 5
    @State private var accelRate = 2
    @State private var pulseTap = 1

    // Advanced raw write
    @State private var rawIdx = ""
    @State private var rawVal = ""

    @State private var showDefaultConfirm = false
    @State private var showBondsConfirm = false
    @State private var copiedFrames = false

    private func frameLabel(_ hex: String) -> String {
        let h = hex.lowercased()
        if h.hasPrefix("1402") { return "ACK / bevestiging" }
        if h.hasPrefix("140a") { return "Statuspakket (0x0A)" }
        if h.hasPrefix("1412") || h.hasPrefix("12")  { return "Context (teller)" }
        return "Onbekend frame"
    }

    private var connected: Bool { ble.ready }

    var body: some View {
        NavigationStack {
            List {
                if !connected {
                    Section {
                        Label("Niet verbonden — ga dichtbij je slot. Instellingen zijn uitgeschakeld tot 'Verbonden'.",
                              systemImage: "antenna.radiowaves.left.and.right.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                commandResultRow

                Section("Vergrendeling") {
                    Toggle(isOn: Binding(
                        get: { autoLock },
                        set: { v in autoLock = v; LockPrefs.setBool(v, key: "autoLock", serial: serial); if connected { ble.setAutolock(v) } }
                    )) { Label("Auto-lock", systemImage: "lock.rotation") }
                    Toggle(isOn: Binding(
                        get: { quickLock },
                        set: { v in quickLock = v; LockPrefs.setBool(v, key: "quickLock", serial: serial); if connected { ble.setQuickLock(v) } }
                    )) { Label("Quick-lock", systemImage: "bolt.horizontal") }
                }
                .disabled(!connected)

                Section {
                    numeric("Bump-gevoeligheid", value: $bump, range: 1...20, icon: "waveform.path") { ble.setBumpThreshold($0) }
                    numeric("Stall-delay", value: $stall, range: 0...30, icon: "hourglass") { ble.setStall($0) }
                    numeric("Alarm-delay", value: $alarmDelay, range: 0...60, icon: "timer") { ble.setAlarmDelay($0) }
                    numeric("Alarm-tijd", value: $alarmTime, range: 0...255, icon: "alarm") { ble.setAlarmTime($0) }
                } header: {
                    Text("Alarm & gevoeligheid")
                } footer: {
                    Text("Eenheden zijn niet officieel gedocumenteerd — stel in en kijk naar het gedrag van je slot. De waarde wordt pas geschreven als je op ‘Schrijf’ tikt.")
                }
                .disabled(!connected)

                Section {
                    numeric("Roll-hoek (zijwaarts)", value: $rollAngle, range: 0...90, icon: "rotate.3d") { ble.setRollAngle($0) }
                    numeric("Tilt-hoek (voor/achter)", value: $tiltAngle, range: 0...90, icon: "gyroscope") { ble.setTiltAngle($0) }
                    numeric("Jostle (schudgevoeligheid)", value: $jostle, range: 0...30, icon: "waveform") { ble.setJostle($0) }
                    numeric("Accel data-rate", value: $accelRate, range: 0...10, icon: "speedometer") { ble.setAccelDataRate($0) }
                    numeric("Pulse-tap", value: $pulseTap, range: 0...10, icon: "hand.tap") { ble.setPulseTap($0) }
                } header: {
                    Text("Kanteling-alarm & gevoeligheid")
                } footer: {
                    Text("Hoek in graden waarbij het alarm afgaat als de fiets kantelt (roll = zijwaarts, tilt = voor/achter). Accel-datarate en pulse-tap regelen hoe fijn de sensor meet.")
                }
                .disabled(!connected)

                Section {
                    numeric("Lock-sleep", value: $lockSleep, range: 0...255, icon: "moon.zzz") { ble.setLockSleep($0) }
                    numeric("Unlock-sleep", value: $unlockSleep, range: 0...255, icon: "moon") { ble.setUnlockSleep($0) }
                } header: {
                    Text("Energie (sleep)")
                } footer: {
                    Text("Hoe lang het slot wacht voor het in slaapstand gaat. Langer = sneller reageren, meer batterijverbruik.")
                }
                .disabled(!connected)

                Section {
                    Button { ble.statePing() } label: { Label("State-ping (status opvragen)", systemImage: "dot.radiowaves.up.forward") }
                    Button { ble.reboot() } label: { Label("Herstart slot", systemImage: "arrow.clockwise.circle") }
                    Button { ble.sleepLock() } label: { Label("Slaapstand", systemImage: "moon.zzz") }
                } header: {
                    Text("Onderhoud")
                } footer: {
                    Text("Herstart start de slot-firmware opnieuw op. Slaapstand zet 'm in energiebesparing (ontwaakt bij beweging/BLE).")
                }
                .disabled(!connected)

                Section {
                    Button { ble.readPAC() } label: { Label("Lees PAC-code", systemImage: "number.square") }
                    Button { ble.readActuations() } label: { Label("Lees actuations (totaalteller)", systemImage: "number") }
                    if ble.readFrames.isEmpty {
                        Text("Nog geen frames. Tik op een leesknop.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(ble.readFrames.enumerated()), id: \.offset) { i, f in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(i + 1) · \(frameLabel(f))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(f)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        Button {
                            UIPasteboard.general.string = ble.readFrames.joined(separator: "\n")
                            Haptic.tap(.light)
                            copiedFrames = true
                        } label: {
                            Label(copiedFrames ? "Gekopieerd ✓" : "Kopieer alle frames",
                                  systemImage: copiedFrames ? "checkmark" : "doc.on.doc")
                        }
                    }
                } header: {
                    Text("Uitlezen (experimenteel)")
                } footer: {
                    Text("Na een lezing stuurt het slot een bevestiging (ACK, 1402…) plus een statuspakket (140a…). Tik \"Kopieer alle frames\" en plak ze in de chat — dan decodeer ik de PAC/teller.")
                }
                .disabled(!connected)

                Section {
                    HStack {
                        TextField("index", text: $rawIdx).keyboardType(.numberPad).frame(width: 70)
                        Divider()
                        TextField("waarde", text: $rawVal).keyboardType(.numberPad)
                        Button("Schrijf") {
                            if let i = Int(rawIdx), let v = Int(rawVal), connected { ble.writeSetting(idx: i, value: v) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connected || Int(rawIdx) == nil || Int(rawVal) == nil)
                    }
                } header: {
                    Text("Parameter schrijven (geavanceerd)")
                } footer: {
                    Text("Schrijf elke parameter-index + waarde rechtstreeks. Bekend: 1=PAC, 5=stall, 7=alarm-delay, 10=bump, 12=audio, 13=pulse-tap, 14=jostle, 16=accel-rate, 17=lock-sleep, 28=roll-hoek, 29=tilt-hoek, 30/50=unlock-sleep, 37=alarm-tijd, 55=quick-lock, 102=auto-lock, 106=beweeg-alarm. ⚠︎ Onbekende indexen/waarden op eigen risico.")
                }
                .disabled(!connected)

                Section {
                    Button(role: .destructive) { showDefaultConfirm = true } label: {
                        Label("Standaardinstellingen herstellen", systemImage: "arrow.counterclockwise")
                    }
                    Button(role: .destructive) { showBondsConfirm = true } label: {
                        Label("Bluetooth-koppelingen wissen", systemImage: "trash")
                    }
                } header: {
                    Text("Gevaarlijk")
                } footer: {
                    Text("Deze acties resetten instellingen of ontkoppelen apparaten. Gebruik met beleid.")
                }
                .disabled(!connected)
            }
            .navigationTitle("Slotinstellingen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sluit") { dismiss() } } }
            .alert("Standaardinstellingen herstellen?", isPresented: $showDefaultConfirm) {
                Button("Annuleer", role: .cancel) {}
                Button("Herstellen", role: .destructive) { ble.defaultSettings() }
            } message: {
                Text("Dit zet alle slotinstellingen terug naar fabrieksstandaard.")
            }
            .alert("Koppelingen wissen?", isPresented: $showBondsConfirm) {
                Button("Annuleer", role: .cancel) {}
                Button("Wissen", role: .destructive) { ble.deleteBonds() }
            } message: {
                Text("Dit verwijdert alle Bluetooth-koppelingen van het slot. Je moet daarna opnieuw verbinden.")
            }
            .onChange(of: ble.readFrames.count) { _ in copiedFrames = false }
            .onAppear {
                autoLock = LockPrefs.bool("autoLock", serial: serial)
                quickLock = LockPrefs.bool("quickLock", serial: serial)
            }
        }
    }

    @ViewBuilder
    private var commandResultRow: some View {
        switch ble.commandResult {
        case .success(let n):
            Label("\(n) gelukt", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .rejected:
            Label("Geweigerd — probeer opnieuw", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        case .blocked(let n):
            Label("\(n): niet gelukt", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        case .timeout:
            Label("Geen reactie van het slot", systemImage: "clock.badge.exclamationmark").foregroundStyle(.secondary).font(.callout)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private func numeric(_ title: String, value: Binding<Int>, range: ClosedRange<Int>,
                         icon: String, write: @escaping (Int) -> Void) -> some View {
        HStack {
            Stepper(value: value, in: range) {
                Label("\(title): \(value.wrappedValue)", systemImage: icon)
            }
            Button("Schrijf") { write(value.wrappedValue) }
                .buttonStyle(.bordered).font(.footnote)
        }
    }
}
