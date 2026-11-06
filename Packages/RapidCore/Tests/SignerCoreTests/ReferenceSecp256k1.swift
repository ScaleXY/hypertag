import CryptoKit
import Foundation

// A second secp256k1 implementation, in plain Swift and sharing no code with libsecp256k1.
// Test use only: it is slow and not constant time.

struct U256: Equatable, Comparable {
    /// Little-endian 64-bit limbs.
    var limbs: [UInt64]

    static let zero = U256(limbs: [0, 0, 0, 0])
    static let one = U256(limbs: [1, 0, 0, 0])

    init(limbs: [UInt64]) { self.limbs = limbs }

    init(bytes: some Sequence<UInt8>) {
        let bytes = Array(bytes)
        precondition(bytes.count == 32)
        limbs = (0..<4).map { limb in
            bytes[(24 - limb * 8)..<(32 - limb * 8)].reduce(0) { $0 << 8 | UInt64($1) }
        }
    }

    init(hex: String) { self.init(bytes: Data(hex: hex)) }

    var bytes: [UInt8] {
        limbs.reversed().flatMap { limb in (0..<8).reversed().map { UInt8(truncatingIfNeeded: limb >> ($0 * 8)) } }
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }
    var isOdd: Bool { limbs[0] & 1 == 1 }

    func bit(_ index: Int) -> Bool { limbs[index / 64] >> (index % 64) & 1 == 1 }

    static func < (a: U256, b: U256) -> Bool {
        for index in (0..<4).reversed() where a.limbs[index] != b.limbs[index] {
            return a.limbs[index] < b.limbs[index]
        }
        return false
    }

    func adding(_ other: U256) -> (sum: U256, carry: Bool) {
        var result = self
        var carry: UInt64 = 0
        for index in 0..<4 {
            let (first, overflow1) = limbs[index].addingReportingOverflow(other.limbs[index])
            let (second, overflow2) = first.addingReportingOverflow(carry)
            result.limbs[index] = second
            carry = overflow1 || overflow2 ? 1 : 0
        }
        return (result, carry == 1)
    }

    /// Wraps around modulo 2^256.
    func subtracting(_ other: U256) -> U256 {
        var result = self
        var borrow: UInt64 = 0
        for index in 0..<4 {
            let (first, overflow1) = limbs[index].subtractingReportingOverflow(other.limbs[index])
            let (second, overflow2) = first.subtractingReportingOverflow(borrow)
            result.limbs[index] = second
            borrow = overflow1 || overflow2 ? 1 : 0
        }
        return result
    }

    func multipliedFullWidth(by other: U256) -> (high: U256, low: U256) {
        var product = [UInt64](repeating: 0, count: 8)
        for i in 0..<4 {
            var carry: UInt64 = 0
            for j in 0..<4 {
                let (high, low) = limbs[i].multipliedFullWidth(by: other.limbs[j])
                let (partial, overflow1) = product[i + j].addingReportingOverflow(low)
                let (total, overflow2) = partial.addingReportingOverflow(carry)
                product[i + j] = total
                carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
            }
            product[i + 4] = carry
        }
        return (U256(limbs: Array(product[4...])), U256(limbs: Array(product[..<4])))
    }
}

/// Arithmetic modulo m, where m = 2^256 - c. Both secp256k1 moduli have this form.
struct Modulus {
    let m: U256
    let c: U256

    init(_ m: U256) {
        self.m = m
        c = U256.zero.subtracting(m)
    }

    func reduce(_ a: U256) -> U256 { a >= m ? a.subtracting(m) : a }

    func add(_ a: U256, _ b: U256) -> U256 {
        let (sum, carry) = a.adding(b)
        return carry || sum >= m ? sum.subtracting(m) : sum
    }

    func sub(_ a: U256, _ b: U256) -> U256 {
        a >= b ? a.subtracting(b) : a.adding(m.subtracting(b)).sum
    }

    func mul(_ a: U256, _ b: U256) -> U256 {
        var (high, low) = a.multipliedFullWidth(by: b)
        // high * 2^256 + low is congruent to high * c + low.
        while !high.isZero {
            let (foldHigh, foldLow) = high.multipliedFullWidth(by: c)
            let (sum, carry) = foldLow.adding(low)
            low = sum
            high = carry ? foldHigh.adding(.one).sum : foldHigh
        }
        return reduce(low)
    }

