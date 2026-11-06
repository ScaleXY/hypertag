import Foundation
import NIOSSL
import PassBuilder
import X509

public enum PassIssuerError: Error, CustomStringConvertible {
    case invalidCredentials(String)

    public var description: String {
        switch self {
        case .invalidCredentials(let reason): "Invalid signing credentials: \(reason)"
        }
    }
}

/// Signs passes with Pass Builder.
///
/// Unchecked because `PassSigner` isn't marked `Sendable`. It's immutable here, and each call works in its own
/// temporary directory.
public final class PassIssuer: @unchecked Sendable {
    private let signer: PassSigner
    private let workDirectory: URL
    public let certificateExpiry: Date

    public init(configuration: ServiceConfiguration) throws {
        workDirectory = configuration.workDirectory
        let credentials = try Self.loadCredentials(configuration)
        certificateExpiry = credentials.pass.certificate.notValidAfter
        signer = PassSigner(passCertificate: credentials.pass, wwdrCertificate: credentials.wwdr)

        var identity = Pass()
        identity.passTypeIdentifier = PassIdentity.passTypeIdentifier
        identity.teamIdentifier = PassIdentity.teamIdentifier
        do {
            try credentials.pass.attributes.validateAttributes(for: identity)
        } catch {
            throw PassIssuerError.invalidCredentials(
                "PASS_CERT_PEM isn't for \(PassIdentity.passTypeIdentifier), team \(PassIdentity.teamIdentifier)"
            )
        }
    }

    public func issue(_ request: PassRequest) async throws -> Data {
        let directory = try Self.makePrivateDirectory(in: workDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appending(path: "pass.pkpass")
        let output = try await signer.signPass(request.makePackage(), destination: destination)
        return try Data(contentsOf: output)
    }

    private static func loadCredentials(
        _ configuration: ServiceConfiguration
    ) throws -> (pass: PassCertificate, wwdr: PassCertificate) {
        let chain: [NIOSSLCertificate]
        let key: NIOSSLPrivateKey
        let wwdrDER: [UInt8]
        do {
            chain = try NIOSSLCertificate.fromPEMBytes(configuration.certificatePEM)
        } catch {
            throw PassIssuerError.invalidCredentials("PASS_CERT_PEM isn't a PEM certificate")
        }
        do {
            key = try NIOSSLPrivateKey(bytes: configuration.privateKeyPEM, format: .pem)
        } catch {
            throw PassIssuerError.invalidCredentials("PASS_KEY_PEM isn't an unencrypted PEM private key")
        }
        do {
            wwdrDER = try NIOSSLCertificate(bytes: configuration.wwdrCertificatePEM, format: .pem).toDERBytes()
        } catch {
            throw PassIssuerError.invalidCredentials("WWDR_CERT_PEM isn't a PEM certificate")
        }
        guard let leaf = chain.first else {
            throw PassIssuerError.invalidCredentials("PASS_CERT_PEM holds no certificate")
        }

        // Checked here because NIOSSL's serialize(passphrase:) crashes on a mismatched key rather than throwing.
        guard try keyMatches(configuration.privateKeyPEM, certificate: leaf) else {
            throw PassIssuerError.invalidCredentials("PASS_KEY_PEM doesn't match PASS_CERT_PEM")
        }

        // Pass Builder only loads a signing identity from a .p12 file, so one exists briefly under a random password.
        let directory = try makePrivateDirectory(in: configuration.workDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let password = UUID().uuidString + UUID().uuidString
        let p12 = try NIOSSLPKCS12Bundle(certificateChain: [leaf], privateKey: key)
            .serialize(passphrase: Array(password.utf8))
        let p12URL = directory.appending(path: "pass.p12")
        let wwdrURL = directory.appending(path: "wwdr.cer")
        try writePrivateFile(p12, to: p12URL)
        try writePrivateFile(wwdrDER, to: wwdrURL)

        return (
            try PassCertificate(url: p12URL, password: password),
            try PassCertificate(url: wwdrURL)
        )
    }

    private static func keyMatches(_ keyPEM: [UInt8], certificate: NIOSSLCertificate) throws -> Bool {
        let parsedCertificate = try Certificate(derEncoded: certificate.toDERBytes())
        let parsedKey = try Certificate.PrivateKey(pemEncoded: String(decoding: keyPEM, as: UTF8.self))
        return parsedKey.publicKey == parsedCertificate.publicKey
    }

    private static func makePrivateDirectory(in parent: URL) throws -> URL {
        let directory = parent.appending(path: "rapid-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func writePrivateFile(_ bytes: [UInt8], to url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(bytes),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
