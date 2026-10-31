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

/// Small per-lock UI preferences that should survive app restarts.
enum LockPrefs {
    static func setMovementAlarm(_ on: Bool, serial: String?) {
        guard let serial else { return }
        UserDefaults.standard.set(on, forKey: "movementAlarm_\(serial)")
    }

    static func movementAlarm(serial: String?) -> Bool {
        guard let serial else { return false }
        return UserDefaults.standard.bool(forKey: "movementAlarm_\(serial)")
    }

    static func setBool(_ on: Bool, key: String, serial: String?) {
        guard let serial else { return }
        UserDefaults.standard.set(on, forKey: "\(key)_\(serial)")
    }
    static func bool(_ key: String, serial: String?) -> Bool {
        guard let serial else { return false }
        return UserDefaults.standard.bool(forKey: "\(key)_\(serial)")
    }

    /// Store the PAC the user set (the lock does not return it over BLE, so we
    /// remember what was written, exactly like the official app does).
    static func setPAC(_ code: Int, serial: String?) {
        guard let serial else { return }
        UserDefaults.standard.set(code, forKey: "pac_\(serial)")
    }
    static func pac(serial: String?) -> Int? {
        guard let serial else { return nil }
        let v = UserDefaults.standard.integer(forKey: "pac_\(serial)")
        return v > 0 ? v : nil
    }
}
