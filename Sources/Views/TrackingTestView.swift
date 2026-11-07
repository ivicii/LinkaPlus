import SwiftUI
import MapKit
import UIKit
import Foundation

/// Theft tracking via LINKA's recovery mode — the way the official app does it,
/// but it only arms once Bluetooth confirms the lock is awake (so the server can
/// reach it), keeps recovery ON until you stop, and maps the points it receives
/// (polls current_tracking every 10 s, like the official TrackingActiveFragment).
struct TrackingTestView: View {
    let serial: String
    @EnvironmentObject var session: SessionStore
    @ObservedObject private var ble = BLEController.shared
    private let api = APIClient()

    @State private var armed = false
    @State private var arming = false
    @State private var started: Date?
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var lastUpdate: Date?
    @State private var status: String?
    @State private var showLog = false
    @State private var loop: Task<Void, Never>?

    /// Lock is reachable right now: BLE-connected means it is awake, so the
    /// server's recovery command will arrive. We also refresh it with a ping.
    private var lockAwake: Bool { ble.ready }

    private var modemLines: [String] {
        let keys = ["QGPSLOC", "QGPS", "QIOPEN", "SEND OK", "QISEND", "CSQ", "CME ERROR"]
        return ble.log.filter { l in keys.contains { l.contains($0) } }.prefix(20).map { $0 }
    }
    private var gpsFix: String? {
        guard let l = ble.log.first(where: { $0.contains("+QGPSLOC:") }) else { return nil }
        let p = l.components(separatedBy: "+QGPSLOC:").last?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return p.count >= 3 ? "\(p[1]), \(p[2])" : nil
    }

    var body: some View {
        List {
            if armed {
                Section {
                    if let last = points.last {
                        LockMapView(coordinate: last, title: "Laatste positie", route: points)
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets())
                    } else {
                        HStack { ProgressView(); Text("Wachten op eerste positie van het slot…") }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if !armed {
                    Button { arm() } label: {
                        Label(arming ? "Bezig…" : "Start tracking", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(arming)
                } else {
                    Button(role: .destructive) { stop() } label: {
                        Label("Stop tracking", systemImage: "stop.circle.fill")
                    }
                }
            } footer: {
                Text("Werkt óók als je slot weg is: de aanvraag wordt bij LINKA klaargezet en het slot pikt hem op zodra het zich meldt. Bij diefstal beweegt de fiets, en beweging maakt het slot wakker — meestal binnen enkele minuten. Je krijgt een bevestigingsmail van LINKA zodra het actief is; daarna verschijnen de posities hieronder. Blijft aan tot je stopt. Verbruikt data van je dataplan.")
            }

            Section("Status") {
                row("Tracking", armed ? "aangevraagd/aan sinds \(started.map { DateUtils.timeHM($0) } ?? "–")" : "uit")
                row("Posities ontvangen", "\(points.count)")
                row("Laatste update", lastUpdate.map { DateUtils.timeHM($0) } ?? "–")
                if let last = points.last {
                    row("Laatste positie", String(format: "%.5f, %.5f", last.latitude, last.longitude))
                }
                if let status {
                    HStack(alignment: .top) {
                        Text("Server"); Spacer()
                        Text(status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                            .lineLimit(3)
                    }
                }
            }

            Section {
                row("Bluetooth", ble.ready ? "verbonden (slot wakker)" : "niet verbonden")
                row("GPS-fix (slot)", gpsFix ?? "nog geen")
                row("Netwerk", ble.netOperator.map { $0 + (ble.netCSQ.map { " · \($0)/31" } ?? "") } ?? "–")
                DisclosureGroup(isExpanded: $showLog) {
                    ForEach(Array(modemLines.enumerated()), id: \.offset) { _, l in
                        Text(l).font(.system(.caption2, design: .monospaced))
                    }
                    Button {
                        UIPasteboard.general.string = modemLines.reversed().joined(separator: "\n")
                        Haptic.tap(.light)
                    } label: { Label("Kopieer modemlog", systemImage: "doc.on.doc") }
                } label: { Text("Slot live (diagnose)").font(.subheadline) }
            } header: { Text("Slot") } footer: {
                Text("‘CME ERROR: 516’ = nog geen GPS-fix. ‘SEND OK’ = het slot stuurt data naar LINKA.")
            }
        }
        .navigationTitle("Tracking (recovery)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { restore() }
        .onDisappear { loop?.cancel() }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private static func armedKey(_ s: String) -> String { "recoveryArmed_\(s)" }

    /// Reflect what the user themselves started (reliable), not a guessed server state.
    private func restore() {
        if UserDefaults.standard.bool(forKey: Self.armedKey(serial)) {
            armed = true; started = started ?? Date(); startPolling()
        }
    }

    /// Friendlier wording for the server's tracking status.
    private func serverText(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("not currently") || l.contains("no theft") {
            return "nog niet actief — wacht tot het slot zich meldt"
        }
        return String(raw.prefix(140))
    }

    /// Short, human message for an error (no giant NSError dump).
    private func shortError(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .networkConnectionLost, .notConnectedToInternet, .timedOut, .cannotConnectToHost:
                return "netwerk even weg — opnieuw proberen…"
            default: return "netwerkfout — opnieuw proberen…"
            }
        }
        let d = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return serverText(d)
    }

    private func arm() {
        arming = true; status = nil
        // If we happen to be next to the lock, wake it so it checks in sooner.
        if ble.ready { ble.statePing() }
        let auth = session.identity()
        Task {
            do {
                try await api.setRecoveryMode(serial: serial, enabled: true, auth: auth)
                armed = true; started = Date(); points = []
                UserDefaults.standard.set(true, forKey: Self.armedKey(serial))
                status = ble.ready ? "recovery aangezet" : "aangevraagd — wacht tot het slot zich meldt"
                startPolling()
            } catch {
                status = "aanzetten mislukt: \(shortError(error))"
            }
            arming = false
        }
    }

    private func startPolling() {
        loop?.cancel()
        let auth = session.identity()
        loop = Task {
            while !Task.isCancelled && armed {
                do {
                    let acts = try await api.currentTracking(serial: serial, auth: auth)
                    let pts = acts.compactMap { a -> (Date, CLLocationCoordinate2D)? in
                        guard a.hasLocation, let lat = a.latitude, let lon = a.longitude else { return nil }
                        let t = DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt) ?? Date.distantPast
                        return (t, CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }.sorted { $0.0 < $1.0 }.map { $0.1 }
                    if pts.count != points.count { points = pts }
                    lastUpdate = Date()
                    status = acts.isEmpty ? "nog niet actief — wacht tot het slot zich meldt" : "\(acts.count) punt(en)"
                } catch {
                    status = shortError(error)
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10 s, like the official app
            }
        }
    }

    private func stop() {
        loop?.cancel(); loop = nil
        armed = false
        UserDefaults.standard.set(false, forKey: Self.armedKey(serial))
        let auth = session.identity()
        Task {
            do { try await api.setRecoveryMode(serial: serial, enabled: false, auth: auth); status = "recovery uitgezet" }
            catch { status = "uitzetten mislukt: \((error as? LocalizedError)?.errorDescription ?? "\(error)")" }
        }
    }
}
