import Foundation

/// Local cache (in the Keychain) of the access key and lock list, so the app
/// keeps working over Bluetooth even if the LINKA cloud becomes unavailable.
enum LockCache {
    static func saveKeys(_ keys: AccessKeys, serial: String) {
        if let data = try? JSONEncoder().encode(keys), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: "keys_\(serial)")
        }
    }

    static func loadKeys(serial: String) -> AccessKeys? {
        guard let s = Keychain.get("keys_\(serial)"), let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AccessKeys.self, from: data)
    }

    static func saveLocks(_ locks: [Lock]) {
        if let data = try? JSONEncoder().encode(locks), let s = String(data: data, encoding: .utf8) {
            Keychain.set(s, for: "locks_cache")
        }
    }

    static func loadLocks() -> [Lock] {
        guard let s = Keychain.get("locks_cache"), let data = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Lock].self, from: data)) ?? []
    }
}
