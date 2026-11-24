import Foundation

public struct ResumeDocument: Codable, Hashable, Sendable {
    public var version: Int = 1
    public var candidateName: String
    public var headline: String?
    public var contact: Contact?
    public var links: [Link]
    public var avatarAssetId: String?
    public var sections: [Section]

    public init(candidateName: String, headline: String? = nil, sections: [Section] = []) {
        self.candidateName = candidateName
        self.headline = headline
        self.sections = sections
        links = []
    }

    public struct Contact: Codable, Hashable, Sendable {
        public var email: String?
        public var phone: String?
        public var location: String?
        public init() {}
    }

    public struct Link: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var label: String
        public var url: String
        public init(id: String = UUID().uuidString, label: String = "", url: String = "") {
            self.id = id
            self.label = label
            self.url = url
        }
    }

    public enum SectionKind: String, Codable, CaseIterable, Sendable {
        case profile, experience, education, skills, projects, certifications, custom
    }

    public struct Section: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var kind: SectionKind
        public var title: String
        public var entries: [Entry]
        public init(id: String = UUID().uuidString, kind: SectionKind, title: String, entries: [Entry] = []) {
            self.id = id
            self.kind = kind
            self.title = title
            self.entries = entries
        }
    }

    public struct Entry: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String?
        public var organization: String?
        public var location: String?
        public var startDate: String?
        public var endDate: String?
        public var current: Bool?
        public var description: String?
        public var url: String?
        public var bullets: [Bullet]
        public init(id: String = UUID().uuidString) {
            self.id = id
            bullets = []
        }
    }

    public struct Bullet: Codable, Identifiable, Hashable, Sendable {
        public var id: String
        public var text: String
        public init(id: String = UUID().uuidString, text: String = "") {
            self.id = id
            self.text = text
        }
    }
}

public struct ResumeTarget: Codable, Hashable, Sendable {
    public let familyId: String
    public let variantId: String?
    public let language: String
    public let revisionToken: String
}

public struct ResolvedResume: Decodable, Hashable, Sendable {
    public struct Variant: Decodable, Hashable, Sendable, Identifiable {
        public let id: String
        public let company: String
        public let targetRole: String?
        public let jobDescription: String?
    }

    public let familyId: String
    public let variantId: String?
    public let language: String
    public let revisionToken: String
    public let document: ResumeDocument
    public let title: String
    public let variants: [Variant]
    public let languages: [String]
    public let baseRevision: Int
    public let overridePaths: [String]?
    public let overrideCount: Int
    public let reviewPaths: [String]
    public let missingTranslationPaths: [String]
    public let recoverablePaths: [String]

    public var target: ResumeTarget {
        ResumeTarget(familyId: familyId, variantId: variantId, language: language, revisionToken: revisionToken)
    }
}

public struct ResumeRevision: Decodable, Hashable, Sendable, Identifiable {
    public var id: String { revisionToken }
    public let revision: Int
    public let revisionToken: String
    public let origin: String
    public let language: String
    public let createdAt: Date
}

public struct ResumeEdit: Codable, Hashable, Sendable {
    public let op: String
    public let path: String
    public let value: JSONValue?
    public let after: JSONValue?
    public init(_ op: String, path: String, value: JSONValue? = nil, after: JSONValue? = nil) {
        self.op = op
        self.path = path
        self.value = value
        self.after = after
    }
}

extension ResumeDocument {
    public func value(at path: String) throws -> JSONValue? {
        var node: JSONValue? = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
        for part in path.split(separator: "/") {
            let key = String(part)
            if case .array(let rows) = node { node = rows.first { $0["id"]?.stringValue == key } }
            else { node = node?[key] }
        }
        return node
    }

