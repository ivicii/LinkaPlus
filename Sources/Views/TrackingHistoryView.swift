import SwiftUI
import MapKit

/// List of past tracking sessions; each opens its own map with the route.
struct TrackingHistoryView: View {
    let serial: String
    var lockName: String = "LINKA-slot"
    @State private var sessions: [TrackingSession] = []

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("Nog geen tracking-sessies opgeslagen. Zodra je tracking gebruikt, verschijnt elke sessie hier met z'n eigen kaart.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { s in
                    NavigationLink {
                        TrackingSessionDetailView(session: s, lockName: lockName)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Self.rangeText(s)).font(.callout)
                            Text("\(s.coords.count) posities" + (s.end == nil ? " · lopend" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    idx.map { sessions[$0].id }.forEach { TrackingHistory.delete(id: $0, serial: serial) }
                    sessions = TrackingHistory.all(serial: serial)
                }
            }
        }
        .navigationTitle("Tracking-geschiedenis")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !sessions.isEmpty { EditButton() } }
        .onAppear { sessions = TrackingHistory.all(serial: serial) }
    }

    static func rangeText(_ s: TrackingSession) -> String {
        let d = DateFormatter(); d.locale = Locale(identifier: "nl_NL"); d.dateFormat = "d MMM · HH:mm"
        let start = d.string(from: s.start)
        guard let end = s.end else { return start }
        let t = DateFormatter(); t.locale = Locale(identifier: "nl_NL"); t.dateFormat = "HH:mm"
        return "\(start)–\(t.string(from: end))"
    }
}

/// One session's map plus its details.
struct TrackingSessionDetailView: View {
    let session: TrackingSession
    var lockName: String = "LINKA-slot"

    var body: some View {
        List {
            if let last = session.locations.last {
                Section {
                    LockMapView(coordinate: last, title: lockName, route: session.locations)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section("Sessie") {
                row("Gestart", Self.dateTime(session.start))
                row("Geëindigd", session.end.map(Self.dateTime) ?? "lopend")
                row("Duur", durationText)
                row("Posities", "\(session.coords.count)")
                if let last = session.locations.last {
                    row("Laatste positie", String(format: "%.5f, %.5f", last.latitude, last.longitude))
                }
            }
        }
        .navigationTitle(TrackingHistoryView.rangeText(session))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var durationText: String {
        guard let end = session.end else { return "–" }
        let secs = Int(end.timeIntervalSince(session.start))
        if secs < 60 { return "\(secs) s" }
        let m = secs / 60
        if m < 60 { return "\(m) min" }
        return "\(m / 60) u \(m % 60) min"
    }

    private static func dateTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "nl_NL"); f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: d)
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}
