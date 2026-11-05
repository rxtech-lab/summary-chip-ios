import Foundation
import LocalAgentKit

/// What a CLI would see in the user's terminal. Launchd gives services a bare environment, so
/// without this agents can't find `node`, or the credentials and proxies the user's profile sets.
actor UserEnvironment {
    static let shared = UserEnvironment()
    private static let marker = "__CHIPPY_ENV_START__"
    private static let extraDirectories = [
        ".local/bin", ".claude/local", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin",
    ]
    private static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private var cached: [String: String]?
    private var inFlight: Task<[String: String], Never>?

    func values() async -> [String: String] {
        if let cached { return cached }
        if let inFlight { return await inFlight.value }
        let task = Task.detached { Self.load() }
        inFlight = task
        let values = await task.value
        cached = values
        inFlight = nil
        return values
    }

    func install(of kind: LocalAgentKind) async -> LocalAgentInstall {
        let environment = await values()
        guard let path = Self.find(kind.executableName, in: environment) else {
            return LocalAgentInstall(kind: kind, path: nil, version: nil)
        }
        let output = await Task.detached {
            Self.capture(executable: path, arguments: ["--version"], environment: environment, timeout: 15)
        }.value
        let version = output.flatMap { String(decoding: $0, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init) }
        return LocalAgentInstall(kind: kind, path: path.path, version: version)
    }

    static func find(_ name: String, in environment: [String: String]) -> URL? {
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func load() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var values = ProcessInfo.processInfo.environment
        let shell = URL(filePath: loginShell())
        // Profiles can print anything, so only trust what follows the marker.
        if let data = capture(executable: shell, arguments: ["-ilc", "printf '\(marker)\\0'; /usr/bin/env -0"], environment: values, timeout: 10) {
            let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
            if let start = fields.lastIndex(where: { $0.hasSuffix(marker) }) {
                for field in fields[fields.index(after: start)...] {
                    guard let separator = field.firstIndex(of: "=") else { continue }
                    values[String(field[..<separator])] = String(field[field.index(after: separator)...])
                }
            }
        }
        values["HOME"] = home.path
        let existing = (values["PATH"] ?? "").split(separator: ":").map(String.init)
        let extras = extraDirectories.map { home.appending(path: $0).path } + systemDirectories
        var seen = Set<String>()
        values["PATH"] = (existing + extras).filter { seen.insert($0).inserted }.joined(separator: ":")
        return values
    }

    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// Stdout of a short-lived command, or nil if it failed or ran out of time.
    static func capture(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
