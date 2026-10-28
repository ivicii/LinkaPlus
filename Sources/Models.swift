import Foundation

// MARK: - Generic envelope

struct APIEnvelope<T: Decodable>: Decodable {
    let status: String?
    let message: String?
    let data: T?

    var isSuccess: Bool { status == "success" }
}

/// A response that only carries status/message (no data payload we care about).
struct APIStatus: Decodable {
    let status: String?
    let message: String?
    var isSuccess: Bool { status == "success" }
}

// MARK: - Auth

struct LoginData: Decodable {
    let authToken: String
    let userId: String
    let userEmail: String?
    let first_name: String?
    let last_name: String?
    let name: String?
    let showWalkthrough: Bool?
}

// MARK: - Locks

struct Lock: Decodable, Identifiable, Hashable {
    let _id: String
    let name: String?
    let serial_no: String?
    let is_locked: Bool?
    let latitude: Double?
    let longitude: Double?
    let createdAt: String?
    let modifiedAt: String?
    let userProfile_id: String?

    var id: String { _id }

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let s = serial_no, !s.isEmpty { return s }
        return "LINKA-slot"
    }

    /// A lock has a usable map location only when coordinates are present and non-zero.
    var hasLocation: Bool {
        guard let lat = latitude, let lon = longitude else { return false }
        return !(lat == 0 && lon == 0)
    }
}

// MARK: - Activities

struct LockActivity: Decodable, Identifiable {
    let _id: String?
    let createdAt: String?
    let direction: Int?
    let latitude: Double?
    let longitude: Double?
    let lock_serial_no: String?
    let msg_title: String?
    let msg_desc: String?
    let timestamp: String?
    let timestamp_locked: String?
    let linka_activity_status: Int?
    let batteryPercent: Int?
    let owner: String?

    var id: String { _id ?? UUID().uuidString }

    var hasLocation: Bool {
        guard let lat = latitude, let lon = longitude else { return false }
        return !(lat == 0 && lon == 0)
    }
}
