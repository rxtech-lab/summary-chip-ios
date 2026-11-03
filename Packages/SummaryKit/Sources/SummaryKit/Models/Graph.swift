import Foundation

/// A picture on a node or edge.
public struct GraphImage: Codable, Sendable, Hashable, Identifiable {
    public var url: URL
    public var caption: String?
    public var credit: String?
    public var id: URL { url }

    public init(url: URL, caption: String? = nil, credit: String? = nil) {
        self.url = url
        self.caption = caption
        self.credit = credit
    }
}

/// A node: schemaless JSON `properties` like a NoSQL document, images, and an optional custom view
/// drawn with the same JSON catalog as a trip's. Mirrors `server/lib/contracts/graph.ts`.
public struct GraphNode: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var label: String
    /// What `(n:Type)` matches in a query.
    public var types: [String]
    /// `#RRGGBB`; nil colours the node by its first type.
    public var color: String?
    public var properties: [String: JSONValue]
    public var images: [GraphImage]
    public var view: TripViewSpec?

    public init(id: String, label: String, types: [String] = [], color: String? = nil, properties: [String: JSONValue] = [:], images: [GraphImage] = [], view: TripViewSpec? = nil) {
        self.id = id
        self.label = label
        self.types = types
        self.color = color
        self.properties = properties
        self.images = images
        self.view = view
    }

    private enum CodingKeys: String, CodingKey { case id, label, types, color, properties, images, view }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        images = try c.decodeIfPresent([GraphImage].self, forKey: .images) ?? []
        view = try c.decodeIfPresent(TripViewSpec.self, forKey: .view)
    }
}

/// An edge from `source` to `target`, with the same data a node has. Its `label` is what
/// `[r:LABEL]` matches in a query.
public struct GraphEdge: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var source: String
    public var target: String
    public var label: String
    public var directed: Bool
    public var color: String?
    public var properties: [String: JSONValue]
    public var images: [GraphImage]
    public var view: TripViewSpec?

    public init(id: String, source: String, target: String, label: String, directed: Bool = true, color: String? = nil, properties: [String: JSONValue] = [:], images: [GraphImage] = [], view: TripViewSpec? = nil) {
        self.id = id
        self.source = source
        self.target = target
        self.label = label
        self.directed = directed
        self.color = color
        self.properties = properties
        self.images = images
        self.view = view
    }

    private enum CodingKeys: String, CodingKey { case id, source, target, label, directed, color, properties, images, view }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = try c.decode(String.self, forKey: .source)
        target = try c.decode(String.self, forKey: .target)
        label = try c.decode(String.self, forKey: .label)
        directed = try c.decodeIfPresent(Bool.self, forKey: .directed) ?? true
        color = try c.decodeIfPresent(String.self, forKey: .color)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        images = try c.decodeIfPresent([GraphImage].self, forKey: .images) ?? []
        view = try c.decodeIfPresent(TripViewSpec.self, forKey: .view)
    }
}

/// A query kept with the graph to run again.
public struct GraphSavedQuery: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var query: String

    public init(id: String, name: String, description: String? = nil, query: String) {
        self.id = id
        self.name = name
        self.description = description
        self.query = query
    }
}

public struct GraphDocument: Codable, Sendable, Hashable {
    public var version: Int
    public var title: String
    public var description: String?
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]
    public var queries: [GraphSavedQuery]

    public init(title: String, description: String? = nil, nodes: [GraphNode] = [], edges: [GraphEdge] = [], queries: [GraphSavedQuery] = []) {
        version = 1
        self.title = title
        self.description = description
        self.nodes = nodes
        self.edges = edges
        self.queries = queries
    }

    private enum CodingKeys: String, CodingKey { case version, title, description, nodes, edges, queries }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        nodes = try c.decodeIfPresent([GraphNode].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([GraphEdge].self, forKey: .edges) ?? []
        queries = try c.decodeIfPresent([GraphSavedQuery].self, forKey: .queries) ?? []
    }
}

public enum GraphSelectionMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Dims everything else.
    case highlight
    /// Hides everything else.
    case isolate
}

