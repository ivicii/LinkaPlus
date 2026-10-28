import Foundation
import CommonCrypto

/// Port of the LINKA "Lock Enc V1" command protocol (pc/g, pc/f, pc/k).
/// Builds the 20-byte encrypted command frame written to D31E0002.
enum LinkaCrypto {

    // Embedded static keys (extracted from the APK dex).
    static let staticKeyA: [UInt8] = hex("f985deefecec2df4c79c91e2314b8466")
    static let staticKeyB: [UInt8] = hex("7c235022766280bd6b7a5b99ca9b5a29")
    // Constant nonce used for subkey derivation (pc/g.f).
    static let subkeyNonce: [UInt8] = [0,0,0,0xb2,0x9c,0x0d,0x53,0xf6,0xca,0xeb,0,0,0,0,0,0]

    enum Priv { case admin, user }

    // MARK: CRC-16/CCITT (poly 0x1021, init 0xFFFF, MSB-first) — pc/k.a
    static func crc16(_ bytes: [UInt8], _ len: Int) -> UInt16 {
        var crc: UInt32 = 0xFFFF
        for i in 0..<len {
            for bit in 0..<8 {
                let b = ((Int(bytes[i]) >> (7 - bit)) & 1) == 1
                let c = ((crc >> 15) & 1) == 1
                crc = (crc << 1) & 0xFFFFFFFF
                if b != c { crc ^= 4129 }
            }
        }
        return UInt16(crc & 0xFFFF)
    }

    /// pc/f.l — CRC over all but last 2 bytes, stored big-endian in the last 2.
    static func applyCRC(_ buf: inout [UInt8]) {
        let c = crc16(buf, buf.count - 2)
        buf[buf.count - 1] = UInt8(c & 0xff)
        buf[buf.count - 2] = UInt8((c >> 8) & 0xff)
    }

    // MARK: AES-128-CBC, no padding
    static func aesCBC(key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0), // CBC, no padding
            key, key.count, iv, data, data.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return [] }
        return Array(out.prefix(moved))
    }

    // MARK: Subkey derivation (pc/g.f)
    static func deriveSubkey(masterKey: [UInt8], slot: Int, revMAC: [UInt8], priv: Priv, encVer: Int) -> [UInt8] {
        var nonce = subkeyNonce
        let staticKey = (encVer == 0 || encVer == 1) ? staticKeyA : staticKeyB
        nonce[0] = (encVer == 0 || encVer == 1) ? UInt8(encVer) : 2
        nonce[1] = (priv == .admin) ? 0 : 1
        nonce[2] = (slot == 0) ? 0x11 : 0x22
        for i in 0..<6 { nonce[10 + i] = revMAC[i] }
        return aesCBC(key: masterKey, iv: nonce, data: staticKey)
    }

    // MARK: Command frame (pc/g.g with setSubkey) — payload is e.g. [cmd, param]
    /// cmd: 0 = unlock, 1 = lock. `subkey` is the access key used directly
    /// (the app calls setSubkey(key,1,priv), so f36009f==1 → flag bit 0x40,
    /// and no master-key derivation is done).
    static func commandFrame(mac: [UInt8], payload: [UInt8], subkey: [UInt8],
                             priv: Priv, counter: UInt32) -> [UInt8] {
        let revMAC = (0..<6).map { mac[5 - $0] }   // bArr7[5-i] = mac[i]

        // payload block (16 bytes): [0x10, payload..., CRC]
        var block = [UInt8](repeating: 0, count: 16)
        block[0] = 0x10
        for (i, b) in payload.enumerated() { block[1 + i] = b }
        applyCRC(&block)

        // IV = revMAC(6) + counter LE(4) + zeros
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { iv[i] = revMAC[i] }
        iv[6] = UInt8(counter & 0xff)
        iv[7] = UInt8((counter >> 8) & 0xff)
        iv[8] = UInt8((counter >> 16) & 0xff)
        iv[9] = UInt8((counter >> 24) & 0xff)

        let enc = aesCBC(key: subkey, iv: iv, data: block)

        // frame (20 bytes)
        var frame = [UInt8](repeating: 0, count: 20)
        frame[0] = 20
        var flag: UInt8 = 0x80 | 0x40   // f36009f == 1
        if priv == .user { flag |= 0x10 }
        frame[1] = flag
        for i in 0..<16 { frame[2 + i] = (i < enc.count) ? enc[i] : 0 }
        applyCRC(&frame)
        return frame
    }

    /// Payload for a WRITE-setting packet (pc/i: VCMD_SET_SETTING).
    /// [0x03, idx, value LE(4), value2 LE(4), 0,0,0]  → 13 bytes.
    static func settingPayload(idx: Int, value: Int) -> [UInt8] {
        var p: [UInt8] = [0x03, UInt8(idx & 0xff)]
        let v = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        p += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)]
        p += [0, 0, 0, 0]   // value2
        p += [0, 0, 0]      // padding to 13
        return p
    }

    // MARK: Status frame parse (pc/e) — encVer = byte[2], counter = int32 LE at [3..6]
    static func parseStatus(_ frame: [UInt8]) -> (encVer: Int, counter: UInt32)? {
        guard frame.count >= 7 else { return nil }
        let encVer = Int(frame[2])
        let counter = UInt32(frame[3]) | (UInt32(frame[4]) << 8) | (UInt32(frame[5]) << 16) | (UInt32(frame[6]) << 24)
        return (encVer, counter)
    }

    // MARK: helpers
    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex, let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) {
            if let b = UInt8(s[idx..<next], radix: 16) { out.append(b) }
            idx = next
        }
        return out
    }
    static func toHex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    /// Parse a MAC string "FB:80:2B:7A:C2:EB" into 6 bytes.
    static func macBytes(_ serial: String) -> [UInt8]? {
        let parts = serial.split(separator: ":")
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        return bytes.count == 6 ? bytes : nil
    }
}
