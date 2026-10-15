import Foundation

public struct MiniApp: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var document: MiniAppDocument
    public var revision: Int
    public var isOwner: Bool
    public var shareUrl: String
    public var permissions: [String: String]
}

public struct MiniAppDocument: Codable, Sendable, Hashable {
    public var schemaVersion: Int
    public var title: String
    public var description: String
    public var ui: MiniAppUI
    public var initialState: [String: JSONValue]
    public var tables: [String: JSONValue]
    public var queries: [String: JSONValue]
    public var actions: [String: JSONValue]
    public var scripts: [String: String]
    public var connectors: [String: JSONValue]
    public var fixtures: JSONValue

    public static func blank(title: String = "My Mini App") -> Self {
        Self(schemaVersion: 1, title: title, description: "", ui: MiniAppUI(root: "root", elements: [
            "root": MiniAppNode(type: "Navigation", props: ["title": .string(title)], children: ["text"]),
            "text": MiniAppNode(type: "Text", props: ["text": .string("Use Edit with AI to build your app.")])
        ]), initialState: [:], tables: [:], queries: [:], actions: [:], scripts: [:], connectors: [:], fixtures: .object(["records": .object([:]), "responses": .object([:])]))
    }
}

public struct MiniAppUI: Codable, Sendable, Hashable {
    public var root: String
    public var elements: [String: MiniAppNode]
}

public struct MiniAppNode: Codable, Sendable, Hashable {
    public var type: String
    public var props: [String: JSONValue]
    public var children: [String]
    public var visible: JSONValue?
    public var `repeat`: JSONValue?
    public var events: [String: String]

    public init(type: String, props: [String: JSONValue] = [:], children: [String] = [], visible: JSONValue? = nil, repeat: JSONValue? = nil, events: [String: String] = [:]) {
        self.type = type; self.props = props; self.children = children
        self.visible = visible; self.repeat = `repeat`; self.events = events
    }
}

public struct MiniAppRunResult: Codable, Sendable {
    public var state: [String: JSONValue]
    public var effects: [JSONValue]
    public var records: [String: [JSONValue]]?
}

public struct MiniAppRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var data: [String: JSONValue]
    public var revision: Int
}

public struct MiniAppRecordPage: Codable, Sendable {
    public var items: [MiniAppRecord]
    public var nextCursor: String?
}

public extension JSONValue {
    var miniObject: [String: JSONValue] { if case .object(let value) = self { value } else { [:] } }
    var miniArray: [JSONValue] { if case .array(let value) = self { value } else { [] } }
    var miniText: String {
        switch self {
        case .string(let value): value
        case .number(let value): value.formatted(.number.grouping(.never))
        case .bool(let value): value ? "true" : "false"
        case .null: ""
        default: String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? ""
        }
    }
    /// A number, or a string holding one (coordinates typed into a field).
    var miniNumber: Double? {
        switch self {
        case .number(let value): value.isFinite ? value : nil
        case .string(let value): Double(value.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: nil
        }
    }
    var miniTruth: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        default: true
        }
    }
}
