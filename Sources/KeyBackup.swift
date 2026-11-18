import Foundation
import CryptoKit
import CommonCrypto

/// Encrypted backup of the lock access keys so the app keeps working even if
/// the LINKA cloud disappears or the phone is lost. The backup is sealed with a
/// passphrase (PBKDF2-SHA256 → AES-GCM); without it the file is useless.
enum KeyBackup {
    static let fileExtension = "linkabackup"

    struct Payload: Codable {
        var version = 2
        var exportedAt = Date()
        var locks: [Lock]
        var keys: [String: String]   // serial → AccessKeys JSON (as stored in Keychain)
        var pacs: [String: Int]      // serial → PAC (if the user set one)
    }

    private struct Envelope: Codable {
        let v: Int
        let salt: String            // base64
        let nonce: String           // base64
        let ct: String              // base64 (ciphertext + tag)
    }

    enum BackupError: LocalizedError {
        case noKeys, badFile, wrongPassphrase
        var errorDescription: String? {
            switch self {
            case .noKeys: return "Geen sloten of sleutels om te back-uppen."
            case .badFile: return "Dit is geen geldig back-upbestand."
            case .wrongPassphrase: return "Verkeerd wachtwoord of beschadigd bestand."
            }
        }
    }

    // MARK: Gather / apply

    static func gather() -> Payload {
        let locks = LockCache.loadLocks()
        var keys: [String: String] = [:]
        var pacs: [String: Int] = [:]
        for lock in locks {
            guard let serial = lock.serial_no else { continue }
            if let k = Keychain.get("keys_\(serial)") { keys[serial] = k }
            if let p = LockPrefs.pac(serial: serial) { pacs[serial] = p }
        }
        return Payload(locks: locks, keys: keys, pacs: pacs)
    }

    static var hasSomethingToBackup: Bool { !gather().keys.isEmpty }

    static func apply(_ payload: Payload) {
        // Merge with what's already here (don't drop existing locks).
        var locks = LockCache.loadLocks()
        let known = Set(locks.compactMap { $0.serial_no })
        for lock in payload.locks where !(lock.serial_no.map(known.contains) ?? false) {
            locks.append(lock)
        }
        LockCache.saveLocks(locks)
        for (serial, k) in payload.keys { Keychain.set(k, for: "keys_\(serial)") }
        for (serial, p) in payload.pacs { LockPrefs.setPAC(p, serial: serial) }
    }

    // MARK: Encrypt / decrypt

    static func export(passphrase: String) throws -> Data {
        let payload = gather()
        guard !payload.keys.isEmpty else { throw BackupError.noKeys }
        let plain = try JSONEncoder().encode(payload)
        var salt = Data(count: 16); _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = deriveKey(passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw BackupError.badFile }
        let env = Envelope(v: 1, salt: salt.base64EncodedString(),
                           nonce: Data(sealed.nonce).base64EncodedString(),
                           ct: combined.base64EncodedString())
        return try JSONEncoder().encode(env)
    }

    static func restore(_ data: Data, passphrase: String) throws {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data),
              let salt = Data(base64Encoded: env.salt),
              let combined = Data(base64Encoded: env.ct) else { throw BackupError.badFile }
        let key = deriveKey(passphrase, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let plain = try AES.GCM.open(box, using: key)
            let payload = try JSONDecoder().decode(Payload.self, from: plain)
            apply(payload)
        } catch {
            throw BackupError.wrongPassphrase
        }
    }

    /// PBKDF2-SHA256, 200k rounds → 32-byte AES key.
    private static func deriveKey(_ passphrase: String, salt: Data) -> SymmetricKey {
        var derived = Data(count: 32)
        let pass = Array(passphrase.utf8)
        _ = derived.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.map { Int8(bitPattern: $0) }, pass.count,
                    saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    200_000,
                    outBuf.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return SymmetricKey(data: derived)
    }
}
