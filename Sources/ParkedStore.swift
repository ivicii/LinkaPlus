import Foundation
import CoreLocation

/// Where the bike was parked: the phone's location captured the moment the lock
/// closed. Like a car's parked-location pin, but for your bike. Per lock, kept
/// across app restarts.
enum ParkedStore {
    struct Spot: Codable {
        let lat: Double
        let lon: Double
        let at: Double          // epoch seconds
        let accuracy: Double    // metres (−1 = unknown)
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
        var date: Date { Date(timeIntervalSince1970: at) }
    }

    private static func key(_ serial: String) -> String { "parked_\(serial)" }

    static func save(_ c: CLLocationCoordinate2D, accuracy: Double, serial: String?) {
        guard let serial else { return }
        let spot = Spot(lat: c.latitude, lon: c.longitude, at: Date().timeIntervalSince1970, accuracy: accuracy)
        if let d = try? JSONEncoder().encode(spot) {
            UserDefaults.standard.set(d, forKey: key(serial))
        }
    }

    static func load(serial: String?) -> Spot? {
        guard let serial, let d = UserDefaults.standard.data(forKey: key(serial)) else { return nil }
        return try? JSONDecoder().decode(Spot.self, from: d)
    }

    static func clear(serial: String?) {
        guard let serial else { return }
        UserDefaults.standard.removeObject(forKey: key(serial))
    }
}
