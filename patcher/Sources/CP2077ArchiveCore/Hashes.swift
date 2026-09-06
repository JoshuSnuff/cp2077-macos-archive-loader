import CryptoKit
import Foundation

public enum Hashes {
    private static let fnvOffset: UInt64 = 0xcbf29ce484222325
    private static let fnvPrime: UInt64 = 0x100000001b3
    private static let crc64Poly: UInt64 = 0xC96C5795D7870F42

    private static let crc64Table: [UInt64] = (0..<256).map { index in
        var crc = UInt64(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ crc64Poly : crc >> 1
        }
        return crc
    }

    public static func fnv1a64Path(_ path: String) -> UInt64 {
        var hash = fnvOffset
        let normalized = path.lowercased().replacingOccurrences(of: "/", with: "\\")
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    public static func crc64(_ data: Data) -> UInt64 {
        var crc = UInt64.max
        for byte in data {
            let index = Int((crc ^ UInt64(byte)) & 0xff)
            crc = (crc >> 8) ^ crc64Table[index]
        }
        return ~crc
    }

    public static func hex64(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16).leftPadded(to: 16, with: "0")
    }

    /// Streaming SHA-256 of a file, lowercase hex.
    ///
    /// Read in chunks because the archives this hashes run to gigabytes and
    /// the baseline hashes every one of them.
    ///
    /// The `autoreleasepool` is load-bearing, not decoration. `FileHandle`
    /// bridges to Objective-C and hands back an autoreleased `NSData` per
    /// chunk; a command-line tool has no run loop to drain the pool, so
    /// without one here every chunk read stays alive for the whole process.
    /// Hashing one baseline that way grows to the size of the archive set —
    /// measured at 1.17 GB resident for a single 3 GB file, and a SIGKILL
    /// partway through the real 83 GB install. Draining per chunk holds it
    /// flat at about 10 MB.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while try autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        if count >= length { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}

