import Foundation

/// Image and figure creation shares the paper's existing autosave and version history.
public enum PaperFigureKind: String, CaseIterable, Identifiable, Sendable {
    case image
    case tikz
    case plot

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .image: String(localized: "Image", bundle: .module)
        case .tikz: String(localized: "TikZ Diagram", bundle: .module)
        case .plot: String(localized: "pgfplots Chart", bundle: .module)
        }
    }
    public var systemImage: String {
        switch self {
        case .image: "photo"
        case .tikz: "point.3.connected.trianglepath.dotted"
        case .plot: "chart.xyaxis.line"
        }
    }

    public var starter: String {
        switch self {
        case .image: ""
        case .tikz:
            #"""
            \begin{tikzpicture}
              \node[draw, rounded corners] (input) at (0,0) {Input};
              \node[draw, rounded corners] (output) at (4,0) {Output};
              \draw[->, thick] (input) -- (output);
            \end{tikzpicture}
            """#
        case .plot:
            #"""
            \begin{tikzpicture}
              \begin{axis}[width=0.8\linewidth, xlabel={$x$}, ylabel={$y$}, grid=major]
                \addplot[blue, thick, domain=0:5, samples=50] {x^2};
              \end{axis}
            \end{tikzpicture}
            """#
        }
    }
}

public struct PaperProjectError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Mirrors the server limits; image bytes are uploaded directly to S3.
public enum PaperLimits {
    public static let maxImageBytes = 10 * 1024 * 1024
    public static let maxTotalImageBytes = 25 * 1024 * 1024
    public static let maxFileCharacters = 400_000
    public static let maxTotalCharacters = 800_000
    public static func validateImage(path: String, data: Data) throws {
        if let problem = PaperPath.problem(with: path) { throw PaperProjectError(problem) }
        guard data.count <= maxImageBytes else { throw PaperProjectError(String(localized: "Each image is limited to 10 MB.", bundle: .module)) }
        guard matchesImage(data, extension: (path as NSString).pathExtension.lowercased()) else {
            throw PaperProjectError(String(localized: "Choose a PNG, JPEG or PDF whose contents match its file extension.", bundle: .module))
        }
    }

    public static func problem(with source: PaperSource) -> String? {
        if source.files.count > PaperPath.maxFiles { return String(localized: "A paper can have at most 60 files.", bundle: .module) }
        var imageBytes = 0
        var textCharacters = 0
        for file in source.files {
            if let problem = PaperPath.problem(with: file.path) { return problem }
            if let asset = file.asset {
                let mime = file.fileExtension == "png" ? "image/png" : file.fileExtension == "pdf" ? "application/pdf" : "image/jpeg"
                guard PaperPath.imageExtensions.contains(file.fileExtension), asset.mimeType == mime,
                      asset.byteSize > 0, asset.byteSize <= maxImageBytes, file.content.isEmpty else {
                    return String(localized: "Choose a valid PNG, JPEG or PDF, up to 10 MB.", bundle: .module)
                }
                imageBytes += asset.byteSize
            } else {
                if PaperPath.imageExtensions.contains(file.fileExtension) { return String(localized: "Image files must be imported from a PNG, JPEG or PDF.", bundle: .module) }
                let count = file.content.utf16.count
                if count > maxFileCharacters { return String(localized: "Each source file is limited to 400,000 characters.", bundle: .module) }
                textCharacters += count
            }
        }
        if imageBytes > maxTotalImageBytes { return String(localized: "The paper's images together are limited to 25 MB.", bundle: .module) }
        if textCharacters > maxTotalCharacters { return String(localized: "The paper's source text is limited to 800,000 characters.", bundle: .module) }
        return nil
    }

    private static func matchesImage(_ data: Data, extension ext: String) -> Bool {
        switch ext {
        case "png": data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        case "jpg", "jpeg": data.starts(with: [255, 216, 255])
        case "pdf": data.starts(with: Data("%PDF-".utf8))
        default: false
        }
    }
}

extension PaperSource {
    /// Creates one figure file, loads its package in the main preamble, and includes it in the
    /// chosen TeX file. Works on a copy so validation failures leave the project untouched.
    public mutating func addFigure(
        kind: PaperFigureKind, path: String, caption: String, code: String,
        image: PaperFile? = nil, target: String? = nil
    ) throws {
        var next = self
        guard PaperPath.problem(with: path) == nil, path.lowercased().hasSuffix(".tex"), next.file(path) == nil else {
            throw PaperProjectError(String(localized: "Choose an unused .tex path for the figure.", bundle: .module))
        }
        let destination = target.flatMap { next.file($0)?.isTeX == true ? $0 : nil } ?? mainFile
        guard var main = next.file(mainFile), Self.commandRange(#"\\begin\s*\{document\}"#, in: main.content) != nil else {
            throw PaperProjectError(String(localized: "The main file needs \\begin{document} before a figure can be added.", bundle: .module))
        }
        let package = kind == .image ? "graphicx" : kind == .tikz ? "tikz" : "pgfplots"
        main.content = Self.addPackage(package, to: main.content)
        next.write(main)
        let body: String
        if kind == .image {
            guard let image, image.isImage, image.path != path, next.file(image.path) == nil else {
                throw PaperProjectError(String(localized: "Choose an image with an unused file name.", bundle: .module))
            }
            next.write(image)
            body = "\\includegraphics[width=0.8\\linewidth]{\(image.path)}"
        } else {
            guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PaperProjectError(String(localized: "Enter the figure's LaTeX source.", bundle: .module))
            }
            body = code
        }
        let figure = "\\begin{figure}[htbp]\n\\centering\n\(body)\n\\caption{\(Self.texText(caption))}\n\\end{figure}\n"
        next.write(path, content: figure)
        guard var file = next.file(destination) else { return }
        let include = "\n\\input{\(path)}\n"
        if let end = Self.commandRange(#"\\end\s*\{document\}"#, in: file.content, last: true) {
            file.content.insert(contentsOf: include, at: end.lowerBound)
        } else {
            file.content += include
        }
        next.write(file)
        if let problem = PaperLimits.problem(with: next) { throw PaperProjectError(problem) }
        self = next
    }

    private static func texText(_ text: String) -> String {
        let escaped: [Character: String] = ["\\": "\\textbackslash{}", "{": "\\{", "}": "\\}", "$": "\\$", "&": "\\&", "%": "\\%", "#": "\\#", "_": "\\_", "^": "\\textasciicircum{}", "~": "\\textasciitilde{}"]
        return text.map { escaped[$0] ?? String($0) }.joined()
    }

    private static func addPackage(_ package: String, to text: String) -> String {
        guard let begin = commandRange(#"\\begin\s*\{document\}"#, in: text) else { return text }
        let preamble = String(text[..<begin.lowerBound])
        let pattern = #"\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{[^}]*\b"# + package + #"\b[^}]*\}"#
        guard commandRange(pattern, in: preamble) == nil else { return text }
        var result = text
        let options = package == "pgfplots" ? "\\pgfplotsset{compat=1.18}\n" : ""
        result.insert(contentsOf: "\\usepackage{\(package)}\n\(options)\n", at: begin.lowerBound)
        return result
    }

    /// Ignores commented commands while preserving indices into the original source.
    private static func commandRange(_ pattern: String, in text: String, last: Bool = false) -> Range<String.Index>? {
        let masked = NSMutableString(string: text)
        let comments = try? NSRegularExpression(pattern: #"(?m)(?<!\\)%[^\r\n]*"#)
        for match in comments?.matches(in: text, range: NSRange(location: 0, length: masked.length)).reversed() ?? [] {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let matches = (try? NSRegularExpression(pattern: pattern))?.matches(in: masked as String, range: NSRange(location: 0, length: masked.length)) ?? []
        guard let match = last ? matches.last : matches.first else { return nil }
        return Range(match.range, in: text)
    }
}
