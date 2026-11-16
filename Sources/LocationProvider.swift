import Foundation
import CoreLocation

/// Publishes the phone's current location so we can show it on the map and
/// compute distance to the lock. When-in-use only.
@MainActor
final class LocationProvider: NSObject, ObservableObject {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var authorized = false
    /// Horizontal accuracy (m) of the latest fix, for the parked-location quality.
    @Published var accuracy: Double = -1

    /// Time of the latest GPS fix (not published): tells a fresh fix from a stale one.
    private(set) var fixDate: Date?
    private var lastPublished: CLLocation?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            self.fixDate = l.timestamp
            // Publish only a real change: every published tick redraws the screen.
            let moved = self.lastPublished.map { $0.distance(from: l) > 5 } ?? true
            if moved || abs(self.accuracy - l.horizontalAccuracy) > 10 {
                self.lastPublished = l
                self.coordinate = l.coordinate
                self.accuracy = l.horizontalAccuracy
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
        }
    }
}
