import Foundation
import Testing

private let serial = "6F9619FF-8B86-D011-B42D-00C04FC964FF"

private func request(
    serial: String = serial,
    kind: String = "normal",
    title: String = "Office Wi-Fi",
    details: String = "Normal",
    qr: String? = nil
) -> [String: Any] {
    var body: [String: Any] = ["serial": serial, "kind": kind, "title": title, "details": details]
    body["qr"] = qr
    return body
}

private func issuePass(_ server: RunningServer, _ body: [String: Any]) async throws -> PassBundle {
    let reply = try await server.postPass(body)
    try #require(reply.status == 200, "Got \(reply.status): \(String(decoding: reply.body, as: UTF8.self))")
    return try PassBundle(reply.body, in: server.sandbox)
}

@Suite("HTTP surface")
struct HTTPTests {
    @Test func healthzNeedsNoToken() async throws {
        try await withServer { server in
            let reply = try await server.get("healthz")
            #expect(reply.status == 200)
        }
    }

    @Test func rejectsBadCredentialsWith401() async throws {
        try await withServer { server in
            let body = try JSONSerialization.data(withJSONObject: request())
            let token = server.sandbox.token
            let attempts: [String?] = [
                nil, "", "Bearer", "Bearer ", "Bearer wrong", "Bearer \(token)x", "Bearer \(token.dropLast())",
                "Basic \(token)", token,
            ]
            for authorization in attempts {
                let reply = try await server.postPass(body, authorization: authorization)
                #expect(reply.status == 401, "Authorization: \(authorization ?? "<none>")")
                #expect(reply.wwwAuthenticate == "Bearer")
                #expect(reply.contentType != "application/vnd.apple.pkpass")
            }
            let accepted = try await server.postPass(body, authorization: "Bearer \(token)")
            #expect(accepted.status == 200)
        }
    }

    @Test func checksTokenBeforeReadingBody() async throws {
        try await withServer { server in
            let reply = try await server.postPass(Data("not json".utf8), authorization: "Bearer wrong")
            #expect(reply.status == 401)
        }
    }

    @Test func rejectsInvalidRequestsWith400() async throws {
        try await withServer { server in
            let invalid: [(String, [String: Any])] = [
                ("serial not a UUID", request(serial: "not-a-uuid")),
                ("serial empty", request(serial: "")),
                ("serial with markup", request(serial: "'><a href='https://evil.example'>x")),
                ("serial too short", request(serial: String(serial.dropLast()))),
                ("title empty", request(title: "")),
                ("title blank", request(title: "   \n")),
                ("title 65 characters", request(title: String(repeating: "a", count: 65))),
                ("details 129 characters", request(details: String(repeating: "a", count: 129))),
                ("qr empty", request(qr: "")),
                ("qr 1025 bytes", request(qr: String(repeating: "a", count: 1025))),
                ("qr over limit in multibyte text", request(qr: String(repeating: "é", count: 513))),
                ("unknown kind", request(kind: "admin")),
                ("missing title", ["serial": serial, "kind": "normal", "details": "Normal"]),
                ("missing serial", ["kind": "normal", "title": "x", "details": "Normal"]),
                ("title wrong type", ["serial": serial, "kind": "normal", "title": 7, "details": "Normal"]),
            ]
            for (name, body) in invalid {
                let reply = try await server.postPass(body)
                #expect(reply.status == 400, "\(name)")
            }

            let malformed = try await server.postPass(Data("{".utf8), authorization: "Bearer \(server.sandbox.token)")
            #expect(malformed.status == 400)
            let empty = try await server.postPass(Data(), authorization: "Bearer \(server.sandbox.token)")
            #expect(empty.status == 400)
        }
    }

    @Test func acceptsValuesAtTheLimits() async throws {
        try await withServer { server in
            let reply = try await server.postPass(request(
                serial: serial.lowercased(),
                title: String(repeating: "a", count: 64),
                details: String(repeating: "a", count: 128),
                qr: String(repeating: "a", count: 1024)
            ))
            #expect(reply.status == 200)
        }
    }

    @Test func refusesOversizedBodies() async throws {
        try await withServer { server in
            let reply = try await server.postPass(request(qr: String(repeating: "a", count: 40_000)))
            #expect(reply.status == 413)
        }
    }

    @Test func errorsDoNotEchoInput() async throws {
        try await withServer { server in
            let marker = "ECHO-MARKER-\(UUID().uuidString)"
            let reply = try await server.postPass(request(serial: marker))
            #expect(reply.status == 400)
            #expect(!String(decoding: reply.body, as: UTF8.self).contains(marker))
        }
    }

