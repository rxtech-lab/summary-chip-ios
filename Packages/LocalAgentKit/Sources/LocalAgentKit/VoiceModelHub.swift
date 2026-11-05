import Foundation

public struct VoiceHubResult: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let downloads: Int?
    public let likes: Int?
}

public struct VoiceHubPage: Sendable {
    public let models: [VoiceHubResult]
    public let next: URL?
}

public enum VoiceModelHub {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
    public static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }
    }
    public static func safeFile(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public static func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        guard url.scheme == "https", url.host == "huggingface.co" else { throw Failure("Invalid Hugging Face URL.") }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw Failure("Invalid server response.") }
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 { throw Failure("This model is private or gated. Choose a public model; Hugging Face sign-in isn't available here yet.") }
            throw Failure("Hugging Face returned HTTP \(response.statusCode). Please try again.")
        }
        return (data, response)
    }
    public static func search(_ query: String, next: URL? = nil) async throws -> VoiceHubPage {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            .init(name: "filter", value: "mlx"), .init(name: "pipeline_tag", value: "text-to-speech"),
            .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"),
            .init(name: "limit", value: "30"), .init(name: "search", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        let (data, response) = try await fetch(next ?? components.url!)
        let models = try JSONDecoder().decode([VoiceHubResult].self, from: data)
        return VoiceHubPage(models: models, next: nextPage(response))
    }
    public static func nextPage(_ response: HTTPURLResponse) -> URL? {
        for part in (response.value(forHTTPHeaderField: "Link") ?? "").split(separator: ",") where part.contains("rel=\"next\"") {
            guard let start = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), start < end else { continue }
            let url = URL(string: String(part[part.index(after: start)..<end]))
            if url?.host == "huggingface.co", url?.scheme == "https" { return url }
        }
        return nil
    }
    public static func readme(_ repository: String, revision: String = "main") async throws -> String {
        guard validRepository(repository), revision.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw Failure("Invalid model repository.") }
        let (data, _) = try await fetch(URL(string: "https://huggingface.co/\(repository)/raw/\(revision)/README.md")!)
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
    /// Download model data, not repository scripts, demos, or sample recordings.
    public static func isModelFile(_ path: String) -> Bool {
        guard safeFile(path), !path.hasPrefix("samples/"), !path.hasPrefix("examples/") else { return false }
        return ["json", "safetensors", "txt", "model", "tiktoken", "vocab", "merges", "yaml", "yml", "onnx", "npy", "npz"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    public static func resolve(_ repository: String, revision: String? = nil) async throws -> LocalVoiceModel {
        guard validRepository(repository) else { throw Failure("Enter a Hugging Face repository as owner/model.") }
        struct Info: Decodable { let sha: String }
        let pinned: String
        if let revision { pinned = revision } else {
            let (data, _) = try await fetch(URL(string: "https://huggingface.co/api/models/\(repository)")!)
            pinned = try JSONDecoder().decode(Info.self, from: data).sha
        }
        guard pinned.count == 40, pinned.allSatisfy({ $0.isHexDigit }) else { throw Failure("The model revision is invalid.") }
        let (configData, _) = try await fetch(URL(string: "https://huggingface.co/\(repository)/resolve/\(pinned)/config.json")!)
        let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any] ?? [:]
        let type = config["model_type"] as? String ?? ""
        let family = type.isEmpty ? "unspecified" : type
        struct Entry: Decodable { let type: String; let path: String; let size: Int64? }
        var entries: [Entry] = []
        var next: URL? = URL(string: "https://huggingface.co/api/models/\(repository)/tree/\(pinned)?recursive=true")!
        while let url = next {
            let (data, response) = try await fetch(url)
            entries += try JSONDecoder().decode([Entry].self, from: data)
            next = nextPage(response)
        }
        let files = entries.filter { $0.type == "file" && isModelFile($0.path) }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw Failure("This repository has no MLX safetensors weights.")
        }
        guard files.allSatisfy({ safeFile($0.path) }) else { throw Failure("The repository contains an unsafe file path.") }
        return LocalVoiceModel(id: repository, revision: pinned, title: repository.components(separatedBy: "/").last!,
                               modelFiles: files.map(\.path), sizeBytes: files.reduce(0) { $0 + ($1.size ?? 0) }, family: family,
                               presetVoices: VoiceCatalog.presetVoices(files: files.map(\.path), config: config))
    }
}
