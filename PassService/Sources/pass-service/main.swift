import Foundation
import Hummingbird
import Logging
import PassServiceCore

var logger = Logger(label: "pass-service")
logger.logLevel = .info

let configuration: ServiceConfiguration
let issuer: PassIssuer
do {
    configuration = try ServiceConfiguration(environment: ProcessInfo.processInfo.environment)
    issuer = try PassIssuer(configuration: configuration)
} catch {
    FileHandle.standardError.write(Data("pass-service: \(error)\n".utf8))
    exit(1)
}

logger.info("Signing certificate expires \(issuer.certificateExpiry.formatted(.iso8601))")
try await buildApplication(configuration: configuration, issuer: issuer, logger: logger).runService()
