import Foundation

/// The SQLite store and its sidecars on disk.
struct StoreFiles: Sendable {
    let url: URL

    var paths: [URL] {
        let directory = url.deletingLastPathComponent()
        return ["", "-wal", "-shm"].map { directory.appendingPathComponent(url.lastPathComponent + $0) }
    }

    static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("RapidWallet", isDirectory: true)
            .appendingPathComponent("tags.store")
    }

    /// The directory gets the class too, for files created between `protect()` calls.
    func prepareDirectory() throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }

    /// SQLite can recreate its sidecars, so this runs after open and after every write.
    func protect() throws {
        #if os(iOS)
        let manager = FileManager.default
        for path in paths.map(\.path) where manager.fileExists(atPath: path) {
            try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: path)
        }
        #endif
    }
}
