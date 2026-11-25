import SwiftUI
import MapKit
import UIKit

/// "Volg je fiets": live chase screen. Map that keeps you and the bike in view,
/// a big distance + arrow pointing at the bike, the bike's speed/heading and how
/// fresh the last fix is. Keeps running in the background until you stop it.
struct FollowView: View {
    let serial: String
    var lockName: String = "LINKA-slot"
    @EnvironmentObject var session: SessionStore
    @ObservedObject private var eng = FollowEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var autoFollow = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                FollowMapView(fixes: eng.fixes, me: eng.me?.coordinate, autoFollow: $autoFollow)
                if !autoFollow {
                    Button { autoFollow = true } label: {
                        Image(systemName: "location.fill.viewfinder")
                            .font(.title3)
                            .padding(12)
                            .background(.regularMaterial, in: Circle())
                    }
                    .padding(12)
                    .accessibilityLabel("Volg weer automatisch")
                }
            }
            panel
        }
        .navigationTitle("Volg je fiets")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            eng.start(serial: serial, lockName: lockName, auth: session.identity())
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                arrow
                VStack(alignment: .leading, spacing: 2) {
                    Text(eng.latest == nil ? "Wacht op positie…" : FollowEngine.distanceText(eng.distance))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(directionLine)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 0) {
                stat("Fiets", bikeSpeed)
                stat("Richting", bikeHeading)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    stat("Laatste fix", age(at: ctx.date))
                }
                stat("Nauwkeurig", eng.latest?.accuracy.map { "±\($0) m" } ?? "–")
            }

            if eng.locationDenied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    Label("Geef locatietoegang voor afstand en richting", systemImage: "location.slash")
                        .font(.footnote)
                }
            }
            if let e = eng.error {
                Label(e, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange).lineLimit(2)
            }

            HStack(spacing: 12) {
                Menu {
                    Button { navigate(MKLaunchOptionsDirectionsModeDriving) } label: { Label("Met de auto", systemImage: "car") }
                    Button { navigate(MKLaunchOptionsDirectionsModeWalking) } label: { Label("Lopend", systemImage: "figure.walk") }
                    Button { navigate(MKLaunchOptionsDirectionsModeCycling) } label: { Label("Fietsend", systemImage: "bicycle") }
                } label: {
                    Label("Navigeer", systemImage: "location.north.line.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(eng.latest == nil)

                Button(role: .destructive) {
                    eng.stop()
                    dismiss()
                } label: {
                    Label("Stop volgen", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            Text("Volgen loopt door op de achtergrond (blauwe balk bovenin) en houdt de Dynamic Island bij. Je telefoon trilt bij elke nieuwe positie, en harder als je dichterbij komt.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.regularMaterial)
    }

    /// Arrow that points at the bike. Uses the phone's compass when available, so
    /// it works like a homing needle; otherwise it's relative to north (map up).
    private var arrow: some View {
        let rotation: Double? = {
            guard let b = eng.bearing else { return nil }
            if let h = eng.heading { return b - h }
            return b
        }()
        return ZStack {
            Circle().fill(Color.accentColor.opacity(0.15))
            Image(systemName: rotation == nil ? "questionmark" : "location.north.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .rotationEffect(.degrees(rotation ?? 0))
                .animation(.easeOut(duration: 0.3), value: rotation ?? 0)
        }
        .frame(width: 64, height: 64)
    }

    private var directionLine: String {
        guard eng.latest != nil else { return "Zodra het slot een positie stuurt, verschijnt die hier." }
        guard let b = eng.bearing else { return "Wacht op jouw locatie…" }
        let dir = FollowEngine.compass(b)
        return eng.heading != nil ? "Pijl wijst naar je fiets · \(dir)" : "Fiets ligt \(dir) van je (noord = boven)"
    }

    private var bikeSpeed: String {
        guard let k = eng.latest?.speedKmh else { return "–" }
        return k <= 2 ? "stil" : "\(k) km/u"
    }

    private var bikeHeading: String {
        guard let f = eng.latest, let h = f.headingDegrees, (f.speedKmh ?? 0) > 2 else { return "–" }
        return FollowEngine.compass(h)
    }

    private func age(at now: Date) -> String {
        let t: Date? = {
            if let f = eng.latest, f.time.timeIntervalSince1970 > 946_684_800 { return f.time }
            return eng.lastNewFixAt
        }()
        guard let t else { return "–" }
        let s = max(0, Int(now.timeIntervalSince(t)))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) u"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func navigate(_ mode: String) {
        guard let f = eng.latest else { return }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: f.coord))
        item.name = "\(lockName) — live positie"
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode])
    }
}

/// Map that shows the bike's trail and live position plus your own, and keeps
/// both in view until you pan it yourself.
struct FollowMapView: UIViewRepresentable {
    let fixes: [TrackFix]
    let me: CLLocationCoordinate2D?
    @Binding var autoFollow: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        if c.drawnCount != fixes.count {
            map.removeOverlays(map.overlays)
            if fixes.count > 1 {
                let coords = fixes.map { $0.coord }
                map.addOverlay(MKPolyline(coordinates: coords, count: coords.count))
            }
            c.drawnCount = fixes.count
        }

        if let last = fixes.last {
            if let a = c.bike {
                UIView.animate(withDuration: 0.6) { a.coordinate = last.coord }
            } else {
                let a = MKPointAnnotation()
                a.coordinate = last.coord
                a.title = "Je fiets"
                map.addAnnotation(a)
                c.bike = a
            }
        }

        if autoFollow { c.fitIfNeeded(map, me: me, bike: fixes.last?.coord, force: !c.wasAuto) }
        c.wasAuto = autoFollow
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FollowMapView
        var bike: MKPointAnnotation?
        var drawnCount = 0
        var wasAuto = true
        private var lastFitMe: CLLocationCoordinate2D?
        private var lastFitBike: CLLocationCoordinate2D?

        init(parent: FollowMapView) { self.parent = parent }

        private func moved(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
            switch (a, b) {
            case (nil, nil): return false
            case let (x?, y?):
                return CLLocation(latitude: x.latitude, longitude: x.longitude)
                    .distance(from: CLLocation(latitude: y.latitude, longitude: y.longitude)) > 15
            default: return true
            }
        }

        func fitIfNeeded(_ map: MKMapView, me: CLLocationCoordinate2D?, bike: CLLocationCoordinate2D?, force: Bool) {
            guard force || moved(me, lastFitMe) || moved(bike, lastFitBike) else { return }
            lastFitMe = me; lastFitBike = bike
            let pts = [me, bike].compactMap { $0 }
            guard !pts.isEmpty else { return }
            if pts.count == 1 {
                map.setRegion(MKCoordinateRegion(center: pts[0], latitudinalMeters: 700, longitudinalMeters: 700), animated: true)
                return
            }
            var rect = MKMapRect.null
            for p in pts {
                let mp = MKMapPoint(p)
                rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0.1, height: 0.1))
            }
            map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 70, left: 60, bottom: 70, right: 60), animated: true)
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // A pan/zoom by the user switches auto-follow off until they tap re-centre.
            let byUser = mapView.subviews.first?.gestureRecognizers?
                .contains { $0.state == .began || $0.state == .changed } ?? false
            if byUser { DispatchQueue.main.async { self.parent.autoFollow = false } }
        }

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
            guard let a = annotation as? MKPointAnnotation, a === bike else { return nil }
            let id = "bike"
            let v = (m.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: id)
            v.annotation = a
            v.markerTintColor = .systemRed
            v.glyphImage = UIImage(systemName: "bicycle")
            v.displayPriority = .required
            return v
        }
    }
}
