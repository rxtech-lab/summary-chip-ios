import Foundation

/// The TeX engine a paper is compiled with. Mirrors `PAPER_COMPILERS` (`server/lib/contracts/paper.ts`).
public enum PaperCompiler: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case pdflatex
    case xelatex
    case lualatex

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pdflatex: "pdfLaTeX"
        case .xelatex: "XeLaTeX"
        case .lualatex: "LuaLaTeX"
        }
    }

    public var detail: String {
        switch self {
        case .pdflatex: String(localized: "The standard engine; fastest.", bundle: .module, comment: "LaTeX engine description")
        case .xelatex: String(localized: "System fonts and CJK text.", bundle: .module, comment: "LaTeX engine description")
        case .lualatex: String(localized: "System fonts and Lua scripting.", bundle: .module, comment: "LaTeX engine description")
        }
    }

    public init(from decoder: any Decoder) throws {
        // A newer server's engine reads as the standard one rather than failing the paper.
        self = PaperCompiler(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .pdflatex
    }
}

public struct PaperAsset: Codable, Sendable, Hashable {
    public var key: String
    public var mimeType: String
    public var byteSize: Int

    public init(key: String, mimeType: String, byteSize: Int) {
        self.key = key
        self.mimeType = mimeType
        self.byteSize = byteSize
    }
}

/// A text source file or a reference to an image uploaded to S3.
public struct PaperFile: Codable, Sendable, Hashable, Identifiable {
    /// Relative, `/`-separated: `sections/introduction.tex`.
    public var path: String
    public var content: String
    public var asset: PaperAsset?

    public var id: String { path }

    public init(path: String, content: String = "", asset: PaperAsset? = nil) {
        self.path = path
        self.content = content
        self.asset = asset
    }

    public var isImage: Bool { asset != nil }

    /// `introduction.tex`.
    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    /// `sections`, or nil at the top.
    public var folder: String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    public var isTeX: Bool { fileExtension == "tex" }

    public var systemImage: String {
        switch fileExtension {
        case "tex": "doc.text"
        case "bib": "books.vertical"
        case "sty", "cls", "bst", "def", "cfg", "clo", "bbx", "cbx", "lbx": "paintbrush"
        case "csv", "tsv", "dat": "tablecells"
        case "png", "jpg", "jpeg": "photo"
        case "pdf": "doc.richtext"
        case "tikz": "point.3.connected.trianglepath.dotted"
        default: "doc.plaintext"
        }
    }
}

/// Paths the server accepts for paper files; mirrors `paperPathSchema`.
public enum PaperPath {
    public static let allowedExtensions: Set<String> = Set([
        "tex", "bib", "sty", "cls", "bst", "bbx", "cbx", "lbx", "def", "cfg", "clo", "ist", "tikz", "txt", "csv", "tsv", "dat", "md",
    ]).union(imageExtensions)
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf"]
    public static let maxFiles = 60

    /// Why `path` isn't a valid file path, or nil when it is.
    public static func problem(with path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let validPart = { (part: Substring) -> Bool in
            guard let first = part.first, first != "." else { return false }
            return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        }
        guard !path.isEmpty, path.count <= 160, parts.count <= 5, parts.allSatisfy(validPart) else {
            return String(localized: "Use a relative path like sections/introduction.tex, with letters, digits, dots, dashes and underscores.", bundle: .module)
        }
        let ext = (String(parts.last!) as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else {
            return String(localized: "Use a LaTeX text file, PNG, JPEG or PDF.", bundle: .module)
        }
        return nil
    }
}

/// `GET /api/v1/papers/:id`: a LaTeX paper's working copy. `id` is its library item's id.
public struct Paper: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    /// Counts saves of the working copy; autosaves send the one they edited.
    public var revision: Int
    public var visibility: SummaryVisibility
    public var isOwner: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var shareUrl: URL
    public var title: String
    public var files: [PaperFile]
    public var mainFile: String
    public var compiler: PaperCompiler
    /// The newest saved version.
    public var version: Int?
    /// Manual edits not saved as a version yet; they are when the editor closes.
    public var hasUnversionedChanges: Bool
    public var likedAt: Date?
    /// The bibliography entries with their fact-checks (the owner's only); see `referenceList`.
    public var references: [PaperReference]?
    public var originalLanguage: String?
    public var language: String?
    public var displayLanguage: String?
    public var translationOutdated: Bool?
    public var renderingOptions: PaperRendering?
    public var rendering: PaperRendering { renderingOptions ?? PaperRendering() }

    public var writtenLanguage: String { originalLanguage ?? language ?? "en" }
    public var readingLanguage: String { language ?? writtenLanguage }
    public var isTranslated: Bool { readingLanguage != writtenLanguage }

    public init(
        id: String, slug: String, revision: Int, visibility: SummaryVisibility = .private, isOwner: Bool = true,
        createdAt: Date = .now, updatedAt: Date = .now, shareUrl: URL, title: String, files: [PaperFile], mainFile: String,
        compiler: PaperCompiler = .pdflatex, version: Int? = 1, hasUnversionedChanges: Bool = false, likedAt: Date? = nil,
        references: [PaperReference]? = nil, originalLanguage: String? = nil, language: String? = nil,
        displayLanguage: String? = nil, translationOutdated: Bool? = nil, renderingOptions: PaperRendering? = nil
    ) {
        self.id = id; self.slug = slug; self.revision = revision; self.visibility = visibility; self.isOwner = isOwner
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.shareUrl = shareUrl; self.title = title; self.files = files
        self.mainFile = mainFile; self.compiler = compiler; self.version = version; self.hasUnversionedChanges = hasUnversionedChanges
        self.likedAt = likedAt
        self.references = references
        self.originalLanguage = originalLanguage
        self.language = language
        self.displayLanguage = displayLanguage
        self.translationOutdated = translationOutdated
        self.renderingOptions = renderingOptions
    }

