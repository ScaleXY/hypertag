import Foundation
import Synchronization

/// Serves canned responses without a network. Each `StubServer` gets its own host,
/// so tests stay isolated while Swift Testing runs them in parallel.
final class StubURLProtocol: URLProtocol {
    fileprivate static let servers = Mutex<[String: StubServer]>([:])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let server = Self.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        // URLSession moves the body into a stream before it reaches a URLProtocol.
        var received = request
        received.httpBody = request.httpBodyStream.map(Self.drain) ?? request.httpBody
        server.record(received)

        switch server.reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    private static func drain(_ stream: InputStream) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        stream.open()
        defer { stream.close() }
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { return data }
            data.append(contentsOf: buffer[..<count])
        }
    }
}

final class StubServer: Sendable {
    enum Reply: Sendable {
        case response(status: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    let host = "\(UUID().uuidString.lowercased()).example.test"
    let reply: Reply
    let session: URLSession
    private let received = Mutex<[URLRequest]>([])

    init(_ reply: Reply) {
        self.reply = reply
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.servers.withLock { $0[host] = self }
    }

    var requests: [URLRequest] { received.withLock { $0 } }

    fileprivate func record(_ request: URLRequest) {
        received.withLock { $0.append(request) }
    }
}
