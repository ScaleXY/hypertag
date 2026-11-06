import Foundation
import Testing
@testable import WalletBridge

@Suite struct PassServiceClientTests {
    private static let pkpass = "application/vnd.apple.pkpass"
    private static let passBytes = Data([0x50, 0x4B, 0x03, 0x04, 0xFF])
    private let passRequest = PassRequest(
        serial: "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
        kind: .signer,
        title: "Office Wi-Fi",
        details: "Normal",
        qr: "https://example.com"
    )

    private func client(for server: StubServer, path: String = "", token: String = "secret") -> PassServiceClient {
        let configuration = PassServiceConfiguration(baseURL: URL(string: "https://\(server.host)\(path)")!, token: token)
        return PassServiceClient(configuration: configuration, session: server.session)
    }

    private func passServer(contentType: String = pkpass, body: Data = passBytes) -> StubServer {
        StubServer(.response(status: 200, headers: ["Content-Type": contentType], body: body))
    }

    /// The thrown error, so the assertion can compare it exactly.
    private func failure(of client: PassServiceClient) async -> Error? {
        do {
            _ = try await client.fetchPass(passRequest)
            return nil
        } catch {
            return error
        }
    }

    @Test func sendsThePlannedRequest() async throws {
        let server = passServer()
        _ = try await client(for: server).fetchPass(passRequest)

        let sent = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://\(server.host)/v1/passes")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.value(forHTTPHeaderField: "Accept") == Self.pkpass)

        let body = try #require(sent.httpBody)
        #expect(try JSONDecoder().decode(PassRequest.self, from: body) == passRequest)

        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "serial": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
            "kind": "signer",
            "title": "Office Wi-Fi",
            "details": "Normal",
            "qr": "https://example.com",
        ])
    }

    @Test func omitsQRWhenAbsent() async throws {
        let server = passServer()
        let request = PassRequest(serial: "s", kind: .normal, title: "t", details: "d")
        _ = try await client(for: server).fetchPass(request)

        let body = try #require(server.requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["qr"] == nil)
        #expect(json["kind"] == "normal")
    }

    @Test(arguments: [("/", "/v1/passes"), ("/api", "/api/v1/passes"), ("/api/", "/api/v1/passes")])
    func joinsBaseURLPaths(base: String, expected: String) async throws {
        let server = passServer()
        _ = try await client(for: server, path: base).fetchPass(passRequest)
        #expect(server.requests.first?.url?.path() == expected)
    }

    @Test func returnsPassBytes() async throws {
        let data = try await client(for: passServer()).fetchPass(passRequest)
        #expect(data == Self.passBytes)
    }

    @Test(arguments: ["application/vnd.apple.pkpass; charset=binary", "Application/VND.Apple.PKPass"])
    func acceptsContentTypeVariants(contentType: String) async throws {
        let data = try await client(for: passServer(contentType: contentType)).fetchPass(passRequest)
        #expect(data == Self.passBytes)
    }

    @Test func unauthorizedIsRejected() async {
        let server = StubServer(.response(status: 401, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
        let error = await failure(of: client(for: server))
        #expect(error as? WalletError == .serviceRejected(status: 401))
    }

    @Test func serverErrorIsRejected() async {
        let server = StubServer(.response(status: 500, headers: [:], body: Data("boom".utf8)))
        let error = await failure(of: client(for: server))
        #expect(error as? WalletError == .serviceRejected(status: 500))
    }

    /// A pkpass body under any status but 200 still doesn't count.
    @Test(arguments: [201, 204, 403, 429, 503])
    func otherStatusesAreRejected(status: Int) async {
        let server = StubServer(.response(status: status, headers: ["Content-Type": Self.pkpass], body: Self.passBytes))
        let error = await failure(of: client(for: server))
        #expect(error as? WalletError == .serviceRejected(status: status))
    }

    @Test(arguments: [URLError.Code.cannotConnectToHost, .notConnectedToInternet, .timedOut, .cannotFindHost])
    func connectionFailuresAreUnreachable(code: URLError.Code) async throws {
        let error = await failure(of: client(for: StubServer(.failure(URLError(code)))))
        guard case .serviceUnreachable(let message) = try #require(error as? WalletError) else {
            Issue.record("Expected serviceUnreachable, got \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func cancellationIsCancelled() async {
        let error = await failure(of: client(for: StubServer(.failure(URLError(.cancelled)))))
        #expect(error as? WalletError == .cancelled)
    }

    @Test func cancellingTheTaskIsCancelled() async {
        let client = client(for: passServer())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await failure(of: client)
        }
        #expect(await task.value as? WalletError == .cancelled)
    }

    @Test(arguments: ["text/html", "application/json", "application/vnd.apple.pkpasses", "application/octet-stream"])
    func wrongContentTypeIsInvalid(contentType: String) async {
        let error = await failure(of: client(for: passServer(contentType: contentType)))
        #expect(error as? WalletError == .invalidPass)
    }

    @Test func missingContentTypeIsInvalid() async {
        let server = StubServer(.response(status: 200, headers: [:], body: Self.passBytes))
        let error = await failure(of: client(for: server))
        #expect(error as? WalletError == .invalidPass)
    }

    @Test func emptyBodyIsInvalid() async {
        let error = await failure(of: client(for: passServer(body: Data())))
        #expect(error as? WalletError == .invalidPass)
    }

    @Test(arguments: ["", "   \n"])
    func blankTokenIsNotConfigured(token: String) async {
        let server = passServer()
        let error = await failure(of: client(for: server, token: token))
        #expect(error as? WalletError == .serviceNotConfigured)
        #expect(server.requests.isEmpty)
    }

    @Test(arguments: ["ftp://example.test", "file:///tmp/passes", "example.test"])
    func unusableBaseURLIsNotConfigured(base: String) async {
        let server = passServer()
        let configuration = PassServiceConfiguration(baseURL: URL(string: base)!, token: "secret")
        let client = PassServiceClient(configuration: configuration, session: server.session)
        let error = await failure(of: client)
        #expect(error as? WalletError == .serviceNotConfigured)
    }
}