    /// What an autosave sends and a version keeps.
    public var source: PaperSource {
        PaperSource(title: title, files: files, mainFile: mainFile, compiler: compiler)
    }
}

/// A paper's title and LaTeX project: the working copy being edited, or a saved version's content.
public struct PaperSource: Codable, Sendable, Hashable {
    public var title: String
    public var files: [PaperFile]
    public var mainFile: String
    public var compiler: PaperCompiler

    public init(title: String, files: [PaperFile], mainFile: String, compiler: PaperCompiler = .pdflatex) {
        self.title = title
        self.files = files
        self.mainFile = mainFile
        self.compiler = compiler
    }

    /// The files in reading order: the main file first, then the other `.tex` files, then the rest, each by path.
    public var orderedFiles: [PaperFile] {
        files.sorted { a, b in
            let rank = { (file: PaperFile) in file.path == mainFile ? 0 : file.isTeX ? 1 : 2 }
            return (rank(a), a.path) < (rank(b), b.path)
        }
    }

    public func file(_ path: String) -> PaperFile? { files.first { $0.path == path } }

    /// Sets a file's content (adding the file when it's new).
    public mutating func write(_ path: String, content: String) {
        write(PaperFile(path: path, content: content))
    }

    /// Replaces the complete file, preserving an image's S3 reference on saves and merges.
    public mutating func write(_ file: PaperFile) {
        if let index = files.firstIndex(where: { $0.path == file.path }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }

    /// Moves a file; the main file follows.
    public mutating func rename(_ path: String, to newPath: String) {
        guard let index = files.firstIndex(where: { $0.path == path }) else { return }
        files[index].path = newPath
        if mainFile == path { mainFile = newPath }
    }

    public mutating func delete(_ path: String) {
        guard path != mainFile else { return }
        files.removeAll { $0.path == path }
    }
}

/// One row of `GET /api/v1/papers`.
public struct PaperListItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String
    public var title: String
    public var mainFile: String
    public var fileCount: Int
    public var revision: Int
    public var updatedAt: Date
}

/// Where a new paper starts: `POST /api/v1/papers`'s `template`.
public enum PaperTemplate: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case article
    case report
    case blank

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .article: String(localized: "Article", bundle: .module, comment: "Paper template")
        case .report: String(localized: "Report", bundle: .module, comment: "Paper template")
        case .blank: String(localized: "Blank", bundle: .module, comment: "Paper template")
        }
    }

    public var detail: String {
        switch self {
        case .article: String(localized: "Abstract, sections and a bibliography.", bundle: .module, comment: "Paper template description")
        case .report: String(localized: "Title page, contents and chapters.", bundle: .module, comment: "Paper template description")
        case .blank: String(localized: "A single empty document.", bundle: .module, comment: "Paper template description")
        }
    }

    public var systemImage: String {
        switch self {
        case .article: "doc.richtext"
        case .report: "book.closed"
        case .blank: "doc"
        }
    }
}

/// A problem from the LaTeX log, at a project file and line when the log says.
public struct LatexIssue: Codable, Sendable, Hashable, Identifiable {
    public var file: String?
    public var line: Int?
    public var message: String

    public var id: String { "\(file ?? "-"):\(line ?? 0):\(message)" }

    public init(file: String?, line: Int?, message: String) {
        self.file = file
        self.line = line
        self.message = message
    }

    /// "sections/intro.tex:12".
    public var location: String? {
        guard let file else { return nil }
        return line.map { "\(file):\($0)" } ?? file
    }
}

/// `POST /api/v1/papers/:id/check`: a strict compile of the working copy.
public struct PaperCheck: Decodable, Sendable, Hashable {
    public var ok: Bool
    public var revision: Int
    public var errors: [LatexIssue]
    public var log: String?

    public init(ok: Bool, revision: Int, errors: [LatexIssue] = [], log: String? = nil) {
        self.ok = ok
        self.revision = revision
        self.errors = errors
        self.log = log
    }

    private enum CodingKeys: String, CodingKey { case ok, revision, errors, log }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        revision = try c.decode(Int.self, forKey: .revision)
        errors = try c.decodeIfPresent([LatexIssue].self, forKey: .errors) ?? []
        log = try c.decodeIfPresent(String.self, forKey: .log)
    }
}

/// A compiled paper (`GET /api/v1/papers/:id/pdf`).
public struct PaperPDF: Sendable, Hashable {
    public var data: Data
    /// The working copy's revision it was compiled from; nil for a saved version.
    public var revision: Int?

    public init(data: Data, revision: Int?) {
        self.data = data
        self.revision = revision
    }
}

public extension SummaryAPIError {
    /// The paper changed since it was loaded (`409 PAPER_REVISION_CONFLICT`), usually by an agent.
    var isPaperRevisionConflict: Bool { statusCode == 409 && code == "PAPER_REVISION_CONFLICT" }

    /// The LaTeX errors of a compile that produced no PDF (`422 LATEX_COMPILE_FAILED`), else nil.
    var latexIssues: [LatexIssue]? {
        guard case .server(422, let body) = self, body.code == "LATEX_COMPILE_FAILED" else { return nil }
        return (try? body.details?["errors"]?.decode([LatexIssue].self)) ?? []
    }
}
