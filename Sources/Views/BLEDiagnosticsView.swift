import SwiftUI
import UIKit

/// Scans for the lock over Bluetooth, connects, and shows its GATT profile +
/// incoming packets — so we can verify the protocol before writing commands.
struct BLEDiagnosticsView: View {
    let lockName: String?
    @Environment(\.dismiss) var dismiss
    @StateObject private var ble = BLEManager()

    var body: some View {
        NavigationStack {
            List {
            Group {
                Section {
                    HStack {
                        Text("Status").bold()
                        Spacer()
                        Text(ble.state.label).foregroundStyle(.secondary)
                    }
                    Button {
                        ble.startScan(nameHint: lockName)
                    } label: {
                        Label("Zoek & verbind met slot", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    Button(role: .destructive) { ble.stop() } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                } footer: {
                    Text("Zorg dat je vlak bij je slot bent. Zet het slot eventueel 'wakker' (beweeg het) zodat het adverteert.")
                }

                if !ble.discovered.isEmpty {
                    Section("Gevonden apparaten") {
                        ForEach(ble.discovered, id: \.name) { d in
                            HStack { Text(d.name); Spacer(); Text("\(d.rssi) dBm").foregroundStyle(.secondary) }
                                .font(.caption)
                        }
                    }
                }

                if let pkt = ble.lastPacketHex {
                    Section("Laatste statuspacket (data TX)") {
                        Text(pkt).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }

                if !ble.profile.isEmpty {
                    Section("GATT-profiel") {
                        ForEach(ble.profile.keys.sorted(), id: \.self) { svc in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(svc).font(.caption.bold()).textSelection(.enabled)
                                ForEach(ble.profile[svc] ?? [], id: \.self) { ch in
                                    Text("• \(ch)").font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Log") {
                    if ble.log.isEmpty {
                        Text("Nog geen log — tik op ‘Zoek & verbind met slot’.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button {
                            UIPasteboard.general.string = ble.fullLog()
                            Haptic.tap(.light)
                        } label: { Label("Kopieer log", systemImage: "doc.on.doc") }
                    }
                    ForEach(Array(ble.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .listRowBackground(Theme.cardFill)
        }
            .linkaScreen().navigationTitle("Bluetooth-diagnose")
            .navigationBarTitleDisplayMode(.inline)
            // Also when the sheet is swiped away: don't leave a scan running.
            .onDisappear { ble.stop() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Gereed") { ble.stop(); dismiss() }
                }
            }
        }
    }
}
