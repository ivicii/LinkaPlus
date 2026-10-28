import SwiftUI

/// Phase-2 open/close over Bluetooth. Fetches the access key, connects, reads
/// the live counter, and sends encrypted unlock/lock commands. Includes small
/// knobs (slot, counter offset) so we can iterate against the real lock.
struct BLEControlView: View {
    let serial: String
    let lockName: String?
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @StateObject private var ble = BLEController()
    @State private var keyLoaded = false
    @State private var loadError: String?
    @State private var slot = 0
    @State private var counterOffset = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack { Text("Status").bold(); Spacer(); Text(ble.state).foregroundStyle(.secondary) }
                    HStack {
                        Text("encVer"); Spacer()
                        Text(ble.encVer.map(String.init) ?? "–").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Teller"); Spacer()
                        Text(ble.counter.map(String.init) ?? "–").foregroundStyle(.secondary)
                    }
                    if !keyLoaded {
                        Button { Task { await loadKeyAndStart() } } label: {
                            Label("Sleutel laden & verbinden", systemImage: "key.radiowaves.forward")
                        }
                    } else {
                        Button { ble.start() } label: {
                            Label("(Her)verbinden", systemImage: "arrow.clockwise")
                        }
                    }
                    if let loadError { Text(loadError).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text("Ga vlak bij je slot staan en beweeg het even zodat het adverteert.")
                }

                Section("Bediening") {
                    Button {
                        ble.slot = slot; ble.counterOffset = counterOffset; ble.unlock()
                    } label: { Label("Open (unlock)", systemImage: "lock.open") }
                        .disabled(!ble.ready)
                    Button {
                        ble.slot = slot; ble.counterOffset = counterOffset; ble.lock()
                    } label: { Label("Sluit (lock)", systemImage: "lock") }
                        .disabled(!ble.ready)
                }

                Section {
                    Picker("Key slot", selection: $slot) {
                        Text("SLOT1").tag(0); Text("SLOT2").tag(1)
                    }
                    Stepper("Teller-offset: \(counterOffset)", value: $counterOffset, in: -1...2)
                } header: {
                    Text("Iteratie-opties")
                } footer: {
                    Text("Als unlock niet werkt, probeer SLOT2 of teller-offset +1. De respons verschijnt in de log.")
                }

                Section("Log") {
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
            guard let ck = status.key?.commandKey else {
                loadError = "Geen bruikbare access-key gevonden."
                return
            }
            ble.configure(keyHex: ck.hex, admin: ck.admin, serial: serial, nameHint: lockName)
            keyLoaded = true
            ble.start()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Sleutel laden mislukt: \(error)"
        }
    }
}
