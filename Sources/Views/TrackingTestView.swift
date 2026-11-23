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
    var lockName: String = "LINKA-slot"
    @EnvironmentObject var session: SessionStore
    @ObservedObject private var ble = BLEController.shared
    private let api = APIClient()

    @State private var armed = false
    @State private var arming = false
    @State private var stopping = false
    @State private var started: Date?
    @State private var points: [CLLocationCoordinate2D] = []
    @State private var lastUpdate: Date?
    @State private var status: String?
    @State private var showLog = false
    @State private var loop: Task<Void, Never>?
    @State private var armLoop: Task<Void, Never>?
    @State private var armAttempts = 0
    @State private var armSince: Date?
    @State private var pointTimes: [Date] = []

    private let armRetryInterval: UInt64 = 15   // seconds between arm attempts

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
            if let last = points.last {
                Section {
                    LockMapView(coordinate: last, title: "Laatste positie", route: points)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    if !armed {
                        Text("Punten van de laatste tracking-sessie — die blijven bewaard tot je ze wist of nieuwe tracking start.")
                    }
                }
            } else if armed {
                Section {
                    HStack { ProgressView(); Text("Wachten op eerste positie van het slot…") }
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                if armed {
                    Button(role: .destructive) { stop() } label: {
                        Label(stopping ? "Bezig…" : "Stop tracking", systemImage: "stop.circle.fill")
                    }
                    .disabled(stopping)
                } else if arming {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bezig met activeren… (poging \(armAttempts))")
                            if let s = armSince {
                                Text("Blijft proberen tot het slot zich meldt — gestart \(sinceText(s))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button(role: .cancel) { cancelArming() } label: {
                        Label("Stop proberen", systemImage: "xmark.circle")
                    }
                } else {
                    Button { startArming() } label: {
                        Label("Start tracking", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    if !points.isEmpty {
                        Button(role: .destructive) { clearPoints() } label: {
                            Label("Wis kaart en punten", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Werkt óók als je slot weg is: de app blijft de aanvraag automatisch opnieuw bij LINKA klaarzetten tot het slot zich meldt — je hoeft niet zelf te blijven tikken. Bij diefstal beweegt de fiets, en beweging maakt het slot wakker, meestal binnen enkele minuten. Je krijgt een bevestigingsmail van LINKA zodra het actief is; daarna verschijnen de posities hieronder. Blijft aan tot je stopt. Verbruikt data van je dataplan.")
            }

            Section("Status") {
                row("Tracking", armed ? "aangevraagd/aan sinds \(started.map { sinceText($0) } ?? "–")" : (arming ? "activeren… (poging \(armAttempts))" : "uit"))
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

            Section {
                NavigationLink {
                    TrackingHistoryView(serial: serial, lockName: lockName)
                } label: {
                    Label("Tracking-geschiedenis", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle("Tracking (recovery)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { restore() }
        .onDisappear { loop?.cancel(); armLoop?.cancel() }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
    }

    private static func armedKey(_ s: String) -> String { "recoveryArmed_\(s)" }
    private static func startedKey(_ s: String) -> String { "recoveryStarted_\(s)" }
    private static func armingKey(_ s: String) -> String { "recoveryArming_\(s)" }
    private static func firstFixKey(_ s: String) -> String { "recoveryFirstFix_\(s)" }
    private static func pointsKey(_ s: String) -> String { "recoveryPoints_\(s)" }

    /// Keep the received positions on disk so the map survives stopping tracking
    /// and relaunching the app, until the user wipes them or starts a new session.
    private func savePoints() {
        let arr = points.map { [$0.latitude, $0.longitude] }
        if let d = try? JSONSerialization.data(withJSONObject: arr) {
            UserDefaults.standard.set(d, forKey: Self.pointsKey(serial))
        }
    }
    private func loadPoints() {
        guard let d = UserDefaults.standard.data(forKey: Self.pointsKey(serial)),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[Double]] else { return }
        points = arr.compactMap { $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }
    private func clearPoints() {
        points = []
        lastUpdate = nil
        UserDefaults.standard.removeObject(forKey: Self.pointsKey(serial))
    }

    /// Archive the live points as a history session (keyed by start time, so poll
    /// updates replace rather than duplicate). `ongoing: false` stamps the end.
    private func upsertCurrentSession(ongoing: Bool) {
        guard let started, !points.isEmpty else { return }
        let times: [Double]? = pointTimes.count == points.count
            ? pointTimes.map { $0.timeIntervalSince1970 } : nil
        let s = TrackingSession(id: "s\(Int(started.timeIntervalSince1970))",
                                start: started, end: ongoing ? nil : Date(),
                                coords: points.map { [$0.latitude, $0.longitude] },
                                times: times)
        TrackingHistory.upsert(s, serial: serial)
    }

    /// Time only for today, otherwise date + time.
    private func sinceText(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? DateUtils.timeHM(d) : DateUtils.absolute(d)
    }

    /// Reflect what the user themselves started (reliable), not a guessed server state.
    private func restore() {
        LockNotifier.shared.requestAuth()
        loadPoints()
        if UserDefaults.standard.bool(forKey: Self.armedKey(serial)) {
            armed = true
            if started == nil {
                // The real start time — not "now", which made it look freshly started.
                let t = UserDefaults.standard.double(forKey: Self.startedKey(serial))
                started = t > 0 ? Date(timeIntervalSince1970: t) : nil
            }
            startPolling()
        } else if UserDefaults.standard.bool(forKey: Self.armingKey(serial)) {
            // Was mid-arming when the app closed — pick the retrying back up.
            startArming()
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

    /// Build the current Live Activity content from the tracking state.
    @available(iOS 16.1, *)
    private func liveState() -> TrackingActivityAttributes.ContentState {
        let pos = points.last.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) }
        return .init(statusText: status ?? "Tracking actief",
                     pointCount: points.count,
                     lastUpdate: lastUpdate ?? Date(),
                     positionText: pos)
    }

    private func startLiveActivity() {
        if #available(iOS 16.1, *) {
            LiveActivityManager.start(lockName: lockName, state: liveState())
        }
    }
    private func updateLiveActivity() {
        if #available(iOS 16.1, *) { LiveActivityManager.update(liveState()) }
    }
    private func endLiveActivity() {
        if #available(iOS 16.1, *) { LiveActivityManager.end() }
    }

    /// Keep asking LINKA to arm recovery until the server accepts it (it only does
    /// once the lock has checked in), instead of the user tapping over and over.
    /// Fires a notification the moment it goes live, and resumes if the app reopens.
    private func startArming() {
        guard !arming, !armed else { return }
        // Finalise any still-open previous session before starting a fresh one.
        upsertCurrentSession(ongoing: false)
        arming = true; armAttempts = 0; armSince = Date(); status = "bezig met activeren…"
        UserDefaults.standard.set(true, forKey: Self.armingKey(serial))
        UserDefaults.standard.removeObject(forKey: Self.firstFixKey(serial))
        let auth = session.identity()
        armLoop?.cancel()
        armLoop = Task {
            while !Task.isCancelled && !armed {
                armAttempts += 1
                // If we're near the lock, wake it so it checks in sooner.
                if ble.ready { ble.statePing() }
                do {
                    try await api.setRecoveryMode(serial: serial, enabled: true, auth: auth)
                    armed = true; started = Date(); points = []; savePoints()
                    UserDefaults.standard.set(true, forKey: Self.armedKey(serial))
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.startedKey(serial))
                    UserDefaults.standard.removeObject(forKey: Self.armingKey(serial))
                    status = "recovery actief — wacht op posities"
                    LockNotifier.shared.notify(
                        title: "Tracking staat aan",
                        body: "\(lockName): recovery is geactiveerd. Je krijgt de posities zodra het slot zich meldt.",
                        id: "recoveryActive_\(serial)")
                    startLiveActivity()
                    startPolling()
                } catch {
                    let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let l = raw.lowercased()
                    if l.contains("not currently") || l.contains("no theft") || l.contains("not active") {
                        status = "nog niet actief — blijft proberen (poging \(armAttempts))"
                    } else if error is URLError {
                        status = "netwerk even weg — blijft proberen (poging \(armAttempts))"
                    } else {
                        status = "server: \(String(raw.prefix(80))) — blijft proberen (poging \(armAttempts))"
                    }
                }
                if armed || Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: armRetryInterval * 1_000_000_000)
            }
            arming = false
        }
    }

    private func cancelArming() {
        armLoop?.cancel(); armLoop = nil
        arming = false
        UserDefaults.standard.removeObject(forKey: Self.armingKey(serial))
        status = "activeren gestopt"
    }

    private func startPolling() {
        loop?.cancel()
        let auth = session.identity()
        loop = Task {
            while !Task.isCancelled && armed {
                do {
                    let acts = try await api.currentTracking(serial: serial, auth: auth)
                    let pairs = acts.compactMap { a -> (Date, CLLocationCoordinate2D)? in
                        guard a.hasLocation, let lat = a.latitude, let lon = a.longitude else { return nil }
                        let t = DateUtils.parseAny(a.timestamp) ?? DateUtils.parseISO(a.createdAt) ?? Date.distantPast
                        return (t, CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }.sorted { $0.0 < $1.0 }
                    let pts = pairs.map { $0.1 }
                    if pts.count != points.count {
                        points = pts
                        pointTimes = pairs.map { $0.0 }
                        savePoints()
                        upsertCurrentSession(ongoing: true)
                        // First real position in → alert (once per recovery session).
                        if let first = pts.last,
                           !UserDefaults.standard.bool(forKey: Self.firstFixKey(serial)) {
                            UserDefaults.standard.set(true, forKey: Self.firstFixKey(serial))
                            LockNotifier.shared.notify(
                                title: "Eerste positie binnen",
                                body: String(format: "%@: %.5f, %.5f", lockName, first.latitude, first.longitude),
                                id: "recoveryFirstFix_\(serial)")
                        }
                    }
                    lastUpdate = Date()
                    status = acts.isEmpty ? "nog niet actief — wacht tot het slot zich meldt" : "\(acts.count) punt(en)"
                    updateLiveActivity()
                } catch {
                    status = shortError(error)
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10 s, like the official app
            }
        }
    }

    private func stop() {
        stopping = true
        endLiveActivity()
        let auth = session.identity()
        Task {
            var off = false
            do {
                try await api.setRecoveryMode(serial: serial, enabled: false, auth: auth)
                off = true
                status = "recovery uitgezet"
            } catch {
                let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                let l = raw.lowercased()
                if l.contains("not currently") || l.contains("not active") || l.contains("no theft") {
                    // The server has no active session → it is off already.
                    off = true
                    status = "recovery stond niet (meer) aan"
                } else {
                    // Don't show "uit" while the server (and the data meter) keeps running.
                    status = "uitzetten mislukt — tracking staat nog aan. Probeer opnieuw. (\(String(raw.prefix(100))))"
                }
            }
            if off {
                upsertCurrentSession(ongoing: false)   // archive this session with its end time
                loop?.cancel(); loop = nil
                armLoop?.cancel(); armLoop = nil
                armed = false; started = nil
                UserDefaults.standard.set(false, forKey: Self.armedKey(serial))
                UserDefaults.standard.removeObject(forKey: Self.startedKey(serial))
                UserDefaults.standard.removeObject(forKey: Self.armingKey(serial))
                UserDefaults.standard.removeObject(forKey: Self.firstFixKey(serial))
            }
            stopping = false
        }
    }
}
