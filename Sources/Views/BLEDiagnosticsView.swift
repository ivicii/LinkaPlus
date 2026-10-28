import SwiftUI

/// Scans for the lock over Bluetooth, connects, and shows its GATT profile +
/// incoming packets — so we can verify the protocol before writing commands.
struct BLEDiagnosticsView: View {
    let lockName: String?
    @Environment(\.dismiss) var dismiss
    @StateObject private var ble = BLEManager()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Status").bold()
                        Spacer()
                        Text(ble.state.rawValue).foregroundStyle(.secondary)
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
                    ForEach(Array(ble.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Bluetooth-diagnose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sluit") { ble.stop(); dismiss() }
                }
            }
        }
    }
}
