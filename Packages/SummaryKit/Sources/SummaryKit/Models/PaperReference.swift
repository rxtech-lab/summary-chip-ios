import Foundation

/// Where a reference's fact-check stands. Mirrors `PAPER_REFERENCE_STATUSES` (`server/lib/contracts/paper.ts`).
public enum PaperReferenceStatus: String, Codable, Sendable, Hashable {
    /// Not checked yet; the next save that touches the bibliography checks it.
    case unchecked
    case checking
    case verified
    case error

    public init(from decoder: any Decoder) throws {
        // A newer server's status reads as not checked rather than failing the paper.
        self = PaperReferenceStatus(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unchecked
    }
}

/// Why a reference didn't hold up. Mirrors `PAPER_REFERENCE_ISSUES`.
public enum PaperReferenceIssue: String, Codable, Sendable, Hashable {
    case linkNotFound = "link_not_found"
    case referenceNotFound = "reference_not_found"
    case unreliableSource = "unreliable_source"
    case linkMismatch = "link_mismatch"
    case misreference
    case other

    public init(from decoder: any Decoder) throws {
        self = PaperReferenceIssue(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    public var title: String {
        switch self {
        case .linkNotFound: String(localized: "Link doesn't open", bundle: .module, comment: "Paper reference error")
        case .referenceNotFound: String(localized: "Reference not found", bundle: .module, comment: "Paper reference error")
        case .unreliableSource: String(localized: "Unreliable source", bundle: .module, comment: "Paper reference error")
        case .linkMismatch: String(localized: "Link shows a different work", bundle: .module, comment: "Paper reference error")
        case .misreference: String(localized: "Misreferenced", bundle: .module, comment: "Paper reference error")
        case .other: String(localized: "Reference error", bundle: .module, comment: "Paper reference error")
        }
    }

    public var systemImage: String {
        switch self {
        case .linkNotFound: "link.badge.plus"
        case .referenceNotFound: "questionmark.text.page"
        case .unreliableSource: "exclamationmark.shield"
        case .linkMismatch: "arrow.triangle.swap"
        case .misreference, .other: "exclamationmark.triangle"
        }
    }
}

/// One bibliography entry of a paper's working copy with its fact-check: whether its link opens,
/// the work exists and is reliable, the link shows that work, and it supports the citing sentences.
public struct PaperReference: Codable, Sendable, Hashable, Identifiable {
    /// The citation key: `\cite{key}`.
    public var key: String
    /// The `.bib` file (or the `.tex` file with `\bibitem`) the entry is in.
    public var file: String
    public var line: Int
    /// The entry's title as plain text.
    public var title: String?
    /// The entry's `url`, or its DOI as a doi.org link (a string: a bibliography can hold anything).
    public var url: String?
    public var status: PaperReferenceStatus
    public var issue: PaperReferenceIssue?
    /// What the check found: why it's an error, or what confirmed it.
    public var message: String?
    public var checkedAt: Date?

    public var id: String { key }
    public var isError: Bool { status == .error }

    public init(
        key: String, file: String, line: Int, title: String? = nil, url: String? = nil, status: PaperReferenceStatus,
        issue: PaperReferenceIssue? = nil, message: String? = nil, checkedAt: Date? = nil
    ) {
        self.key = key; self.file = file; self.line = line; self.title = title; self.url = url; self.status = status
        self.issue = issue; self.message = message; self.checkedAt = checkedAt
    }

    public var link: URL? { url.flatMap(URL.init(string:)) }

    /// "references.bib:12".
    public var location: String { "\(file):\(line)" }

    /// Phrases to find the entry by in the compiled PDF's bibliography, longest first: the title's
    /// opening words (a PDF breaks lines and hyphenates, so a whole title rarely matches).
    public var searchPhrases: [String] {
        let words = (title ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        var phrases: [String] = []
        for count in [6, 4, 3] where words.count >= min(count, 2) {
            let phrase = words.prefix(count).joined(separator: " ")
            if phrase.count >= 8, !phrases.contains(phrase) { phrases.append(phrase) }
        }
        return phrases
    }
}

public extension Paper {
    /// The working copy's references; empty for papers someone else owns.
    var referenceList: [PaperReference] { references ?? [] }
    var referenceErrors: [PaperReference] { referenceList.filter(\.isError) }
    var isCheckingReferences: Bool { referenceList.contains { $0.status == .checking } }
}
