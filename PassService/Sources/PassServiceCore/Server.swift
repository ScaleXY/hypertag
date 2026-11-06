import Foundation
import HTTPTypes
import Hummingbird
import Logging

extension HTTPField.Name {
    fileprivate static let wwwAuthenticate = HTTPField.Name("WWW-Authenticate")!
}

/// Dev-build stand-in for App Attest, agreed with the lead.
struct BearerTokenMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: [UInt8]

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let presented = Self.bearerToken(in: request), Self.matches(presented, token) else {
            throw HTTPError(
                .unauthorized,
                headers: [.wwwAuthenticate: "Bearer"],
                message: "A valid bearer token is required"
            )
        }
        return try await next(request, context)
    }

    private static func bearerToken(in request: Request) -> [UInt8]? {
        guard let header = request.headers[.authorization] else { return nil }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return Array(parts[1].utf8)
    }

    private static func matches(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private let maximumBodyBytes = 16 * 1024

/// Logs carry the method, path and status only. Request bodies and headers stay out of them.
public func buildApplication(
    configuration: ServiceConfiguration,
    issuer: PassIssuer,
    logger: Logger
) -> some ApplicationProtocol {
    let router = Router()
    router.add(middleware: LogRequestsMiddleware(.info))

    router.get("healthz") { _, _ in "ok" }

    router.group("v1/passes")
        .add(middleware: BearerTokenMiddleware(token: Array(configuration.token.utf8)))
        .post { request, context -> Response in
            var request = request
            let body = try await request.collectBody(upTo: maximumBodyBytes)

            let passRequest: PassRequest
            do {
                passRequest = try JSONDecoder().decode(PassRequest.self, from: Data(body.readableBytesView))
                try passRequest.validate()
            } catch let error as PassRequestError {
                throw HTTPError(.badRequest, message: error.description)
            } catch {
                throw HTTPError(.badRequest, message: "Body must be a JSON pass request")
            }

            let pass: Data
            do {
                pass = try await issuer.issue(passRequest)
            } catch {
                context.logger.error("Signing failed: \(type(of: error))")
                throw HTTPError(.internalServerError, message: "Could not sign the pass")
            }

            return Response(
                status: .ok,
                headers: [.contentType: "application/vnd.apple.pkpass"],
                body: ResponseBody(byteBuffer: ByteBuffer(bytes: pass))
            )
        }

    return Application(
        router: router,
        configuration: .init(address: .hostname(configuration.host, port: configuration.port)),
        onServerRunning: { channel in
            let port = channel.localAddress?.port ?? configuration.port
            logger.info("pass-service listening on \(configuration.host):\(port)")
        },
        logger: logger
    )
}