    @Test func unwritableWorkDirectoryGivesAPlain500() async throws {
        try await withServer { server in
            let path = server.sandbox.serverTemp.path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }

            let reply = try await server.postPass(request())
            #expect(reply.status == 500)
            let body = String(decoding: reply.body, as: UTF8.self)
            #expect(body.contains("Could not sign the pass"))
            #expect(!body.contains(path))
        }
    }

    @Test func handlesConcurrentRequestsAndCleansUp() async throws {
        try await withServer { server in
            let serials = (0..<12).map { _ in UUID().uuidString }
            try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for serial in serials {
                    group.addTask {
                        let reply = try await server.postPass(request(serial: serial))
                        try #require(reply.status == 200)
                        return (serial, reply.body)
                    }
                }
                for try await (serial, data) in group {
                    let bundle = try PassBundle(data, in: server.sandbox)
                    #expect(try bundle.pass["serialNumber"] as? String == serial)
                }
            }
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: server.sandbox.serverTemp.path)
            #expect(leftovers.isEmpty, "Temp files left behind: \(leftovers)")
        }
    }
}

@Suite("Pass contents")
struct PassContentTests {
    @Test func buildsPassPerPlan() async throws {
        try await withServer { server in
            let reply = try await server.postPass(request())
            #expect(reply.status == 200)
            #expect(reply.contentType == "application/vnd.apple.pkpass")

            let bundle = try PassBundle(reply.body, in: server.sandbox)
            for name in ["pass.json", "manifest.json", "signature", "icon.png", "icon@2x.png", "logo.png"] {
                #expect(bundle.files[name] != nil, "\(name) is missing")
            }

            let pass = try bundle.pass
            #expect(pass["formatVersion"] as? Int == 1)
            #expect(pass["passTypeIdentifier"] as? String == "pass.dev.scalexy.rapidwallet.tag")
            #expect(pass["teamIdentifier"] as? String == "B2AA43A5CZ")
            #expect(pass["organizationName"] as? String == "ScaleXY")
            #expect(pass["serialNumber"] as? String == serial)
            #expect(pass["sharingProhibited"] as? Bool == true)
            #expect(pass["description"] as? String == "Rapid Wallet tag")
            #expect(pass["associatedStoreIdentifiers"] == nil)
            #expect(pass["appLaunchURL"] == nil)
            #expect(pass["webServiceURL"] == nil)
            #expect(pass["authenticationToken"] == nil)
            #expect(pass["nfc"] == nil)

            let primary = try bundle.fields("primaryFields")
            #expect(primary.count == 1)
            #expect(primary[0]["value"] as? String == "Office Wi-Fi")
            let secondary = try bundle.fields("secondaryFields")
            #expect(secondary.count == 1)
            #expect(secondary[0]["value"] as? String == "Normal")

            let back = try bundle.fields("backFields")
            #expect(back.contains { ($0["value"] as? String)?.contains("near a reader won't work") == true })
            #expect(back.contains {
                $0["attributedValue"] as? String == "<a href='rapidwallet://tag/\(serial)'>Open in Rapid Wallet</a>"
            })
            #expect(back.allSatisfy { $0["textAlignment"] == nil })
        }
    }

    @Test func imagesAreValidPNGsOfTheRightSize() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request())
            func size(_ name: String) throws -> (width: Int, height: Int) {
                let data = try #require(bundle.files[name])
                return try #require(pngSize(data))
            }
            #expect(try size("icon.png") == (38, 38))
            #expect(try size("icon@2x.png") == (76, 76))
            let logo = try size("logo.png")
            #expect(logo.width <= 160 && logo.height <= 50)
        }
    }

    @Test func signerPassCarriesDetailsAndKeyNotice() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request(kind: "signer", title: "Login", details: "ab12cd34"))
            let secondary = try bundle.fields("secondaryFields")
            #expect(secondary.map { $0["value"] as? String } == ["Signer", "ab12cd34"])
            let back = try bundle.fields("backFields")
            #expect(back.contains { $0["value"] as? String == "The key stays on the iPhone that created it." })
        }
    }

    @Test func includesQROnlyWhenRequested() async throws {
        try await withServer { server in
            let qr = "https://example.com/ünï?a=1&b=2"
            let with = try await issuePass(server, request(qr: qr))
            let barcodes = try #require(try with.pass["barcodes"] as? [[String: Any]])
            #expect(barcodes.count == 1)
            #expect(barcodes[0]["format"] as? String == "PKBarcodeFormatQR")
            #expect(barcodes[0]["message"] as? String == qr)
            #expect(barcodes[0]["messageEncoding"] as? String == "utf-8")

            let without = try await issuePass(server, request())
            #expect(try without.pass["barcodes"] == nil)
            #expect(try without.pass["barcode"] == nil)
        }
    }

    @Test func reissuingKeepsTheSerial() async throws {
        try await withServer { server in
            let first = try await issuePass(server, request(title: "Before"))
            let second = try await issuePass(server, request(title: "After"))
            #expect(try first.pass["serialNumber"] as? String == second.pass["serialNumber"] as? String)
            #expect(try second.fields("primaryFields")[0]["value"] as? String == "After")
        }
    }
}

