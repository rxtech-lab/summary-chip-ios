import CryptoKit
import Foundation
import LocalAgentKit

struct VoiceSetupError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Installs the speech runtime with uv and downloads the pinned model from Hugging Face.
struct VoiceInstaller: Sendable {
    /// The service runs outside the sandbox, so this is the user's real Application Support.
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Chippy/LocalVoice")
    }
    static var runtime: URL { root.appending(path: "runtime/\(LocalVoiceManifest.runtimeVersion)") }
    static var python: URL { runtime.appending(path: "bin/python") }
    /// The selected model always resolves to a downloaded folder outside the app.
    static var selectedModel: LocalVoiceModel? {
        if let id = UserDefaults.standard.string(forKey: "selectedVoiceModel") {
            return catalogue.first { $0.id == id }
        }
        return catalogue.first { isDownloaded($0) }
    }
    static var catalogue: [LocalVoiceModel] {
        var saved = (try? Data(contentsOf: root.appending(path: "models.json"))).flatMap { try? JSONDecoder().decode([LocalVoiceModel].self, from: $0) } ?? []
        // Discover older downloads from disk, without seeding a catalogue or default model.
        let folders = (try? FileManager.default.contentsOfDirectory(at: root.appending(path: "models"), includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = folder.lastPathComponent
            guard name.count > 41, !saved.contains(where: { $0.folderName == name }) else { continue }
            let revision = String(name.suffix(40))
            guard revision.allSatisfy({ $0.isHexDigit }), name.dropLast(40).last == "-" else { continue }
            let id = String(name.dropLast(41)).replacingOccurrences(of: "--", with: "/")
            let repo = id.contains("/") ? id : "mlx-community/\(id)"
            guard VoiceModelHub.validRepository(repo),
                  let configData = try? Data(contentsOf: folder.appending(path: "config.json")),
                  let config = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else { continue }
            let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
            let files = (entries?.allObjects as? [URL] ?? []).map { String($0.path.dropFirst(folder.path.count + 1)) }.filter(VoiceModelHub.isModelFile)
            let model = LocalVoiceModel(id: id, revision: revision, title: repo.components(separatedBy: "/").last!, modelFiles: files, family: config["model_type"] as? String ?? "unspecified")
            saved.append(model)
        }
        return saved
    }
    static func register(_ model: LocalVoiceModel) throws {
        var models = catalogue.filter { $0.id != model.id }
        models.append(model)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(models).write(to: root.appending(path: "models.json"), options: .atomic)
    }
    static func directory(for model: LocalVoiceModel) -> URL { root.appending(path: "models/\(model.folderName)") }
    static func isDownloaded(_ model: LocalVoiceModel) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: model).appending(path: ".chippy-ready").path)
    }
    private static var runtimeMarker: URL { runtime.appending(path: ".chippy-ready") }
    private static var runtimeMarkerContents: String { LocalVoiceManifest.requirements.joined(separator: "\n") }

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var isRuntimeReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && (try? String(contentsOf: runtimeMarker, encoding: .utf8)) == runtimeMarkerContents
    }

    static var isModelReady: Bool { selectedModel.map(isDownloaded) ?? false }
    static var isReady: Bool { isRuntimeReady && isModelReady }

    let model: LocalVoiceModel
    let progress: @Sendable (LocalVoiceSetupProgress) -> Void

    init(model: LocalVoiceModel, progress: @escaping @Sendable (LocalVoiceSetupProgress) -> Void) {
        self.model = model
        self.progress = progress
    }

    func prepare() async throws {
        guard Self.isAppleSilicon else { throw VoiceSetupError("The on-device voice needs a Mac with Apple silicon.") }
        if !Self.isRuntimeReady { try await installRuntime() }
        try Task.checkCancellation()
        if !Self.isDownloaded(model) { try await downloadModel() }
    }

    private func installRuntime() async throws {
        progress(.init(phase: .runtime, fraction: nil))
        let environment = await UserEnvironment.shared.values()
        guard let uv = UserEnvironment.find("uv", in: environment) else {
            throw VoiceSetupError("The on-device voice needs uv. Install it with “brew install uv”, then try again.")
        }
        try FileManager.default.createDirectory(at: Self.runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.isExecutableFile(atPath: Self.python.path) {
            try await run(uv, ["venv", "--python", "3.12", Self.runtime.path], environment: environment)
        }
        try await run(uv, ["pip", "install", "--python", Self.python.path] + LocalVoiceManifest.requirements, environment: environment)
        try Self.runtimeMarkerContents.write(to: Self.runtimeMarker, atomically: true, encoding: .utf8)
    }

    private func run(_ executable: URL, _ arguments: [String], environment: [String: String]) async throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().suffix(600), as: UTF8.self)
            throw VoiceSetupError("Setting up the on-device voice failed. \(detail)")
        }
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable { let oid: String }
        let path: String
        let size: Int64
        let lfs: LFS?
    }

    private func downloadModel() async throws {
        progress(.init(phase: .model, fraction: 0))
        var tree: [TreeEntry] = []
        var next: URL? = model.treeURL
        while let url = next {
            let (listing, response) = try await VoiceModelHub.fetch(url)
            tree += try JSONDecoder().decode([TreeEntry].self, from: listing)
            next = VoiceModelHub.nextPage(response)
        }
        let entries = try model.files.map { file in
            guard let entry = tree.first(where: { $0.path == file }) else {
                throw VoiceSetupError("The voice model is missing \(file).")
            }
            return entry
        }
        let total = entries.reduce(Int64(0)) { $0 + $1.size }
        var finished = Int64(0)
        for entry in entries {
            let destination = Self.directory(for: model).appending(path: entry.path)
            let base = finished
            if !isComplete(destination, entry: entry) {
                try await ModelFileDownload.fetch(model.downloadURL(for: entry.path), to: destination) { received in
                    progress(.init(phase: .model, fraction: Double(base + received) / Double(max(total, 1))))
                }
                guard isComplete(destination, entry: entry) else {
                    try? FileManager.default.removeItem(at: destination)
                    throw VoiceSetupError("\(entry.path) didn't download correctly. Please try again.")
                }
            }
            finished += entry.size
        }
        try Task.checkCancellation()
        try Data().write(to: Self.directory(for: model).appending(path: ".chippy-ready"))
    }

    private func isComplete(_ file: URL, entry: TreeEntry) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) == entry.size else { return false }
        guard let expected = entry.lfs?.oid else { return true }
        return Self.sha256(of: file) == expected
    }

    private static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Streams one file to disk, picking up from a partial file left by an earlier attempt.
private final class ModelFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let destination: URL
    private let onProgress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var failure: Error?
    private var lastReport = Date.distantPast

    private init(destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.partial = destination.appendingPathExtension("partial")
        self.onProgress = onProgress
    }

    static func fetch(_ url: URL, to destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let download = ModelFileDownload(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        // The URL names one fixed revision, so the bytes on disk are still the right prefix.
        download.received = (try? FileManager.default.attributesOfItem(atPath: download.partial.path)[.size] as? Int64) ?? 0
        if download.received > 0 { request.setValue("bytes=\(download.received)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.lock.withLock { download.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else {
                // 416 means the partial no longer fits, so the next attempt starts clean.
                if status == 416 { try? FileManager.default.removeItem(at: partial) }
                throw VoiceSetupError("The voice model download failed with HTTP \(status).")
            }
            if status == 200 {
                received = 0
                try Data().write(to: partial)
            }
            handle = try FileHandle(forWritingTo: partial)
            try handle?.seekToEnd()
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastReport) > 0.25 {
                lastReport = Date()
                onProgress(received)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        do {
            if (error as? URLError)?.code == .cancelled, failure == nil { throw CancellationError() }
            if let problem = failure ?? error { throw problem }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: partial, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
    }
}
