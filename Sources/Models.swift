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

// MARK: - Associated locks (the actual list endpoint)

/// Shape returned by PUT /api/keys/associated_locks (confirmed on device).
/// `location` is GeoJSON-style [longitude, latitude].
struct AssociatedLock: Decodable {
    let _id: String
    let name: String?
    let lock_type: String?
    let lock_serial_no: String?
    let isOwner: Bool?
    let location: [Double]?
    let location_update_time: String?

    func asLock() -> Lock {
        let lat = (location?.count == 2) ? location?[1] : nil
        let lon = (location?.count == 2) ? location?[0] : nil
        return Lock(
            _id: _id,
            name: name,
            serial_no: lock_serial_no,
            is_locked: nil,
            latitude: lat,
            longitude: lon,
            createdAt: nil,
            modifiedAt: location_update_time,
            userProfile_id: nil
        )
    }
}

extension Lock {
    /// Overlay a single-lock lookup: take its locked state, and use its
    /// coordinates only where we don't already have a GPS location.
    func merging(_ other: Lock) -> Lock {
        Lock(
            _id: _id,
            name: name ?? other.name,
            serial_no: serial_no ?? other.serial_no,
            is_locked: other.is_locked ?? is_locked,
            latitude: hasLocation ? latitude : other.latitude,
            longitude: hasLocation ? longitude : other.longitude,
            createdAt: other.createdAt,
            modifiedAt: modifiedAt ?? other.modifiedAt,
            userProfile_id: other.userProfile_id ?? userProfile_id
        )
    }
}

// MARK: - Payments (Stripe) for data-plan renewal

struct PaymentInfo: Decodable {
    let annual_cost: Int?
    let annual_cost_desc: String?
    let stripe_publishable_key: String?
    let stripe_user_id: String?
}

struct SetupIntentData: Decodable {
    let clientSecret: String?
    let customer_id: String?
    let ephemeralKey: String?
}

struct SavedCard: Decodable {
    struct Card: Decodable {
        let brand: String?
        let last4: String?
        let exp_month: Int?
        let exp_year: Int?
    }
    let card: Card?
    let id: String?
}

// MARK: - SIM / data-plan status (from activate_sim_consumer)

struct DataUsage: Decodable {
    let bytes: Int?
    let date: String?
}

struct SimStatus: Decodable {
    let connected: Bool?
    let data_plan_enabled: Bool?
    let activation_expiry: String?
    let initial_data: Int?
    let usage: DataUsage?
    let country: String?
    let theft_status: Int?
    let payment_requires_attention: Bool?
    let recovery_mode: Bool?
    let is_non_cellular: Bool?
}

// MARK: - Live tracking (recovery mode)

struct CurrentTracking: Decodable {
    let activities: [LockActivity]?
    let theft_status: Int?
    let theft_tracking_id: String?
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
