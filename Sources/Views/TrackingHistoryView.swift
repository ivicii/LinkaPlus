import SwiftUI
import MapKit
import UIKit

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

/// One session's map plus every point, each openable in / navigable with Apple Maps.
struct TrackingSessionDetailView: View {
    let session: TrackingSession
    var lockName: String = "LINKA-slot"

    private var locs: [CLLocationCoordinate2D] { session.locations }

    var body: some View {
        List {
            if !locs.isEmpty {
                Section {
                    SessionMapView(points: locs,
                                   subtitles: (0..<locs.count).map { metaLine($0) },
                                   imprecise: (0..<locs.count).map { session.isImprecise(at: $0) }) { idx in
                        MapsLauncher.open(locs[idx], name: pointName(idx), directions: true)
                    }
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    if let last = locs.last {
                        Button {
                            MapsLauncher.open(last, name: "\(lockName) — laatste positie", directions: true)
                        } label: { Label("Navigeer naar laatste positie", systemImage: "location.north.line.fill") }
                    }
                    if locs.count > 1 {
                        Button {
                            MapsLauncher.openAll(locs, name: lockName)
                        } label: { Label("Toon alle punten in Apple Maps", systemImage: "map") }
                    }
                }

                Section {
                    ForEach(Array(locs.enumerated()), id: \.offset) { i, c in
                        Menu {
                            Button { MapsLauncher.open(c, name: pointName(i), directions: true) } label: {
                                Label("Navigeer hierheen", systemImage: "arrow.triangle.turn.up.right.diamond")
                            }
                            Button { MapsLauncher.open(c, name: pointName(i), directions: false) } label: {
                                Label("Toon in Apple Maps", systemImage: "mappin.and.ellipse")
                            }
                            Button {
                                UIPasteboard.general.string = String(format: "%.6f, %.6f", c.latitude, c.longitude)
                            } label: { Label("Kopieer coördinaten", systemImage: "doc.on.doc") }
                        } label: {
                            HStack {
                                Image(systemName: i == locs.count - 1 ? "flag.checkered" : "\(min(i + 1, 50)).circle")
                                    .foregroundStyle(i == locs.count - 1 ? Color.red : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(i == locs.count - 1 ? "Laatste positie" : "Positie \(i + 1)")
                                    let meta = metaLine(i)
                                    if !meta.isEmpty {
                                        Text(meta).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if session.isImprecise(at: i) {
                                        Label("onnauwkeurig", systemImage: "scope")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text(String(format: "%.5f, %.5f", c.latitude, c.longitude))
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "ellipsis.circle").foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Posities (\(locs.count))")
                } footer: {
                    Text("Tik op een positie om ernaartoe te navigeren of 'm in Apple Maps te openen. Op de kaart: tik een pin aan en daarna de ⓘ-knop.")
                }
            }

            Section("Sessie") {
                row("Gestart", Self.dateTime(session.start))
                row("Geëindigd", session.end.map(Self.dateTime) ?? "lopend")
                row("Duur", durationText)
                row("Posities", "\(locs.count)")
                if let r = session.reports, r > locs.count {
                    row("Rapportages", "\(r) totaal · \(locs.count) met locatie")
                }
                if session.impreciseCount > 0 {
                    row("Onnauwkeurig", "\(session.impreciseCount) × ≥ 50 m")
                }
            }
        }
        .navigationTitle(TrackingHistoryView.rangeText(session))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pointName(_ i: Int) -> String {
        i == locs.count - 1 ? "\(lockName) — laatste positie" : "\(lockName) — positie \(i + 1)"
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

    private static func hms(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "nl_NL"); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// "17:38:02 · 14 km/u · NO · ±18 m" — only the parts the server actually sent.
    private func metaLine(_ i: Int) -> String {
        var parts: [String] = []
        if let d = session.date(at: i) { parts.append(Self.hms(d)) }
        if let s = session.speedKmh(at: i) { parts.append("\(s) km/u") }
        if let h = session.headingDegrees(at: i) { parts.append(Self.compass(h)) }
        if let a = session.accuracy(at: i) { parts.append("±\(a) m") }
        return parts.joined(separator: " · ")
    }

    private static func compass(_ deg: Int) -> String {
        let dirs = ["N", "NO", "O", "ZO", "Z", "ZW", "W", "NW"]
        let idx = ((Int((Double(deg) / 45.0).rounded()) % 8) + 8) % 8
        return dirs[idx]
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}

/// Opens coordinates in Apple Maps, as a pin or with driving directions.
enum MapsLauncher {
    static func open(_ c: CLLocationCoordinate2D, name: String, directions: Bool) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
        item.name = name
        item.openInMaps(launchOptions: directions
            ? [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving] : nil)
    }
    static func openAll(_ coords: [CLLocationCoordinate2D], name: String) {
        let items = coords.enumerated().map { i, c -> MKMapItem in
            let it = MKMapItem(placemark: MKPlacemark(coordinate: c))
            it.name = (i == coords.count - 1) ? "\(name) — laatste" : "\(name) — \(i + 1)"
            return it
        }
        guard !items.isEmpty else { return }
        MKMapItem.openMaps(with: items, launchOptions: nil)
    }
}

/// Map with a numbered pin per position and the route between them. Tapping a
/// pin's callout ⓘ calls `onSelect` with that point's index.
struct SessionMapView: UIViewRepresentable {
    let points: [CLLocationCoordinate2D]
    var subtitles: [String] = []
    var imprecise: [Bool] = []
    var onSelect: ((Int) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        rebuild(map)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let have = map.annotations.filter { $0 is IdxAnnotation }.count
        if have != points.count { rebuild(map) }
    }

    private func rebuild(_ map: MKMapView) {
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        map.removeOverlays(map.overlays)
        for (i, c) in points.enumerated() {
            let a = IdxAnnotation()
            a.coordinate = c
            a.index = i
            a.isLast = (i == points.count - 1)
            a.title = a.isLast ? "Laatste positie" : "Positie \(i + 1)"
            let coordStr = String(format: "%.5f, %.5f", c.latitude, c.longitude)
            a.subtitle = (i < subtitles.count && !subtitles[i].isEmpty) ? subtitles[i] : coordStr
            a.isImprecise = i < imprecise.count ? imprecise[i] : false
            map.addAnnotation(a)
        }
        if points.count > 1 {
            map.addOverlay(MKPolyline(coordinates: points, count: points.count))
        }
        if let region = Self.boundingRegion(points) { map.setRegion(region, animated: false) }
    }

    static func boundingRegion(_ cs: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard let first = cs.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in cs {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.5, 0.006),
                                    longitudeDelta: max((maxLon - minLon) * 1.5, 0.006))
        return MKCoordinateRegion(center: center, span: span)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class IdxAnnotation: NSObject, MKAnnotation {
        @objc dynamic var coordinate = CLLocationCoordinate2D()
        var title: String?
        var subtitle: String?
        var index = 0
        var isLast = false
        var isImprecise = false
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let onSelect: ((Int) -> Void)?
        init(onSelect: ((Int) -> Void)?) { self.onSelect = onSelect }

        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = .systemBlue
                r.lineWidth = 4
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ m: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? IdxAnnotation else { return nil }
            let id = "idx"
            let v = (m.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: id)
            v.annotation = a
            v.canShowCallout = true
            v.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            if a.isLast {
                v.markerTintColor = .systemRed
                v.glyphImage = UIImage(systemName: "bicycle")
                v.displayPriority = .required
            } else {
                v.markerTintColor = a.isImprecise ? .systemOrange : .systemBlue
                v.glyphText = "\(a.index + 1)"
                v.displayPriority = .defaultHigh
            }
            return v
        }

        func mapView(_ m: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let a = view.annotation as? IdxAnnotation { onSelect?(a.index) }
        }
    }
}
