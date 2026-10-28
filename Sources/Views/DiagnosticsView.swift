import SwiftUI

/// Runs a battery of candidate endpoints against the live API with the user's
/// token and shows the raw responses, so we can see exactly what works.
struct DiagnosticsView: View {
    @EnvironmentObject var session: SessionStore
    @Environment(\.dismiss) var dismiss
    private let api = APIClient()

    @State private var results: [APIClient.ProbeResult] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(busy ? "Bezig…" : "Diagnose uitvoeren") { run() }
                        .disabled(busy)
                    Text("userId: \(session.userId ?? "–")")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ForEach(results) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.label).font(.subheadline.bold())
                        Text(r.line).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("API-diagnose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Sluit") { dismiss() }
                }
            }
            .task { run() }
        }
    }

    private func run() {
        busy = true
        results = []
        Task {
            let auth = session.identity()
            let uid = auth.userId ?? ""
            var out: [APIClient.ProbeResult] = []
            out.append(await api.probe(label: "GET /api/get_email (auth-check)",
                                       method: "GET", path: "/api/get_email", auth: auth))
            out.append(await api.probe(label: "GET /api/locks (geen query)",
                                       method: "GET", path: "/api/locks", auth: auth))
            out.append(await api.probe(label: "GET /api/locks?query={}",
                                       method: "GET", path: "/api/locks",
                                       query: ["query": "{}"], auth: auth))
            out.append(await api.probe(label: "GET /api/locks?query={userProfile_id}",
                                       method: "GET", path: "/api/locks",
                                       query: ["query": "{\"userProfile_id\":\"\(uid)\"}"], auth: auth))
            out.append(await api.probe(label: "PUT /api/keys/associated_locks",
                                       method: "PUT", path: "/api/keys/associated_locks",
                                       form: ["device_token": auth.deviceToken], auth: auth))

            // Per-lock endpoints: resolve the first serial, then probe features.
            let serial = (try? await api.getLocks(auth: auth))?.first?.serial_no ?? ""
            out.append(APIClient.ProbeResult(label: "— serial in gebruik —", line: serial))

            out.append(await api.probe(label: "POST /api/leo/current_active",
                                       method: "POST", path: "/api/leo/current_active",
                                       form: ["lock_serial_no": serial], auth: auth))
            out.append(await api.probe(label: "POST /api/leo/tracking_history",
                                       method: "POST", path: "/api/leo/tracking_history",
                                       form: ["lock_serial_no": serial], auth: auth))
            out.append(await api.probe(label: "POST /api/leo/current_tracking (epoch)",
                                       method: "POST", path: "/api/leo/current_tracking",
                                       form: ["lock_serial_no": serial,
                                              "date": "1970-01-01T00:00:00.000+0000"], auth: auth))
            out.append(await api.probe(label: "PUT /api/keys/lock_permissions",
                                       method: "PUT", path: "/api/keys/lock_permissions",
                                       form: ["lock_serial_no": serial], auth: auth))
            out.append(await api.probe(label: "POST /api/payments_consumer/stripe/get_payment_info",
                                       method: "POST", path: "/api/payments_consumer/stripe/get_payment_info",
                                       auth: auth))

            await MainActor.run {
                results = out
                busy = false
            }
        }
    }
}