    /// Derive the smallest stable-ID edits from a saved document and a local draft.
    /// Inserted subtrees carry their descendants, leaving all other company fields inherited.
    public func edits(from original: Self) throws -> [ResumeEdit] {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let before = try decoder.decode(JSONValue.self, from: encoder.encode(original))
        let after = try decoder.decode(JSONValue.self, from: encoder.encode(self))
        var edits: [ResumeEdit] = []
        Self.compare(before, after, at: "", into: &edits)
        return edits
    }

    private static func compare(_ before: JSONValue?, _ after: JSONValue?, at path: String, into edits: inout [ResumeEdit]) {
        guard before != after else { return }
        if case .object(let lhs) = before ?? .object([:]), case .object(let rhs) = after ?? .object([:]) {
            for key in Set(lhs.keys).union(rhs.keys).sorted() where key != "id" && key != "version" {
                compare(lhs[key], rhs[key], at: path + "/" + key, into: &edits)
            }
        } else if case .array(let lhs) = before, case .array(let rhs) = after {
            let source = lhs.compactMap { item in item["id"]?.stringValue.map { ($0, item) } }
            let target = rhs.compactMap { item in item["id"]?.stringValue.map { ($0, item) } }
            let targetIDs = Set(target.map(\.0))
            var order = source.map(\.0).filter(targetIDs.contains)
            for (id, _) in source where !targetIDs.contains(id) {
                edits.append(.init("remove", path: path + "/" + id))
            }
            let originals = Dictionary(uniqueKeysWithValues: source)
            for (index, pair) in target.enumerated() {
                let (id, node) = pair
                let neighbor: JSONValue = index == 0 ? .null : .string(target[index - 1].0)
                if let existing = originals[id] {
                    compare(existing, node, at: path + "/" + id, into: &edits)
                    if order[index] != id, let previous = order.firstIndex(of: id) {
                        order.remove(at: previous)
                        order.insert(id, at: index)
                        edits.append(.init("move", path: path + "/" + id, after: neighbor))
                    }
                } else {
                    edits.append(.init("insert", path: path, value: node, after: neighbor))
                    order.insert(id, at: index)
                }
            }
        } else {
            edits.append(.init("set", path: path, value: after ?? .null))
        }
    }
}

public struct ResumePresentation: Codable, Hashable, Sendable {
    public enum Template: String, Codable, CaseIterable, Sendable {
        case compact = "compact-v1"
        case profile = "profile-v1"
        case editorial = "editorial-v1"
        case modern = "modern-v1"
    }
    public enum PaperSize: String, Codable, CaseIterable, Sendable { case a4 = "A4", letter = "Letter" }
    public var template: Template = .compact
    public var paperSize: PaperSize = .a4
    public var showAvatar = true
    public init() {}
}

public struct ResumePreview: Decodable, Sendable {
    public let missingTranslationPaths: [String]?
    public let id: String
    public let pdfUrl: String
    public let docxUrl: String
    public let revisionToken: String
}

public struct ResumePublication: Decodable, Sendable {
    public let expiresAt: Date?
    public let document: ResumeDocument
    public let presentation: ResumePresentation
    public let pdfUrl: String
    public let revisionToken: String
    public let language: String
}

public struct ResumeProposal: Decodable, Sendable {
    public struct Finding: Decodable, Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let rationale: String
        public let source: String?
        public let current: String?
        public let proposed: String?
        public let operation: ResumeEdit?
        public let conflict: Bool
    }
    public let id: String
    public let status: String
    public let error: String?
    public let findings: [Finding]?
}

public struct ResumePublishedLink: Decodable, Sendable, Identifiable {
    public let id: String
    public let label: String?
    public let url: URL
    public let previewId: String
    public let access: ShareLinkAccess
    public let ttlDays: Int?
    public let emails: [SummaryShareLink.Invitee]
}

public struct ViewedResumePublication: Decodable, Sendable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let title: String
    public let language: String
    public let viewedAt: Date
}

public struct ResumeVariantPreview: Decodable, Sendable {
    public let revisionToken: String
    public let operations: [ResumeEdit]
}
