import CryptoKit
import Foundation
import Testing

private final class BundleMarker {}

enum Paths {
    static let packageRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let certScript = packageRoot.appending(path: "scripts/make-test-cert.sh")
    static let serverBinary = Bundle(for: BundleMarker.self).bundleURL
        .deletingLastPathComponent().appending(path: "pass-service")
}

struct HarnessError: Error, CustomStringConvertible {
    var description: String
}

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Runs a command to completion. Output goes through files so a full pipe can't stall it.
@discardableResult
func runCommand(
    _ executable: URL,
    _ arguments: [String],
    environment: [String: String]? = nil,
    timeout: TimeInterval = 30
) throws -> CommandResult {
    let scratch = FileManager.default.temporaryDirectory.appending(path: "rw-cmd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let stdoutURL = scratch.appending(path: "out")
    let stderrURL = scratch.appending(path: "err")
    FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
    FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardOutput = try FileHandle(forWritingTo: stdoutURL)
    process.standardError = try FileHandle(forWritingTo: stderrURL)
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(20_000) }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
        // waitUntilExit() can miss the exit notification off the main thread and block forever.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
    }
    let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
    if timedOut { throw HarnessError(description: "Timed out: \(executable.lastPathComponent)\n\(stdout)\n\(stderr)") }
    return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

func openssl(_ arguments: [String]) throws -> CommandResult {
    try runCommand(URL(filePath: "/usr/bin/env"), ["openssl"] + arguments)
}

/// A private temp directory holding throwaway credentials, made by scripts/make-test-cert.sh.
final class Sandbox: Sendable {
    let root: URL
    let certificate: URL
    let privateKey: URL
    let wwdr: URL
    let serverTemp: URL
    let token = "test-token-\(UUID().uuidString)"

    init(passTypeID: String? = nil, teamID: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "rw-pass-tests-\(UUID().uuidString)")
        serverTemp = root.appending(path: "server-tmp")
        try FileManager.default.createDirectory(at: serverTemp, withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = root.path
        environment["TEST_PASS_TYPE_ID"] = passTypeID
        environment["TEST_TEAM_ID"] = teamID
        let result = try runCommand(Paths.certScript, [], environment: environment)
        guard result.status == 0 else { throw HarnessError(description: "make-test-cert: \(result.stderr)") }

        func path(_ name: String) throws -> URL {
            let prefix = "export \(name)='"
            guard let line = result.stdout.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
                throw HarnessError(description: "make-test-cert printed no \(name)")
            }
            return URL(filePath: String(line.dropFirst(prefix.count).dropLast()))
        }
        certificate = try path("PASS_CERT_PEM")
        privateKey = try path("PASS_KEY_PEM")
        wwdr = try path("WWDR_CERT_PEM")
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var serverEnvironment: [String: String] {
        [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "PASS_SERVICE_TMPDIR": serverTemp.path,
            "PASS_CERT_PEM": certificate.path,
            "PASS_KEY_PEM": privateKey.path,
            "WWDR_CERT_PEM": wwdr.path,
            "PASS_SERVICE_TOKEN": token,
            "PASS_SERVICE_PORT": "0",
        ]
    }
}

/// The real `pass-service` binary on a random port.
final class RunningServer: @unchecked Sendable {
    let sandbox: Sandbox
    let baseURL: URL
    private let process: Process
    private let logURL: URL

    init(sandbox: Sandbox, environment: [String: String]? = nil) throws {
        self.sandbox = sandbox
        logURL = sandbox.root.appending(path: "server-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        process = Process()
        process.executableURL = Paths.serverBinary
        process.environment = environment ?? sandbox.serverEnvironment
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            if let match = text.firstMatch(of: /pass-service listening on [0-9.]+:(\d+)/) {
                baseURL = URL(string: "http://127.0.0.1:\(match.1)")!
                return
            }
            if !process.isRunning { break }
            usleep(20_000)
        }
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        process.terminate()
        throw HarnessError(description: "Server didn't start:\n\(output)")
    }

    func stop() {
        process.terminate()
        // waitUntilExit() can miss the exit notification off the main thread and block forever.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
    }

    var log: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }

    struct Reply {
        var status: Int
        var body: Data
        var contentType: String?
        var wwwAuthenticate: String?
    }

    func get(_ path: String) async throws -> Reply {
        try await send(URLRequest(url: baseURL.appending(path: path)))
    }

    func postPass(_ body: Data, authorization: String?) async throws -> Reply {
        var request = URLRequest(url: baseURL.appending(path: "v1/passes"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    func postPass(_ body: [String: Any]) async throws -> Reply {
        try await postPass(
            JSONSerialization.data(withJSONObject: body),
            authorization: "Bearer \(sandbox.token)"
        )
    }

    private func send(_ request: URLRequest) async throws -> Reply {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        return Reply(
            status: http.statusCode,
            body: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate")
        )
    }
}

func withServer<T>(_ body: (RunningServer) async throws -> T) async throws -> T {
    let server = try RunningServer(sandbox: Sandbox())
    defer { server.stop() }
    return try await body(server)
}

/// An unzipped `.pkpass`.
struct PassBundle {
    let directory: URL
    let files: [String: Data]

    init(_ data: Data, in sandbox: Sandbox) throws {
        directory = sandbox.root.appending(path: "pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathExtension("pkpass")
        try data.write(to: archive)
        let result = try runCommand(URL(filePath: "/usr/bin/unzip"), ["-q", archive.path, "-d", directory.path])
        guard result.status == 0 else { throw HarnessError(description: "unzip: \(result.stderr)") }

        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            files[name] = try Data(contentsOf: directory.appending(path: name))
        }
        self.files = files
    }

    func json(_ name: String) throws -> [String: Any] {
        let data = try #require(files[name], "\(name) is missing")
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var pass: [String: Any] { get throws { try json("pass.json") } }

    func fields(_ group: String) throws -> [[String: Any]] {
        let generic = try #require(pass["generic"] as? [String: Any])
        return try #require(generic[group] as? [[String: Any]])
    }
}

func sha1Hex(_ data: Data) -> String {
    Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func pngSize(_ data: Data) -> (width: Int, height: Int)? {
    guard data.count > 24, data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { return nil }
    func readInt(_ offset: Int) -> Int { data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
    return (readInt(16), readInt(20))
}
