import SwiftUI
import UIKit

/// Live test of the lock's cellular/GPS tracking: turns on recovery mode, then
/// polls the LINKA server for new positions and shows what the lock's modem and
/// GPS are doing (from the Bluetooth debug log).
struct TrackingTestView: View {
    let serial: String
    @EnvironmentObject var session: SessionStore
    @ObservedObject private var ble = BLEController.shared
    private let api = APIClient()

    @State private var running = false
    @State private var started: Date?
    @State private var checks: [String] = []
    @State private var points = 0
    @State private var lastPoint: String?
    @State private var lastLockLoc: String?
    @State private var task: Task<Void, Never>?
    @State private var minutes = 10

    /// Modem/GPS lines from the firmware log, newest first.
    private var modemLines: [String] {
        let keys = ["QGPSLOC", "QGPS", "QIOPEN", "SEND OK", "QISEND", "CSQ", "COPS", "CREG", "M_STATE", "Get Loc", "CME ERROR", "QIRD"]
        return ble.log.filter { l in keys.contains { l.contains($0) } }.prefix(25).map { $0 }
    }

    private var gpsFix: String? {
        // +QGPSLOC: <utc>,<lat>,<lon>,... (mode 2 = decimal degrees)
        guard let l = ble.log.first(where: { $0.contains("+QGPSLOC:") }) else { return nil }
        let parts = l.components(separatedBy: "+QGPSLOC:").last?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return parts.count >= 3 ? "\(parts[1]), \(parts[2])" : nil
    }

    var body: some View {
        List {
            Section {
                Stepper("Duur: \(minutes) min", value: $minutes, in: 5...60, step: 5).disabled(running)
                if running {
                    Button(role: .destructive) { stop(disable: true) } label: { Label("Stop test (tracking uit)", systemImage: "stop.circle.fill") }
                } else {
                    Button { start() } label: { Label("Start tracking-test", systemImage: "play.circle.fill") }
                }
            } footer: {
                Text("Zet tracking-modus aan, leg de fiets buiten (vrij zicht op de lucht) en wacht. De test vraagt elke 30 s de server om nieuwe posities. Verbruikt data van je dataplan.")
            }

            Section("Resultaat (server)") {
                row("Status", running ? "loopt sinds \(started.map { DateUtils.timeHM($0) } ?? "–")" : (checks.isEmpty ? "niet gestart" : "gestopt"))
                row("Trackingpunten", "\(points)")
                row("Laatste punt", lastPoint ?? "–")
                row("Slotlocatie (server)", lastLockLoc ?? "–")
            }

            Section {
                row("Bluetooth", ble.ready ? "verbonden" : "niet verbonden")
                row("GPS-fix (slot)", gpsFix ?? "nog geen")
                row("Netwerk", ble.netOperator.map { $0 + (ble.netCSQ.map { " · \($0)/31" } ?? "") } ?? "–")
                ForEach(Array(modemLines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(.caption2, design: .monospaced))
                }
            } header: { Text("Slot live (via Bluetooth)") } footer: {
                Text("‘CME ERROR: 516’ bij QGPSLOC = nog geen GPS-fix. ‘SEND OK’ = het slot heeft data naar de LINKA-server gestuurd.")
            }

            if !checks.isEmpty {
                Section("Verloop") {
                    ForEach(Array(checks.reversed().enumerated()), id: \.offset) { _, c in
                        Text(c).font(.caption)
                    }
                    Button {
                        let text = (checks + ["", "Modem:"] + modemLines.reversed()).joined(separator: "\n")
                        UIPasteboard.general.string = text
                        Haptic.tap(.light)
                    } label: { Label("Kopieer testverslag", systemImage: "doc.on.doc") }
                }
            }
        }
        .navigationTitle("Tracking-test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { task?.cancel() }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private func note(_ s: String) { checks.append("\(DateUtils.timeHM(Date())) \(s)") }

    private func start() {
        running = true; started = Date(); checks = []; points = 0; lastPoint = nil
        let auth = session.identity()
        let total = minutes
        task = Task {
            do {
                try await api.setRecoveryMode(serial: serial, enabled: true, auth: auth)
                note("Tracking-modus aangezet.")
            } catch {
                note("Aanzetten mislukt: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            let end = Date().addingTimeInterval(Double(total) * 60)
            while !Task.isCancelled && Date() < end {
                do {
                    let acts = try await api.currentTracking(serial: serial, auth: auth)
                    if acts.count != points {
                        note("Server: \(acts.count) punt(en).")
                    }
                    points = acts.count
                    if let a = acts.first(where: { $0.hasLocation }), let lat = a.latitude, let lon = a.longitude {
                        let t = DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt)
                        lastPoint = String(format: "%.5f, %.5f", lat, lon) + (t.map { " · " + DateUtils.timeHM($0) } ?? "")
                    }
                } catch {
                    note("Server: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
                if let l = try? await api.lockSingle(serial: serial, auth: auth), let lat = l.latitude, let lon = l.longitude {
                    let t = DateUtils.parseAny(l.modifiedAt)
                    lastLockLoc = String(format: "%.5f, %.5f", lat, lon) + (t.map { " · " + DateUtils.relative($0) } ?? "")
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
            if !Task.isCancelled { note("Testtijd voorbij."); stop(disable: true) }
        }
    }

    private func stop(disable: Bool) {
        task?.cancel(); task = nil
        running = false
        guard disable else { return }
        let auth = session.identity()
        Task {
            do {
                try await api.setRecoveryMode(serial: serial, enabled: false, auth: auth)
                note("Tracking-modus uitgezet.")
            } catch {
                note("Uitzetten mislukt: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
    }
}