/// The elements the view picks out: from a query the user ran, or from an agent.
public struct GraphSelection: Codable, Sendable, Hashable {
    public var mode: GraphSelectionMode
    public var nodeIds: [String]
    public var edgeIds: [String]
    public var query: String?

    public init(mode: GraphSelectionMode = .highlight, nodeIds: [String] = [], edgeIds: [String] = [], query: String? = nil) {
        self.mode = mode
        self.nodeIds = nodeIds
        self.edgeIds = edgeIds
        self.query = query
    }
}

/// `GET /api/v1/graphs/:id`.
public struct Graph: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    /// Bumped on every save.
    public var revision: Int
    public var visibility: SummaryVisibility
    public var isOwner: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var shareUrl: URL?
    public var document: GraphDocument
    /// Only the owner's; what they or an agent last picked out.
    public var selection: GraphSelection?

    public init(id: String, slug: String, revision: Int = 0, visibility: SummaryVisibility = .private, isOwner: Bool = true, createdAt: Date = .now, updatedAt: Date = .now, shareUrl: URL? = nil, document: GraphDocument, selection: GraphSelection? = nil) {
        self.id = id
        self.slug = slug
        self.revision = revision
        self.visibility = visibility
        self.isOwner = isOwner
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.shareUrl = shareUrl
        self.document = document
        self.selection = selection
    }
}

/// `POST /api/v1/graphs/:id/query`.
public struct GraphQueryResult: Codable, Sendable, Hashable {
    public var nodeIds: [String]
    public var edgeIds: [String]
    public var rowCount: Int
    public var truncated: Bool

    public init(nodeIds: [String] = [], edgeIds: [String] = [], rowCount: Int = 0, truncated: Bool = false) {
        self.nodeIds = nodeIds
        self.edgeIds = edgeIds
        self.rowCount = rowCount
        self.truncated = truncated
    }
}

/// One change to a graph (`POST /api/v1/graphs/:id/operations`).
public enum GraphOperation: Encodable, Sendable, Hashable {
    case setMeta(title: String, description: String?)
    case upsertNode(GraphNode)
    case upsertEdge(GraphEdge)
    case upsertQuery(GraphSavedQuery)
    case deleteNode(String)
    case deleteEdge(String)
    case deleteQuery(String)

    private enum CodingKeys: String, CodingKey { case op, title, description, node, edge, query, collection, id }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setMeta(let title, let description):
            try c.encode("set_meta", forKey: .op)
            try c.encode(title, forKey: .title)
            try c.encode(description, forKey: .description)
        case .upsertNode(let node):
            try c.encode("upsert_node", forKey: .op)
            try c.encode(node, forKey: .node)
        case .upsertEdge(let edge):
            try c.encode("upsert_edge", forKey: .op)
            try c.encode(edge, forKey: .edge)
        case .upsertQuery(let query):
            try c.encode("upsert_query", forKey: .op)
            try c.encode(query, forKey: .query)
        case .deleteNode(let id): try Self.encodeDelete(&c, collection: "nodes", id: id)
        case .deleteEdge(let id): try Self.encodeDelete(&c, collection: "edges", id: id)
        case .deleteQuery(let id): try Self.encodeDelete(&c, collection: "queries", id: id)
        }
    }

    private static func encodeDelete(_ c: inout KeyedEncodingContainer<CodingKeys>, collection: String, id: String) throws {
        try c.encode("delete", forKey: .op)
        try c.encode(collection, forKey: .collection)
        try c.encode(id, forKey: .id)
    }
}

/// A new element's id, from its name: readable in queries and unique in the graph.
public enum GraphElementID {
    public static func make(from label: String, taken: Set<String>) -> String {
        let allowed = CharacterSet.alphanumerics.subtracting(CharacterSet(charactersIn: "\u{80}"..."\u{10FFFF}"))
        let words = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }
        let stem = String(words.joined(separator: "-").prefix(60))
        let base = stem.isEmpty ? "item" : stem
        if !taken.contains(base) { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
