import Foundation

/// Client for `POST /v1/passes`. Every failure surfaces as a `WalletError`.
public struct PassServiceClient: Sendable {
    private static let passContentType = "application/vnd.apple.pkpass"

    private let configuration: PassServiceConfiguration
    private let session: URLSession

    public init(configuration: PassServiceConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func fetchPass(_ request: PassRequest) async throws -> Data {
        let urlRequest = try makeURLRequest(for: request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw WalletError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw WalletError.cancelled
        } catch {
            throw WalletError.serviceUnreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw WalletError.serviceUnreachable("The pass service sent a non-HTTP response.")
        }
        guard http.statusCode == 200 else {
            throw WalletError.serviceRejected(status: http.statusCode)
        }
        guard Self.isPassContentType(http.value(forHTTPHeaderField: "Content-Type")), !data.isEmpty else {
            throw WalletError.invalidPass
        }
        return data
    }

    private func makeURLRequest(for request: PassRequest) throws -> URLRequest {
        let baseURL = configuration.baseURL
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              let scheme = baseURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              baseURL.host()?.isEmpty == false
        else {
            throw WalletError.serviceNotConfigured
        }
        guard let body = try? JSONEncoder().encode(request) else {
            throw WalletError.invalidPass
        }

        var urlRequest = URLRequest(url: baseURL.appending(path: "v1/passes"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(Self.passContentType, forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private static func isPassContentType(_ header: String?) -> Bool {
        guard let mediaType = header?.split(separator: ";", omittingEmptySubsequences: false).first else {
            return false
        }
        return mediaType.trimmingCharacters(in: .whitespaces).lowercased() == passContentType
    }
}
