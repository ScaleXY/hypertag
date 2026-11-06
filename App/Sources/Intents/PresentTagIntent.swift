import AppIntents
import Foundation
import TagStore

struct TagEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static let defaultQuery = TagEntityQuery()

    let id: UUID
    let name: String
    let kind: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)")
    }

    init(_ tag: Tag) {
        id = tag.id
        name = tag.name
        kind = tag.kind == .normal ? "Normal" : "Signer"
    }
}

struct TagEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [TagEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TagEntity] {
        try await AppModel.live.environment.repository.all().map(TagEntity.init)
    }
}

/// Only opens the tag. Apple ties presenting to an explicit tap, so the user still presses Present.
struct PresentTagIntent: AppIntent {
    static let title: LocalizedStringResource = "Present tag"
    static let description = IntentDescription("Opens Rapid Wallet on a tag, ready for you to press Present.")
    static let openAppWhenRun = true

    @Parameter(title: "Tag")
    var tag: TagEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await AppModel.live.open(tagID: tag.id)
        return .result()
    }
}

struct RapidWalletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PresentTagIntent(),
            phrases: ["Present a tag in \(.applicationName)"],
            shortTitle: "Present tag",
            systemImageName: "tag"
        )
    }
}
