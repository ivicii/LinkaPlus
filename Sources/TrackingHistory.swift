import Foundation
import CoreLocation

/// One saved recovery/tracking session: when it ran and the positions received.
struct TrackingSession: Codable, Identifiable {
    var id: String          // stable per session (derived from its start time)
    var start: Date
    var end: Date?          // nil while still running
    var coords: [[Double]]  // [lat, lon] pairs
    var times: [Double]?    // epoch seconds per coord (same order); nil for old sessions
    var speeds: [Double]?   // m/s per coord
    var headings: [Double]? // raw direction value per coord (×10 = degrees)
    var uncerts: [Double]?  // GPS accuracy radius (m) per coord
    var reports: Int?       // total reports the lock sent (incl. ones without a fix)

    var locations: [CLLocationCoordinate2D] {
        coords.compactMap { $0.count >= 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
    }

    /// Timestamp of the position at `i`, when known.
    func date(at i: Int) -> Date? {
        guard let times, i < times.count, times[i] > 0 else { return nil }
        return Date(timeIntervalSince1970: times[i])
    }
    func speedKmh(at i: Int) -> Int? {
        guard let speeds, i < speeds.count, speeds[i] >= 0 else { return nil }
        return Int((speeds[i] * 3.6).rounded())
    }
    func headingDegrees(at i: Int) -> Int? {
        guard let headings, i < headings.count, headings[i] >= 0 else { return nil }
        return Int(headings[i]) * 10
    }
    func accuracy(at i: Int) -> Int? {
        guard let uncerts, i < uncerts.count, uncerts[i] >= 0 else { return nil }
        return Int(uncerts[i].rounded())
    }
    /// A position is flagged imprecise at ≥ 50 m, like the official app.
    func isImprecise(at i: Int) -> Bool {
        if let u = accuracy(at: i) { return u >= 50 }
        return false
    }
    var impreciseCount: Int { (0..<coords.count).filter { isImprecise(at: $0) }.count }
}

/// Per-lock archive of tracking sessions, stored in UserDefaults so each session's
/// map and points stay browsable after it ends.
enum TrackingHistory {
    private static func key(_ s: String) -> String { "recoverySessions_\(s)" }

    static func all(serial: String?) -> [TrackingSession] {
        guard let serial, let d = UserDefaults.standard.data(forKey: key(serial)),
              let a = try? JSONDecoder().decode([TrackingSession].self, from: d) else { return [] }
        return a.sorted { $0.start > $1.start }   // newest first
    }

    /// Insert the session, or replace the existing one with the same id.
    static func upsert(_ session: TrackingSession, serial: String?) {
        guard let serial else { return }
        var all = raw(serial)
        if let i = all.firstIndex(where: { $0.id == session.id }) { all[i] = session }
        else { all.append(session) }
        if all.count > 100 { all.removeFirst(all.count - 100) }
        write(all, serial: serial)
    }

    static func delete(id: String, serial: String?) {
        guard let serial else { return }
        write(raw(serial).filter { $0.id != id }, serial: serial)
    }

    static func clearAll(serial: String?) {
        guard let serial else { return }
        UserDefaults.standard.removeObject(forKey: key(serial))
    }

    private static func raw(_ serial: String) -> [TrackingSession] {
        guard let d = UserDefaults.standard.data(forKey: key(serial)),
              let a = try? JSONDecoder().decode([TrackingSession].self, from: d) else { return [] }
        return a
    }
    private static func write(_ s: [TrackingSession], serial: String) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key(serial)) }
    }
}
