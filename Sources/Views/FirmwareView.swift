import SwiftUI

/// Fetches the firmware LINKA would flash (consumer_app_version) and lets you
/// download the Nordic DFU .zip to inspect it. The lock itself only accepts
/// Nordic Secure DFU (signed) images, so this is for analysis, not reflashing.
struct FirmwareView: View {
    @ObservedObject var ble: BLEController
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @State private var info: ConsumerAppVersion?
    @State private var loading = false
    @State private var error: String?
    @State private var downloading = false
    @State private var downloadedURL: URL?
    @State private var downloadError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Jouw slot") {
                    row("Huidige firmware", ble.fwRevision ?? (ble.ready ? "uitlezen…" : "verbind via Bluetooth"))
                    if let cur = ble.fwRevision, let avail = info?.leo2_firmware_version {
                        if cur == avail {
                            Label("Up-to-date", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green).font(.callout)
                        } else {
                            Label("Beschikbaar via app: \(avail)", systemImage: "arrow.up.circle.fill")
                                .foregroundStyle(Theme.accent).font(.callout)
                        }
                    }
                }

                if loading && info == nil {
                    HStack { ProgressView(); Text("Firmware-info ophalen…").foregroundStyle(.secondary) }
                } else if let info {
                    Section("LEO2-firmware (app-kanaal)") {
                        row("Versie", info.leo2_firmware_version)
                        row("Datum", info.leo2_firmware_date)
                        if let d = info.leo2_firmware_desc, !d.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Omschrijving").font(.caption).foregroundStyle(.secondary)
                                Text(d).font(.callout)
                            }
                        }
                        if let url = info.leo2_firmware_url, !url.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download-URL").font(.caption).foregroundStyle(.secondary)
                                Text(url).font(.caption2).textSelection(.enabled).foregroundStyle(.blue)
                            }
                            downloadControls(url: url, version: info.leo2_firmware_version)
                        } else {
                            Text("Geen firmware-URL in het antwoord.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary).font(.callout)
                        Button("Opnieuw proberen") { Task { await load() } }
                    }
                }

                Section {
                    Text("Dit is het officiële app-kanaal (BLE-DFU). Daarnaast heeft het slot een apart cellulair OTA-kanaal (update_leo_ota_*.bin via de modem) dat alleen LINKA's cloud triggert — dat verklaart waarom er op de server nieuwere builds staan dan hier. De firmware is een Nordic Secure-DFU-pakket (signed): te analyseren, niet te wijzigen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Firmware")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Sluit") { dismiss() } } }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func downloadControls(url: String, version: String?) -> some View {
        if let f = downloadedURL {
            ShareLink(item: f) {
                Label("Deel / bewaar firmware (.zip)", systemImage: "square.and.arrow.up")
            }
        } else {
            Button {
                Task { await download(url: url, version: version) }
            } label: {
                HStack {
                    if downloading { ProgressView() }
                    Label("Download firmware (.zip)", systemImage: "arrow.down.circle")
                }
            }
            .disabled(downloading)
        }
        if let downloadError {
            Text(downloadError).font(.caption).foregroundStyle(.red)
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value?.isEmpty == false ? value! : "–")
        }
        .font(.callout)
    }

    private func load() async {
        loading = true; error = nil
        do {
            info = try await api.consumerAppVersion(auth: session.identity())
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    private func download(url: String, version: String?) async {
        downloading = true; downloadError = nil
        let name = (version?.isEmpty == false ? version! : "leo2_firmware")
            .replacingOccurrences(of: "/", with: "_")
        let fileName = name.hasSuffix(".zip") ? name : name + ".zip"
        do {
            downloadedURL = try await api.downloadFile(from: url, suggestedName: fileName)
        } catch {
            downloadError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        downloading = false
    }
}
