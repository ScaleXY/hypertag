import Foundation
import Security
import TagEngine

/// Fixed-size secret bytes in their own locked pages. Wiped with `memset_s`.
/// Throws rather than falling back to unlocked memory.
final class SecretBuffer: @unchecked Sendable {
    let count: Int
    private let lock = NSLock()
    private let pages: UnsafeMutableRawPointer
    private let pagesSize: Int
    private var wiped = false

    init(count: Int) throws {
        precondition(count > 0)
        let pageSize = Int(getpagesize())
        let size = (count + pageSize - 1) / pageSize * pageSize
        guard let pages = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), pages != MAP_FAILED else {
            throw VaultError.failed("Could not allocate secure memory")
        }
        guard mlock(pages, size) == 0 else {
            munmap(pages, size)
            throw VaultError.failed("Could not lock secure memory")
        }
        self.count = count
        self.pages = pages
        self.pagesSize = size
    }

    convenience init(copying bytes: UnsafeRawBufferPointer) throws {
        try self.init(count: bytes.count)
        pages.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    }

    static func random(count: Int) throws -> SecretBuffer {
        let buffer = try SecretBuffer(count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, buffer.pages) == errSecSuccess else {
            throw VaultError.failed("Secure random generator failed")
        }
        return buffer
    }

    deinit {
        wipe()
        munlock(pages, pagesSize)
        munmap(pages, pagesSize)
    }

    /// Don't let the bytes escape `body`. Throws `SignerRefusal.locked` after a wipe.
    func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        lock.lock()
        defer { lock.unlock() }
        guard !wiped else { throw SignerRefusal.locked }
        return try body(UnsafeRawBufferPointer(start: pages, count: count))
    }

    func wipe() {
        lock.lock()
        defer { lock.unlock() }
        wiped = true
        memset_s(pages, pagesSize, 0, pagesSize)
    }

    var isWiped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wiped
    }

    /// True when every byte of the backing pages is zero. Lets tests inspect a wiped buffer.
    var isZeroed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return UnsafeRawBufferPointer(start: pages, count: pagesSize).allSatisfy { $0 == 0 }
    }
}