@Suite("Signature")
struct SignatureTests {
    @Test func manifestHashesEveryFile() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request(qr: "hello"))
            let manifest = try #require(try bundle.json("manifest.json") as? [String: String])
            let hashed = bundle.files.filter { $0.key != "manifest.json" && $0.key != "signature" }

            #expect(Set(manifest.keys) == Set(hashed.keys))
            for (name, data) in hashed {
                #expect(manifest[name] == sha1Hex(data), "\(name)")
            }
        }
    }

    private func verify(_ bundle: PassBundle, content: URL, caFile: URL) throws -> CommandResult {
        try openssl([
            "cms", "-verify", "-binary", "-inform", "DER",
            "-in", bundle.directory.appending(path: "signature").path,
            "-content", content.path,
            "-CAfile", caFile.path,
            "-purpose", "any",
            "-out", "/dev/null",
        ])
    }

    @Test func opensslVerifiesTheDetachedSignature() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request())
            let result = try verify(
                bundle,
                content: bundle.directory.appending(path: "manifest.json"),
                caFile: server.sandbox.wwdr
            )
            #expect(result.status == 0, "\(result.stderr)")
            #expect(result.stderr.contains("Verification successful"))
        }
    }

    @Test func opensslRejectsATamperedManifest() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request())
            var tampered = try #require(bundle.files["manifest.json"])
            tampered[tampered.startIndex + 2] ^= 0x01
            let tamperedURL = bundle.directory.appending(path: "tampered.json")
            try tampered.write(to: tamperedURL)

            let result = try verify(bundle, content: tamperedURL, caFile: server.sandbox.wwdr)
            #expect(result.status != 0)
        }
    }

    @Test func opensslRejectsAnUnrelatedChain() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request())
            let other = try Sandbox()
            let result = try verify(
                bundle,
                content: bundle.directory.appending(path: "manifest.json"),
                caFile: other.wwdr
            )
            #expect(result.status != 0)
        }
    }

    @Test func signatureIsDetachedWithChainAndSigningTime() async throws {
        try await withServer { server in
            let bundle = try await issuePass(server, request())
            let printed = try openssl([
                "cms", "-cmsout", "-print", "-inform", "DER",
                "-in", bundle.directory.appending(path: "signature").path,
            ])
            #expect(printed.status == 0)
            #expect(printed.stdout.contains("eContent: <ABSENT>"))
            #expect(printed.stdout.contains("signingTime"))

            let certificates = try openssl([
                "pkcs7", "-inform", "DER", "-print_certs", "-noout",
                "-in", bundle.directory.appending(path: "signature").path,
            ])
            #expect(certificates.stdout.contains("Pass Type ID: pass.dev.scalexy.rapidwallet.tag"))
            #expect(certificates.stdout.contains("TEST ONLY fake WWDR"))
        }
    }
}

@Suite("Secrets")
struct SecretTests {
    @Test func passHoldsNothingSecretAndLogsStayClean() async throws {
        try await withServer { server in
            let title = "TITLE-MARKER-\(UUID().uuidString)"
            let details = "DETAILS-MARKER-\(UUID().uuidString)"
            let qr = "QR-MARKER-\(UUID().uuidString)"
            let stray = "STRAY-MARKER-\(UUID().uuidString)"
            let requestSerial = UUID().uuidString

            var body = request(serial: requestSerial, title: title, details: details, qr: qr)
            body["privateKey"] = stray
            body["seedPhrase"] = stray
            let bundle = try await issuePass(server, body)

            let expected: Set = [
                "pass.json", "manifest.json", "signature", "tooling.json", "icon.png", "icon@2x.png", "logo.png",
            ]
            #expect(Set(bundle.files.keys) == expected)

            let key = try String(contentsOf: server.sandbox.privateKey, encoding: .utf8)
            let keyLines = key.split(separator: "\n").filter { !$0.hasPrefix("-----") }.map(String.init)
            #expect(keyLines.count > 5)
            let forbidden = [server.sandbox.token, stray, "PRIVATE KEY", "privateKey", "seedPhrase"] + keyLines
            for (name, data) in bundle.files {
                for secret in forbidden {
                    #expect(data.range(of: Data(secret.utf8)) == nil, "\(name) contains secret-like text")
                }
            }

            let invalid = try await server.postPass(request(title: String(repeating: stray, count: 4)))
            #expect(invalid.status == 400)

            let log = server.log
            #expect(log.contains("/v1/passes"), "The request should be logged")
            for value in [server.sandbox.token, title, details, qr, stray, requestSerial] {
                #expect(!log.contains(value), "Log contains a request value")
            }
            #expect(!log.contains("PRIVATE KEY"))
        }
    }
}

