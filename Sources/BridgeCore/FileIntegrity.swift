import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Portable SHA-256 for artifact identity, not publisher authentication.
/// Streaming avoids loading game/install images into memory on either host.
public enum FileIntegrity {
    public static func sha256(_ url: URL) throws -> String {
        guard url.isFileURL, url.path.hasPrefix("/"),
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw BridgeError.persistence("Integrity checks require a readable regular file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var hash = SHA256()
        #else
        var hash = SHA256Digest()
        #endif
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            #if canImport(CryptoKit)
            hash.update(data: chunk)
            #else
            hash.update(chunk)
            #endif
        }
        #if canImport(CryptoKit)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return hash.finish()
        #endif
    }
    public static func sha256(data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var hash = SHA256Digest(); hash.update(data); return hash.finish()
        #endif
    }
}

private struct SHA256Digest {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    mutating func update(_ data: Data) {
        length &+= UInt64(data.count)
        pending.append(contentsOf: data)
        var offset = 0
        while offset + 64 <= pending.count {
            compress(Array(pending[offset..<offset + 64])); offset += 64
        }
        if offset > 0 { pending = Array(pending.dropFirst(offset)) }
    }
    mutating func finish() -> String {
        let bits = length &* 8
        pending.append(0x80)
        while pending.count % 64 != 56 { pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { pending.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        for offset in stride(from: 0, to: pending.count, by: 64) { compress(Array(pending[offset..<offset + 64])) }
        return state.map { String(format: "%08x", $0) }.joined()
    }
    private func rotate(_ value: UInt32, _ bits: UInt32) -> UInt32 { (value >> bits) | (value << (32 - bits)) }
    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { w[i] = (0..<4).reduce(0) { ($0 << 8) | UInt32(block[i * 4 + $1]) } }
        for i in 16..<64 {
            let a = w[i - 15], b = w[i - 2]
            w[i] = w[i - 16] &+ (rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)) &+ w[i - 7] &+ (rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10))
        }
        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let t1 = h &+ (rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)) &+ ((e & f) ^ (~e & g)) &+ Self.constants[i] &+ w[i]
            let t2 = (rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        for (i, value) in [a,b,c,d,e,f,g,h].enumerated() { state[i] &+= value }
    }
}
