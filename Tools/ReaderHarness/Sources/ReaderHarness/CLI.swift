import Foundation

@main
struct CLI {
    static let usage = """
    Usage:
      ReaderHarness transcript
      ReaderHarness pcsc list
      ReaderHarness pcsc read-ndef [--reader <name>] [--timeout <seconds>]
      ReaderHarness pcsc enroll [--key-file <path>] [--force] [--reader <name>] [--timeout <seconds>]
      ReaderHarness pcsc auth [--key-file <path>] [--reader <name>] [--timeout <seconds>]
      ReaderHarness pcsc sign --digest <hex> [--der] [--label <text>] [--key-file <path>] [--reader <name>] [--timeout <seconds>]

    --key-file defaults to enrolled-tag.json in the current directory.
    --timeout is how long to wait for each tap, and defaults to 60.
    pcsc needs a binary signed with ReaderHarness.entitlements. Sign again after each build.
    """

    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch let error as HarnessError {
            if case .usage = error {
                print("\(error)\n\n\(usage)")
            } else {
                print("Error: \(error)")
            }
            exit(1)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        switch arguments.first {
        case "transcript":
            let report = await Transcript.run()
            if report.failed > 0 { exit(1) }
        case "pcsc":
            try await runPCSC(Array(arguments.dropFirst()))
        default:
            throw HarnessError.usage("Choose a subcommand.")
        }
    }

    static func runPCSC(_ arguments: [String]) async throws {
        guard let subcommand = arguments.first else { throw HarnessError.usage("Choose a pcsc subcommand.") }
        var options = Options(Array(arguments.dropFirst()))
        var command = PCSCCommand()
        command.readerName = try options.value("--reader")
        if let path = try options.value("--key-file") { command.keyFile = path }
        if let seconds = try options.value("--timeout") {
            guard let value = Int(seconds), value > 0 else { throw HarnessError.usage("--timeout takes whole seconds") }
            command.timeout = .seconds(value)
        }
        switch subcommand {
        case "list":
            try options.finish()
            try await command.list()
        case "read-ndef":
            try options.finish()
            try await command.readNDEF()
        case "enroll":
            let force = options.flag("--force")
            try options.finish()
            try await command.enroll(force: force)
        case "auth":
            try options.finish()
            try await command.authenticate()
        case "sign":
            let der = options.flag("--der")
            let label = try options.value("--label")
            guard let hex = try options.value("--digest"), let digest = Data(hex: hex), digest.count == 32 else {
                throw HarnessError.usage("sign needs --digest with 32 bytes of hex")
            }
            guard (label?.utf8.count ?? 0) <= 64 else { throw HarnessError.usage("--label can be at most 64 UTF-8 bytes") }
            try options.finish()
            try await command.sign(digest: digest, der: der, label: label)
        default:
            throw HarnessError.usage("Unknown pcsc subcommand \(subcommand).")
        }
    }
}

private struct Options {
    private var arguments: [String]

    init(_ arguments: [String]) { self.arguments = arguments }

    mutating func flag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count else { throw HarnessError.usage("\(name) needs a value") }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    func finish() throws {
        if let unknown = arguments.first { throw HarnessError.usage("Unknown argument \(unknown).") }
    }
}