@Suite("Startup")
struct StartupTests {
    /// Refusals must exit 1. A crash also exits non-zero, but with a signal number.
    private func start(_ environment: [String: String]) throws -> CommandResult {
        try runCommand(Paths.serverBinary, [], environment: environment, timeout: 15)
    }

    @Test(arguments: ["PASS_CERT_PEM", "PASS_KEY_PEM", "WWDR_CERT_PEM", "PASS_SERVICE_TOKEN"])
    func refusesToStartWithoutRequiredVariable(_ name: String) throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment[name] = nil
        let missing = try start(environment)
        #expect(missing.status == 1)
        #expect(missing.stderr.contains(name))

        environment[name] = ""
        let empty = try start(environment)
        #expect(empty.status == 1)
        #expect(empty.stderr.contains(name))
    }

    @Test func refusesUnreadableCertificatePath() throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_CERT_PEM"] = "/nonexistent/pass-cert.pem"
        let result = try start(environment)
        #expect(result.status == 1)
        #expect(result.stderr.contains("PASS_CERT_PEM"))
    }

    @Test func refusesKeyThatDoesNotMatchCertificate() throws {
        let sandbox = try Sandbox()
        let other = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_KEY_PEM"] = other.privateKey.path
        let result = try start(environment)
        #expect(result.status == 1)
        #expect(result.stderr.contains("doesn't match"))
    }

    @Test func refusesCertificateForAnotherPassType() throws {
        let sandbox = try Sandbox(passTypeID: "pass.dev.scalexy.other")
        let result = try start(sandbox.serverEnvironment)
        #expect(result.status == 1)
        #expect(result.stderr.contains("pass.dev.scalexy.rapidwallet.tag"))
    }

    @Test func refusesCertificateForAnotherTeam() throws {
        let sandbox = try Sandbox(teamID: "ZZZZZZZZZZ")
        let result = try start(sandbox.serverEnvironment)
        #expect(result.status == 1)
        #expect(result.stderr.contains("B2AA43A5CZ"))
    }

    @Test func refusesAnInvalidPort() throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_SERVICE_PORT"] = "not-a-port"
        let result = try start(environment)
        #expect(result.status == 1)
    }

    @Test func refusesKeyThatIsNotPEM() throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_KEY_PEM"] = sandbox.certificate.path
        let result = try start(environment)
        #expect(result.status == 1)
        #expect(result.stderr.contains("PASS_KEY_PEM"))
    }

    @Test func acceptsTraditionalRSAKeyFormat() async throws {
        let sandbox = try Sandbox()
        let traditional = sandbox.root.appending(path: "traditional-key.pem")
        let converted = try openssl([
            "rsa", "-traditional", "-in", sandbox.privateKey.path, "-out", traditional.path,
        ])
        try #require(converted.status == 0, "\(converted.stderr)")
        #expect(try String(contentsOf: traditional, encoding: .utf8).contains("BEGIN RSA PRIVATE KEY"))

        var environment = sandbox.serverEnvironment
        environment["PASS_KEY_PEM"] = traditional.path
        let server = try RunningServer(sandbox: sandbox, environment: environment)
        defer { server.stop() }
        let reply = try await server.postPass(request())
        #expect(reply.status == 200)
    }

    @Test func acceptsInlinePEM() async throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_CERT_PEM"] = try String(contentsOf: sandbox.certificate, encoding: .utf8)
        environment["PASS_KEY_PEM"] = try String(contentsOf: sandbox.privateKey, encoding: .utf8)
        environment["WWDR_CERT_PEM"] = try String(contentsOf: sandbox.wwdr, encoding: .utf8)
        let server = try RunningServer(sandbox: sandbox, environment: environment)
        defer { server.stop() }
        let reply = try await server.postPass(request())
        #expect(reply.status == 200)
    }

    @Test func refusesUnusableWorkDirectory() throws {
        let sandbox = try Sandbox()
        var environment = sandbox.serverEnvironment
        environment["PASS_SERVICE_TMPDIR"] = "/dev/null/rapid-pass"
        let result = try start(environment)
        #expect(result.status == 1)
    }

    @Test func deletesTemporaryP12AfterStartup() async throws {
        try await withServer { server in
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: server.sandbox.serverTemp.path)
            #expect(leftovers.isEmpty, "Temp files left behind: \(leftovers)")
        }
    }
}
