import Foundation

/// A file a Clip hands to the native Save dialog: built from state by an `export` step, or fetched
/// by a `download` step. The server only evaluates these steps; bytes are produced on the device.
public struct MiniAppFile: Sendable, Equatable {
    public var filename: String
    public var data: Data

    public static let exportLimit = 1024 * 1024
    public static let downloadLimit = 25 * 1024 * 1024

    public init(filename: String, data: Data) {
        self.filename = filename; self.data = data
    }

    public enum Failure: LocalizedError, Equatable {
        case invalidURL
        case http(Int)
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidURL: "Downloads need an HTTPS URL."
            case .http(let status): "The download failed with HTTP \(status)."
            case .tooLarge(let limit): "The file exceeds \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
            }
        }
    }

    /// `effect` is an evaluated `export` step: `{filename, format: text | csv | json, content}`.
    public static func export(_ effect: JSONValue) throws -> MiniAppFile {
        let format = effect["format"]?.stringValue ?? "text"
        let content = effect["content"] ?? .null
        let data: Data
        switch format {
        case "csv": data = Data(csv(content).utf8)
        case "json":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(content)
        default: data = Data(text(content).utf8)
        }
        guard data.count <= exportLimit else { throw Failure.tooLarge(exportLimit) }
        let ext = format == "csv" || format == "json" ? format : "txt"
        return MiniAppFile(filename: filename(text(effect["filename"] ?? .null), fallback: "Export", defaultExtension: ext), data: data)
    }

    /// `effect` is an evaluated `download` step: `{url, filename?}`. Reads at most `downloadLimit` bytes.
    public static func download(_ effect: JSONValue, session: URLSession = .shared) async throws -> MiniAppFile {
        let url = try downloadURL(effect["url"] ?? .null)
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 30))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        guard response.expectedContentLength <= Int64(downloadLimit) else { throw Failure.tooLarge(downloadLimit) }
        var data = Data(); data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > downloadLimit { throw Failure.tooLarge(downloadLimit) }
        }
        let suggested = effect["filename"].map(text) ?? response.suggestedFilename ?? url.lastPathComponent
        return MiniAppFile(filename: filename(suggested, fallback: "Download", defaultExtension: nil), data: data)
    }

    /// HTTPS only, without credentials, matching the server's check.
    static func downloadURL(_ value: JSONValue) throws -> URL {
        guard let text = value.stringValue, text.count <= 2048, let url = URL(string: text),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw Failure.invalidURL }
        return url
    }

    /// Rows as arrays keep their order; rows as objects share a sorted header of every key.
    static func csv(_ content: JSONValue) -> String {
        guard case .array(let rows) = content else { return text(content) }
        let objects = rows.compactMap { if case .object(let row) = $0 { row } else { nil } }
        var lines: [[JSONValue]] = []
        if !objects.isEmpty {
            let header = Set(objects.flatMap(\.keys)).sorted()
            lines.append(header.map(JSONValue.string))
            for row in rows {
                if case .object(let object) = row { lines.append(header.map { object[$0] ?? .null }) } else { lines.append(row.miniArray) }
            }
        } else {
            lines = rows.map { if case .array(let cells) = $0 { cells } else { [$0] } }
        }
        return lines.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + (lines.isEmpty ? "" : "\r\n")
    }

    private static func csvField(_ value: JSONValue) -> String {
        let field = text(value)
        guard field.contains(where: { [",", "\"", "\n", "\r"].contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Locale-independent, like JavaScript's `String(value)`: files read the same on every device.
    private static func text(_ value: JSONValue) -> String { MiniAppPublicAPI.queryText(value) }

    /// A single path component: no separators or control characters, no leading dot, at most 120 characters.
    static func filename(_ raw: String, fallback: String, defaultExtension: String?) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var name = raw.components(separatedBy: unsafe).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = fallback }
        if let defaultExtension, (name as NSString).pathExtension.isEmpty { name += ".\(defaultExtension)" }
        return name
    }
}
