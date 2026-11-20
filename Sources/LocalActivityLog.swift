import Foundation

/// On-device activity log. The cloud feed only receives events the lock sends
/// over its own cellular link, so locally observed open/close events and
/// battery readings are recorded here and merged into the statistics.
enum LocalActivityLog {
    struct Entry: Codable { let ts: Double; let kind: String; let battery: Int? }

    private static func key(_ serial: String) -> String { "localActs_\(serial)" }

    private static func entries(_ serial: String) -> [Entry] {
        guard let d = UserDefaults.standard.data(forKey: key(serial)) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static func record(kind: String, battery: Int? = nil, serial: String?) {
        guard let serial else { return }
        var e = entries(serial)
        e.append(Entry(ts: Date().timeIntervalSince1970, kind: kind, battery: battery))
        if e.count > 1500 { e.removeFirst(e.count - 1500) }
        if let d = try? JSONEncoder().encode(e) { UserDefaults.standard.set(d, forKey: key(serial)) }
    }

    static func lastTimestamp(kind: String, serial: String?) -> Date? {
        guard let serial, let t = entries(serial).last(where: { $0.kind == kind })?.ts else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// The most recent battery reading we actually saw (over Bluetooth), with its
    /// age. There is no cloud battery feed, so this is the only "last known" value.
    static func lastBattery(serial: String?) -> (pct: Int, date: Date)? {
        guard let serial, let e = entries(serial).last(where: { ($0.battery ?? 0) > 0 }),
              let b = e.battery else { return nil }
        return (b, Date(timeIntervalSince1970: e.ts))
    }

    static func load(serial: String?) -> [LockActivity] {
        guard let serial else { return [] }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries(serial).map { e in
            let title: String? = e.kind == "open" ? "Ontgrendeld (lokaal)" : e.kind == "close" ? "Vergrendeld (lokaal)" : nil
            return LockActivity(_id: "local-\(e.ts)-\(e.kind)", createdAt: f.string(from: Date(timeIntervalSince1970: e.ts)),
                                direction: e.kind == "open" ? 0 : e.kind == "close" ? 1 : nil,
                                latitude: nil, longitude: nil, lock_serial_no: serial,
                                msg_title: title, msg_desc: nil, timestamp: nil, timestamp_locked: nil,
                                linka_activity_status: nil, batteryPercent: e.battery, owner: "local")
        }
    }
}
