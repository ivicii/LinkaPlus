import SwiftUI
import MapKit

struct LockDetailView: View {
    let lock: Lock
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var activities: [LockActivity] = []
    @State private var busy = false
    @State private var error: String?

    @State private var sirenBusy = false
    @State private var sirenMessage: String?

    @State private var recoveryOn = false
    @State private var recoveryBusy = false
    @State private var recoveryMessage: String?
    @State private var confirmEnable = false
    @State private var routePoints: [CLLocationCoordinate2D] = []

    @StateObject private var loc = LocationProvider()

    private var distanceText: String? {
        guard let c = coordinate, let me = loc.coordinate else { return nil }
        let a = CLLocation(latitude: c.latitude, longitude: c.longitude)
        let b = CLLocation(latitude: me.latitude, longitude: me.longitude)
        let meters = a.distance(from: b)
        if meters < 1000 { return String(format: "%.0f m", meters) }
        return String(format: "%.1f km", meters / 1000)
    }

    /// When the lock's GPS location was last updated (location_update_time).
    private var lastLocationDate: Date? { DateUtils.parseAny(lock.modifiedAt) }

    private var latestBattery: Int? {
        activities.compactMap { $0.batteryPercent }.first { $0 > 0 }
    }

    /// Best known coordinate: the lock's own, else the most recent located activity.
    private var coordinate: CLLocationCoordinate2D? {
        if lock.hasLocation, let lat = lock.latitude, let lon = lock.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if let a = activities.first(where: { $0.hasLocation }), let lat = a.latitude, let lon = a.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                mapView
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
            } footer: {
                if let d = lastLocationDate {
                    Label("Locatie bijgewerkt: \(DateUtils.absoluteWithRelative(d))",
                          systemImage: "clock.arrow.circlepath")
                } else {
                    Text("Tijd van laatste locatie onbekend.")
                }
            }

            Section("Status") {
                statusRow(
                    "Slot",
                    value: (lock.is_locked ?? true) ? "Vergrendeld" : "Ontgrendeld",
                    systemImage: (lock.is_locked ?? true) ? "lock.fill" : "lock.open.fill"
                )
                if let battery = latestBattery {
                    HStack {
                        Label("Batterij", systemImage: batteryIcon(battery))
                        Spacer()
                        Text("\(battery)%" + (battery < 20 ? "  ⚠︎ laag" : ""))
                            .foregroundStyle(battery < 20 ? .red : .secondary)
                    }
                }
                if let distanceText {
                    statusRow("Afstand tot slot", value: distanceText, systemImage: "location.fill")
                }
                if let serial = lock.serial_no {
                    statusRow("Serienummer", value: serial, systemImage: "number")
                }
                if let coordinate {
                    statusRow(
                        "Coördinaten",
                        value: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                        systemImage: "mappin.and.ellipse"
                    )
                    Button {
                        openInMaps(coordinate)
                    } label: {
                        Label("Open in Kaarten / routebeschrijving", systemImage: "car.fill")
                    }
                }
            }

