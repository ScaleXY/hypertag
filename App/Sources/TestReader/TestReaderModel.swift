import CryptoKit
import EmulationKit
import Foundation
import Observation
import SignerCore
import TagEngine
import TagStore

struct ReaderRun: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    var exchanges: [ExchangedAPDU] = []
    var verdict: ReaderVerdict?
}

/// Drives the simulated reader. It owns no key state: it uses the tag screen's `SignerSession`,
/// so the first and second run of Review mode really are two presentations of one session.
@MainActor @Observable
final class TestReaderModel {
    enum Action: String, CaseIterable, Identifiable {
        case sign, authenticate, readKey
        var id: Self { self }
        var title: String {
            switch self {
            case .sign: "Sign"
            case .authenticate: "Login"
            case .readKey: "Read Key"
            }
        }
    }

    weak var detail: TagDetailModel?

    private(set) var runs: [ReaderRun] = []
    private(set) var isRunning = false
    private(set) var digest = TestReaderModel.randomBytes(32)
    var action = Action.sign
    var format = SignatureFormat.compactRecoverable
    var label = "Test Reader (simulated)"
    var notice: String?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var runCount = 0

    /// A real reader repeats the same request on the second tap, so the inputs lock until the flow resolves.
    var isMidReview: Bool {
        detail?.pendingOnSession != nil || detail?.signatureReadyUntil != nil
    }

    func newDigest() {
        digest = Self.randomBytes(32)
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        notice = nil
        runTask = Task {
            await performRun()
            isRunning = false
        }
    }

    func stop() {
        runTask?.cancel()
    }

    func clear() {
        runs = []
    }

    private func performRun() async {
        guard let detail, let tag = detail.tag else { return }
        let plan: Plan
        let applet: any CardApplet
        detail.app.isExpectingSystemUI = true
        do {
            plan = try makePlan(for: tag)
            applet = try await detail.prepareApplet(for: tag)
            detail.app.isExpectingSystemUI = false
        } catch {
            detail.app.isExpectingSystemUI = false
            await detail.finishSignerRun()
            notice = AppModel.message(for: error)
            return
        }

        runCount += 1
        runs.insert(ReaderRun(number: runCount, title: plan.title), at: 0)
        let runID = runs[0].id
        let transport = ScriptedTransport(commands: plan.commands)
        var outcome: PresentationOutcome?
        for await event in transport.run(router: AppletRouter(applet: applet), prompts: .standard) {
            switch event {
            case .exchanged(let exchange): append(exchange, to: runID)
            case .finished(let result): outcome = result
            default: break
            }
        }

        await detail.finishSignerRun()
        await detail.reloadHistory()
        guard !Task.isCancelled, outcome == .completed else {
            finish(runID, verdict: ReaderVerdict(tone: .failure, headline: "Stopped before the reader finished. Any unlocked key was cleared."))
            return
        }
        finish(runID, verdict: plan.verdict(exchanges(of: runID)))
        await detail.app.recordPresented(tagID: tag.id)
        detail.reviewRequest = detail.pendingOnSession
    }

    private func append(_ exchange: ExchangedAPDU, to runID: UUID) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].exchanges.append(exchange)
    }

    private func exchanges(of runID: UUID) -> [ExchangedAPDU] {
        runs.first { $0.id == runID }?.exchanges ?? []
    }

    private func finish(_ runID: UUID, verdict: ReaderVerdict) {
        guard let index = runs.firstIndex(where: { $0.id == runID }) else { return }
        runs[index].verdict = verdict
    }

    // MARK: Scripts

    private struct Plan {
        let title: String
        let commands: [Data]
        let verdict: ([ExchangedAPDU]) -> ReaderVerdict
    }

    private func makePlan(for tag: Tag) throws -> Plan {
        switch tag.content {
        case .normal(let config):
            let message = try NDEFMessageBuilder.encode(config.records)
            return Plan(title: "Type 4 read", commands: ReaderScripts.type4Read(messageLength: message.count)) {
                ReaderDecoding.type4Verdict(exchanges: $0, authored: message)
            }
        case .signer(let config):
            let tagID = tag.id
            let publicKey = config.publicKey
            switch action {
            case .sign:
                let digest = digest
                return Plan(title: "Sign digest", commands: ReaderScripts.signerSign(digest: digest, format: format, label: label)) {
                    ReaderDecoding.signerVerdict(exchanges: $0, tagID: tagID, publicKey: publicKey, digest: digest, readerNonce: nil)
                }
            case .authenticate:
                let nonce = Self.randomBytes(32)
                return Plan(title: "Login challenge", commands: ReaderScripts.signerAuthenticate(nonce: nonce)) {
                    ReaderDecoding.signerVerdict(exchanges: $0, tagID: tagID, publicKey: publicKey, digest: nil, readerNonce: nonce)
                }
            case .readKey:
                return Plan(title: "Read status and key", commands: Self.readKeyScript) {
                    ReaderDecoding.signerVerdict(exchanges: $0, tagID: tagID, publicKey: publicKey, digest: nil, readerNonce: nil)
                }
            }
        }
    }

    /// `ReaderScripts` has no script for these two, so they're written out from the protocol table in plan 04.
    private static let readKeyScript: [Data] = [
        Data([0x00, 0xA4, 0x04, 0x00, UInt8(SignerApplet.defaultAID.count)]) + SignerApplet.defaultAID + Data([0x00]),
        Data([0x80, 0x10, 0x00, 0x00, 0x00]),
        Data([0x80, 0x20, 0x00, 0x00, 0x00]),
    ]

    private static func randomBytes(_ count: Int) -> Data {
        // Test input only, never key material.
        Data(SHA256.hash(data: UUID().uuidString.data(using: .utf8)!).prefix(count))
    }
}
