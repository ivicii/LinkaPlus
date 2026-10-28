import SwiftUI
import MapKit

struct LockDetailView: View {
    let lock: Lock
    @EnvironmentObject var session: SessionStore
    private let api = APIClient()

    @State private var activities: [LockActivity] = []
    @State private var busy = false
    @State private var error: String?

    // iOS 16-compatible map region.
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.0, longitude: 5.0),
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

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
            }

            Section("Status") {
                statusRow(
                    "Slot",
                    value: (lock.is_locked ?? true) ? "Vergrendeld" : "Ontgrendeld",
                    systemImage: (lock.is_locked ?? true) ? "lock.fill" : "lock.open.fill"
                )
                if let battery = latestBattery {
                    statusRow("Batterij", value: "\(battery)%", systemImage: batteryIcon(battery))
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
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private var mapView: some View {
        if let coordinate {
            Map(coordinateRegion: $region, annotationItems: [MapPin(coordinate: coordinate)]) { pin in
                MapMarker(coordinate: pin.coordinate, tint: .red)
            }
            .onAppear {
                region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                )
            }
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

    private func load() async {
        guard let serial = lock.serial_no else { return }
        busy = true; error = nil
        do {
            let result = try await api.fetchActivities(serial: serial, auth: session.identity())
            activities = result.sorted { ($0.timestamp ?? $0.createdAt ?? "") > ($1.timestamp ?? $1.createdAt ?? "") }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        busy = false
    }
}

struct MapPin: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct ActivityRow: View {
    let activity: LockActivity
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
            if let ts = activity.timestamp ?? activity.createdAt {
                Text(ts).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