            Section("Vinden") {
                Button(action: playSiren) {
                    HStack {
                        if sirenBusy { ProgressView() }
                        Label("Laat geluid afspelen (sirene)", systemImage: "speaker.wave.3.fill")
                    }
                }
                .disabled(sirenBusy || lock.serial_no == nil)
                if let sirenMessage {
                    Text(sirenMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                if recoveryOn {
                    Button(role: .destructive) { setRecovery(false) } label: {
                        HStack {
                            if recoveryBusy { ProgressView() }
                            Label("Stop tracking (recovery)", systemImage: "stop.circle.fill")
                        }
                    }
                    .disabled(recoveryBusy)
                    Button {
                        Task { await refreshRoute() }
                    } label: {
                        Label("Route verversen (\(routePoints.count) punten)", systemImage: "arrow.clockwise")
                    }
                } else {
                    Button { confirmEnable = true } label: {
                        HStack {
                            if recoveryBusy { ProgressView() }
                            Label("Zet in tracking-/recovery-modus", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                    .disabled(recoveryBusy || lock.serial_no == nil)
                }
                if let recoveryMessage {
                    Text(recoveryMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Live tracking")
            } footer: {
                Text("Recovery-modus is de anti-diefstalstand: het slot stuurt dan continu zijn GPS-positie door (verbruikt meer batterij en dataplan). De afgelegde route verschijnt op de kaart.")
            }

            Section("Activiteiten") {
                if busy && activities.isEmpty {
                    HStack { ProgressView(); Text("Laden…").foregroundStyle(.secondary) }
                } else if activities.isEmpty {
                    Text(error ?? "Nog geen activiteiten.").foregroundStyle(.secondary)
                } else {
                    ForEach(activities) { ActivityRow(activity: $0) }
                }
            }
        }
        .navigationTitle(lock.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loc.start()
            await load()
            await syncRecoveryState()
        }
        .refreshable {
            await load()
            await syncRecoveryState()
        }
        .alert("Tracking-/recovery-modus aanzetten?", isPresented: $confirmEnable) {
            Button("Annuleer", role: .cancel) {}
            Button("Aanzetten", role: .destructive) { setRecovery(true) }
        } message: {
            Text("Dit is de anti-diefstalstand. Je slot gaat continu zijn GPS-positie doorsturen (meer batterij- en dataverbruik). Je kunt het weer uitzetten.")
        }
    }

    @ViewBuilder
    private var mapView: some View {
        if let coordinate {
            LockMapView(coordinate: coordinate, title: lock.displayName, route: routePoints)
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                VStack(spacing: 6) {
                    Image(systemName: "mappin.slash").font(.title)
                    Text("Geen locatie bekend voor dit slot").font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statusRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<70: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    private func openInMaps(_ c: CLLocationCoordinate2D) {
        let place = MKPlacemark(coordinate: c)
        let item = MKMapItem(placemark: place)
        item.name = lock.displayName
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func playSiren() {
        guard let serial = lock.serial_no else { return }
        sirenBusy = true
        sirenMessage = nil
        Task {
            do {
                try await api.activateSiren(serial: serial, auth: session.identity())
                sirenMessage = "Sirene geactiveerd — luister naar je slot."
            } catch {
                sirenMessage = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error)"
            }
            sirenBusy = false
        }
    }

    private func setRecovery(_ enable: Bool) {
        guard let serial = lock.serial_no else { return }
        recoveryBusy = true; recoveryMessage = nil
        Task {
            do {
                try await api.setRecoveryMode(serial: serial, enabled: enable, auth: session.identity())
                recoveryOn = enable
                if enable {
                    recoveryMessage = "Tracking gestart. Het kan even duren voor de eerste GPS-punten binnen zijn — tik op 'Route verversen'."
                    await refreshRoute()
                } else {
                    recoveryMessage = "Tracking gestopt."
                    routePoints = []
                }
            } catch {
                recoveryMessage = (error as? LocalizedError)?.errorDescription ?? "Mislukt: \(error)"
            }
            recoveryBusy = false
        }
    }

    /// Reads whether tracking is currently active (current_tracking succeeds
    /// only in tracking mode) and loads the route if so.
    private func syncRecoveryState() async {
        guard lock.serial_no != nil else { return }
        if let pts = try? await trackingCoords() {
            routePoints = pts
            recoveryOn = true
        } else {
            recoveryOn = false
        }
    }

    private func refreshRoute() async {
        if let pts = try? await trackingCoords() { routePoints = pts }
    }

    private func trackingCoords() async throws -> [CLLocationCoordinate2D] {
        guard let serial = lock.serial_no else { return [] }
        let pts = try await api.currentTracking(serial: serial, auth: session.identity())
        return pts
            .filter { $0.hasLocation }
            .sorted { (DateUtils.parseAny($0.timestamp) ?? .distantPast) < (DateUtils.parseAny($1.timestamp) ?? .distantPast) }
            .compactMap { a in
                guard let la = a.latitude, let lo = a.longitude else { return nil }
                return CLLocationCoordinate2D(latitude: la, longitude: lo)
            }
    }

    private func load() async {
        guard let serial = lock.serial_no else { return }
        busy = true; error = nil
        do {
            let result = try await api.fetchActivities(serial: serial, auth: session.identity())
            activities = result.sorted {
                let d0 = DateUtils.parseAny($0.timestamp) ?? DateUtils.parseISO($0.createdAt) ?? .distantPast
                let d1 = DateUtils.parseAny($1.timestamp) ?? DateUtils.parseISO($1.createdAt) ?? .distantPast
                return d0 > d1
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = false
    }
}

struct ActivityRow: View {
    let activity: LockActivity

    private var timeText: String? {
        if let d = DateUtils.parseAny(activity.timestamp) ?? DateUtils.parseISO(activity.createdAt) {
            return DateUtils.absolute(d)
        }
        return activity.timestamp ?? activity.createdAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(activity.msg_title ?? "Activiteit").font(.subheadline.bold())
                Spacer()
                if let b = activity.batteryPercent, b > 0 {
                    Text("\(b)%").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let desc = activity.msg_desc, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
            if let timeText {
                Text(timeText).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
