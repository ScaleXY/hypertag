import EmulationKit
import Foundation
import SignerCore
import TagEngine
import TagStore
import WalletBridge

enum SampleData {
    static let signerKey = Data([0x02] + (0..<32).map { UInt8(($0 &* 37) & 0xFF) })

    static let tags: [Tag] = [
        Tag(name: "Office Wi-Fi", content: .normal(NormalTagConfig(records: [.url("https://example.com/wifi")], includesQRCode: true)),
            walletStatus: .added),
        Tag(name: "Business card", content: .normal(NormalTagConfig(records: [
            .contact(vCard: ContactFields(name: "Sam Rivera", phone: "+1 555 0100", email: "sam@example.com", organization: "Example Inc.").vCard),
            .url("https://example.com/sam"),
        ]))),
        Tag(name: "Door login", content: .signer(SignerTagConfig(publicKey: signerKey))),
    ]
}

extension AppEnvironment {
    static func preview(tags: [Tag] = SampleData.tags) -> AppEnvironment {
        AppEnvironment(repository: InMemoryTagRepository(tags: tags), vault: InMemoryVault(), transport: NoRadioTransport(),
                       wallet: WalletLibrary(passTypeIdentifier: passTypeIdentifier))
    }
}

extension AppModel {
    static func preview(tags: [Tag] = SampleData.tags) -> AppModel {
        let model = AppModel(environment: .preview(tags: tags))
        Task { await model.launch() }
        return model
    }
}