    func pow(_ base: U256, _ exponent: U256) -> U256 {
        var result = U256.one
        for index in (0..<256).reversed() {
            result = mul(result, result)
            if exponent.bit(index) { result = mul(result, base) }
        }
        return result
    }

    func inverse(_ a: U256) -> U256 { pow(a, m.subtracting(U256(limbs: [2, 0, 0, 0]))) }
}

enum ReferenceSecp256k1 {
    static let p = Modulus(U256(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F"))
    static let n = Modulus(U256(hex: "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"))
    static let halfN = U256(hex: "7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0")
    static let generator = Point(
        x: U256(hex: "79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798"),
        y: U256(hex: "483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8")
    )

    struct Point: Equatable {
        var x: U256
        var y: U256
    }

    /// Jacobian coordinates. z == 0 is the point at infinity.
    private struct Jacobian {
        var x: U256, y: U256, z: U256
        static let infinity = Jacobian(x: .one, y: .one, z: .zero)
        init(x: U256, y: U256, z: U256) { self.x = x; self.y = y; self.z = z }
        init(_ point: Point) { self.init(x: point.x, y: point.y, z: .one) }
    }

    private static func double(_ a: Jacobian) -> Jacobian {
        if a.z.isZero || a.y.isZero { return .infinity }
        let ySquared = p.mul(a.y, a.y)
        let s = p.mul(U256(limbs: [4, 0, 0, 0]), p.mul(a.x, ySquared))
        let m = p.mul(U256(limbs: [3, 0, 0, 0]), p.mul(a.x, a.x))
        let x = p.sub(p.mul(m, m), p.add(s, s))
        let y = p.sub(p.mul(m, p.sub(s, x)), p.mul(U256(limbs: [8, 0, 0, 0]), p.mul(ySquared, ySquared)))
        return Jacobian(x: x, y: y, z: p.mul(U256(limbs: [2, 0, 0, 0]), p.mul(a.y, a.z)))
    }

    private static func add(_ a: Jacobian, _ b: Jacobian) -> Jacobian {
        if a.z.isZero { return b }
        if b.z.isZero { return a }
        let aZ2 = p.mul(a.z, a.z), bZ2 = p.mul(b.z, b.z)
        let u1 = p.mul(a.x, bZ2), u2 = p.mul(b.x, aZ2)
        let s1 = p.mul(a.y, p.mul(bZ2, b.z)), s2 = p.mul(b.y, p.mul(aZ2, a.z))
        if u1 == u2 { return s1 == s2 ? double(a) : .infinity }
        let h = p.sub(u2, u1), r = p.sub(s2, s1)
        let h2 = p.mul(h, h), h3 = p.mul(h2, h), u1h2 = p.mul(u1, h2)
        let x = p.sub(p.sub(p.mul(r, r), h3), p.add(u1h2, u1h2))
        let y = p.sub(p.mul(r, p.sub(u1h2, x)), p.mul(s1, h3))
        return Jacobian(x: x, y: y, z: p.mul(h, p.mul(a.z, b.z)))
    }

    private static func affine(_ a: Jacobian) -> Point? {
        if a.z.isZero { return nil }
        let inverse = p.inverse(a.z), inverse2 = p.mul(inverse, inverse)
        return Point(x: p.mul(a.x, inverse2), y: p.mul(a.y, p.mul(inverse2, inverse)))
    }

    /// u1 * G + u2 * Q, sharing one doubling chain.
    private static func combination(_ u1: U256, _ u2: U256, _ q: Point) -> Point? {
        let g = Jacobian(generator), other = Jacobian(q)
        var result = Jacobian.infinity
        for index in (0..<256).reversed() {
            result = double(result)
            if u1.bit(index) { result = add(result, g) }
            if u2.bit(index) { result = add(result, other) }
        }
        return affine(result)
    }

    static func publicPoint(privateKey: U256) -> Point {
        combination(privateKey, .zero, generator)!
    }

    /// Accepts 33- or 65-byte SEC1 encodings.
    static func decodePoint(_ encoded: Data) -> Point? {
        let bytes = Array(encoded)
        switch (bytes.first, bytes.count) {
        case (0x04, 65):
            let point = Point(x: U256(bytes: bytes[1..<33]), y: U256(bytes: bytes[33..<65]))
            return isOnCurve(point) ? point : nil
        case (0x02, 33), (0x03, 33):
            let x = U256(bytes: bytes[1..<33])
            let ySquared = p.add(p.mul(x, p.mul(x, x)), U256(limbs: [7, 0, 0, 0]))
            // p = 3 mod 4, so a square root is y^((p + 1) / 4).
            let exponent = U256(hex: "3FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFBFFFFF0C")
            var y = p.pow(ySquared, exponent)
            guard p.mul(y, y) == ySquared else { return nil }
            if y.isOdd != (bytes[0] == 0x03) { y = p.sub(.zero, y) }
            return Point(x: x, y: y)
        default:
            return nil
        }
    }

    static func isOnCurve(_ point: Point) -> Bool {
        p.mul(point.y, point.y) == p.add(p.mul(point.x, p.mul(point.x, point.x)), U256(limbs: [7, 0, 0, 0]))
    }

    static func verify(r: U256, s: U256, digest: Data, publicKey: Data) -> Bool {
        guard let q = decodePoint(publicKey), !r.isZero, !s.isZero, r < n.m, s < n.m else { return false }
        let z = n.reduce(U256(bytes: digest))
        let w = n.inverse(s)
        guard let point = combination(n.mul(z, w), n.mul(r, w), q) else { return false }
        return n.reduce(point.x) == r
    }

    /// RFC 6979 section 3.2 with HMAC-SHA-256, for a 256-bit curve order.
    static func nonce(privateKey: U256, digest: Data) -> U256 {
        let x = privateKey.bytes
        let h = n.reduce(U256(bytes: digest)).bytes
        func hmac(_ key: [UInt8], _ parts: [UInt8]...) -> [UInt8] {
            var mac = HMAC<SHA256>(key: SymmetricKey(data: key))
            parts.forEach { mac.update(data: $0) }
            return Array(mac.finalize())
        }
        var v = [UInt8](repeating: 0x01, count: 32)
        var k = [UInt8](repeating: 0x00, count: 32)
        k = hmac(k, v, [0x00], x, h)
        v = hmac(k, v)
        k = hmac(k, v, [0x01], x, h)
        v = hmac(k, v)
        while true {
            v = hmac(k, v)
            let candidate = U256(bytes: v)
            if !candidate.isZero, candidate < n.m { return candidate }
            k = hmac(k, v, [0x00])
            v = hmac(k, v)
        }
    }

    /// RFC 6979 nonce, low-S, with the matching recovery id.
    static func sign(privateKey: U256, digest: Data) -> (r: U256, s: U256, recoveryID: UInt8) {
        let k = nonce(privateKey: privateKey, digest: digest)
        let point = publicPoint(privateKey: k)
        let r = n.reduce(point.x)
        let z = n.reduce(U256(bytes: digest))
        var s = n.mul(n.inverse(k), n.add(z, n.mul(r, privateKey)))
        var recoveryID: UInt8 = (point.y.isOdd ? 1 : 0) | (point.x >= n.m ? 2 : 0)
        if s > halfN {
            s = n.sub(.zero, s)
            recoveryID ^= 1
        }
        return (r, s, recoveryID)
    }

    /// Strict parse of a DER ECDSA signature of the shape signers produce.
    static func parseDER(_ der: Data) -> (r: U256, s: U256)? {
        let bytes = Array(der)
        guard bytes.count >= 8, bytes[0] == 0x30, Int(bytes[1]) == bytes.count - 2 else { return nil }
        var offset = 2
        func integer() -> U256? {
            guard offset + 2 <= bytes.count, bytes[offset] == 0x02 else { return nil }
            let length = Int(bytes[offset + 1])
            offset += 2
            guard length > 0, offset + length <= bytes.count, bytes[offset] & 0x80 == 0 else { return nil }
            var value = Array(bytes[offset..<(offset + length)])
            offset += length
            if value.count > 1, value[0] == 0, value[1] & 0x80 == 0 { return nil }
            if value.count == 33, value[0] == 0 { value.removeFirst() }
            guard value.count <= 32 else { return nil }
            return U256(bytes: [UInt8](repeating: 0, count: 32 - value.count) + value)
        }
        guard let r = integer(), let s = integer(), offset == bytes.count else { return nil }
        return (r, s)
    }
}

extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
