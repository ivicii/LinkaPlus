import SwiftUI

/// Phase-2 open/close over Bluetooth, with knobs + a shareable log so we can
/// iterate against the real lock.
struct BLEControlView: View {
    let serial: String
    let lockName: String?
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @ObservedObject private var ble = BLEController.shared
    @State private var keyLoaded = BLEController.shared.ready
    @State private var loadError: String?
    @State private var channel = 0
    @State private var counterOffset = 0

    var body: some View {
        NavigationStack {
            List {
            Group {
                Section {
                    HStack { Text("Status").bold(); Spacer(); Text(ble.state).foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Laatste melding (firmware)").font(.caption).foregroundStyle(.secondary)
                        Text(ble.lastEvent).font(.system(.caption, design: .monospaced))
                    }
                    if let w = ble.winner {
                        Label("Werkt: \(w)", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success)
                    }
                    HStack { Text("Context teller"); Spacer(); Text(ble.ctxCounter.map(String.init) ?? "–").foregroundStyle(.secondary) }
                    if !keyLoaded {
                        Button { Task { await loadKeyAndStart() } } label: {
                            Label("Sleutel laden & verbinden", systemImage: "key.radiowaves.forward")
                        }
                    } else {
                        Button { ble.start() } label: { Label("(Her)verbinden", systemImage: "arrow.clockwise") }
                    }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(Theme.danger) }
                } footer: {
                    Text("Ga vlak bij je slot staan en beweeg het even zodat het adverteert.")
                }

                Section("Bediening") {
                    Button {
                        ble.channel = channel; ble.counterOffset = counterOffset; ble.unlock()
                    } label: { Label("Open (unlock)", systemImage: "lock.open") }
                        .disabled(!ble.ready || ble.testing)
                    Button {
                        ble.channel = channel; ble.counterOffset = counterOffset; ble.lock()
                    } label: { Label("Sluit (lock)", systemImage: "lock") }
                        .disabled(!ble.ready || ble.testing)
                }

                Section {
                    if ble.testing {
                        Button(role: .destructive) { ble.stopTest() } label: {
                            HStack { ProgressView(); Label("Stop auto-test", systemImage: "stop.circle") }
                        }
                    } else {
                        Button { ble.autoTest() } label: {
                            Label("Auto-test: zoek de werkende sleutel", systemImage: "wand.and.stars")
                        }
                        .disabled(!ble.ready)
                    }
                } header: {
                    Text("Automatisch testen")
                } footer: {
                    Text("Probeert maximaal 4 sleutels met een onschuldige status-ping (het slot gaat hierbij niet open) en stopt na 2 weigeringen, zodat het slot niet in lockout gaat. Deel daarna de log.")
                }

                Section {
                    Picker("Schrijfkanaal", selection: $channel) {
                        Text("D31E0002").tag(0); Text("D31E0016").tag(1)
                    }
                    Stepper("Teller-offset: \(counterOffset)", value: $counterOffset, in: -2...2)
                } header: {
                    Text("Iteratie-opties")
                } footer: {
                    Text("Werkt het niet, probeer kanaal D31E0016 of een teller-offset. Deel daarna de log.")
                }

                Section {
                    ShareLink(item: ble.fullLog()) {
                        Label("Deel log", systemImage: "square.and.arrow.up")
                    }
                } header: {
                    Text("Log")
                }

                Section {
                    ForEach(Array(ble.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Theme.cardFill)
        }
            .linkaScreen().navigationTitle("Bediening (BLE)")
            .navigationBarTitleDisplayMode(.inline)
            // The test knobs live on the shared controller: put them back, or every
            // later command (settings, widgets) would use this channel/offset too.
            .onDisappear {
                ble.channel = 0; ble.counterOffset = 0
                if ble.testing { ble.stopTest() }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Gereed") { dismiss() }
                }
            }
        }
    }

    private func loadKeyAndStart() async {
        loadError = nil
        var keys: AccessKeys?
        do {
            keys = try await api.checkKeyStatus(serial: serial, auth: session.identity()).key
            if let k = keys, k.commandKey != nil { LockCache.saveKeys(k, serial: serial) }
        } catch {
            // Cloud unreachable → fall back to the key cached on this phone.
            keys = LockCache.loadKeys(serial: serial)
            if keys == nil {
                loadError = (error as? LocalizedError)?.errorDescription ?? "Sleutel laden mislukt: \(error.localizedDescription)"
                return
            }
        }
        guard let k = keys, k.commandKey != nil else { loadError = "Geen bruikbare access-key gevonden."; return }
        ble.configure(keys: k, serial: serial, nameHint: lockName)
        keyLoaded = true
        ble.start()
    }
}
