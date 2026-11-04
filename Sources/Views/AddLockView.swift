import SwiftUI

/// "Slot toevoegen": scan for a LEO2, then pair it like the official app.
struct AddLockView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    @StateObject private var pc = PairingController()
    var onDone: () -> Void

    @State private var confirm: PairingController.Found?

    private var knownSerials: Set<String> { Set(LockCache.loadLocks().compactMap { $0.serial_no?.uppercased() }) }

    var body: some View {
        NavigationStack {
            List {
                if !pc.busy && pc.steps.isEmpty {
                    Section {
                        if pc.found.isEmpty {
                            HStack {
                                if pc.scanning { ProgressView() }
                                Text(pc.scanning ? "Zoeken naar sloten…" : "Tik op Zoeken").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(pc.found) { f in
                            let mine = f.mac.map { knownSerials.contains($0.uppercased()) } ?? false
                            Button { confirm = f } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(f.name).font(.headline)
                                        Text(f.mac ?? "MAC onbekend").font(.caption.monospaced()).foregroundStyle(.secondary)
                                        if mine { Text("Staat al in je lijst").font(.caption2).foregroundStyle(Theme.success) }
                                    }
                                    Spacer()
                                    Text("\(f.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(f.mac == nil)
                        }
                    } header: { Text("Sloten in de buurt") } footer: {
                        Text("Druk op de knop van het nieuwe slot zodat het wakker is en houd je telefoon er vlak bij. Een slot dat al met je telefoon verbonden is, verschijnt hier niet.")
                    }
                }

                if !pc.steps.isEmpty {
                    Section("Voortgang") {
                        ForEach(Array(pc.steps.enumerated()), id: \.offset) { _, s in
                            Text(s).font(.callout)
                        }
                        if pc.busy { HStack { ProgressView(); Text("Bezig — blijf bij het slot") } }
                    }
                }

                if let e = pc.error {
                    Section {
                        Text(e).foregroundStyle(Theme.danger)
                        if pc.canResume {
                            Button { pc.resume() } label: { Label("Hervatten", systemImage: "arrow.clockwise") }
                        }
                        if pc.needsPermissionRequest {
                            Button { pc.requestAccess(auth: session.identity()) } label: {
                                Label("Vraag de eigenaar om toegang", systemImage: "person.badge.key")
                            }
                        }
                    }
                }

                if pc.finished {
                    Section {
                        Button {
                            onDone(); dismiss()
                        } label: { Label("Klaar", systemImage: "checkmark.circle.fill") }
                    }
                }
            }
            .navigationTitle("Slot toevoegen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Sluit") { pc.stopScan(); if pc.finished { onDone() }; dismiss() }
                        .disabled(pc.busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !pc.busy && pc.steps.isEmpty {
                        Button(pc.scanning ? "Stop" : "Zoeken") { pc.scanning ? pc.stopScan() : pc.startScan() }
                    }
                }
            }
            .interactiveDismissDisabled(pc.busy)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { pc.startScan() } }
            .alert("Dit slot koppelen?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
                Button("Annuleer", role: .cancel) { confirm = nil }
                Button("Koppelen") { if let f = confirm { pc.pair(f, auth: session.identity()) }; confirm = nil }
            } message: {
                Text("\(confirm?.name ?? "") \(confirm?.mac ?? "")\n\nDe app schrijft nieuwe sleutels in het slot (zoals de officiële app). Eerst wordt gecontroleerd of het slot de startsleutel accepteert; lukt dat niet, dan wordt er niets geschreven. Blijf tijdens het koppelen bij het slot.")
            }
        }
    }
}
