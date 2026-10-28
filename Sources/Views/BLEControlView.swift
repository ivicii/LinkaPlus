import SwiftUI

/// Phase-2 open/close over Bluetooth, with knobs + a shareable log so we can
/// iterate against the real lock.
struct BLEControlView: View {
    let serial: String
    let lockName: String?
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @StateObject private var ble = BLEController()
    @State private var keyLoaded = false
    @State private var loadError: String?
    @State private var channel = 0
    @State private var counterOffset = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Text("Status").bold(); Spacer(); Text(ble.state).foregroundStyle(.secondary) }
                    HStack { Text("Context encVer"); Spacer(); Text(ble.ctxEncVer.map(String.init) ?? "–").foregroundStyle(.secondary) }
                    HStack { Text("Context teller"); Spacer(); Text(ble.ctxCounter.map(String.init) ?? "–").foregroundStyle(.secondary) }
                    if !keyLoaded {
                        Button { Task { await loadKeyAndStart() } } label: {
                            Label("Sleutel laden & verbinden", systemImage: "key.radiowaves.forward")
                        }
                    } else {
                        Button { ble.start() } label: { Label("(Her)verbinden", systemImage: "arrow.clockwise") }
                    }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text("Ga vlak bij je slot staan en beweeg het even zodat het adverteert.")
                }

                Section("Bediening") {
                    Button {
                        ble.channel = channel; ble.counterOffset = counterOffset; ble.unlock()
                    } label: { Label("Open (unlock)", systemImage: "lock.open") }
                        .disabled(!ble.ready)
                    Button {
                        ble.channel = channel; ble.counterOffset = counterOffset; ble.lock()
                    } label: { Label("Sluit (lock)", systemImage: "lock") }
                        .disabled(!ble.ready)
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
            .navigationTitle("Bediening (BLE)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sluit") { ble.stop(); dismiss() }
                }
            }
        }
    }

    private func loadKeyAndStart() async {
        loadError = nil
        do {
            let status = try await api.checkKeyStatus(serial: serial, auth: session.identity())
            guard let ck = status.key?.commandKey else { loadError = "Geen bruikbare access-key gevonden."; return }
            ble.configure(keyHex: ck.hex, admin: ck.admin, serial: serial, nameHint: lockName)
            keyLoaded = true
            ble.start()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Sleutel laden mislukt: \(error)"
        }
    }
}
