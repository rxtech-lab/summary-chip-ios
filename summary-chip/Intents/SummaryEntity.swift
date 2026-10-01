import AppIntents
import SummaryKit

/// A summary as Siri, Shortcuts and Spotlight see it.
struct SummaryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Summary"
    static let defaultQuery = SummaryEntityQuery()

    let id: String
    @Property(title: "Title") var title: String
    @Property(title: "Summary") var text: String
    @Property(title: "Share Link") var shareURL: URL
    @Property(title: "Source Link") var sourceURL: URL?
    let systemImage: String

    init(_ summary: SummaryKit.Summary) {
        id = summary.id
        systemImage = summary.source.systemImage
        title = summary.title
        text = summary.summary
        shareURL = summary.shareUrl
        sourceURL = summary.sourceUrl
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(text)", image: .init(systemName: systemImage))
    }
}

struct SummaryEntityQuery: EntityQuery {
    @Dependency private var environment: AppEnvironment

    func entities(for identifiers: [SummaryEntity.ID]) async throws -> [SummaryEntity] {
        var entities: [SummaryEntity] = []
        for id in identifiers {
            if let summary = try? await environment.api.summary(id: id) {
                entities.append(SummaryEntity(summary))
            }
        }
        return entities
    }

    @MainActor
    func suggestedEntities() async throws -> [SummaryEntity] {
        environment.library.items.prefix(10).map(SummaryEntity.init)
    }
}
