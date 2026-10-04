#if os(macOS)
import Foundation
import Observation
import Security
import SummaryKit

/// Owns the Mac app's MCP server: whether it runs, its port and its access token. The server only
/// runs while the app is open and is reachable from this Mac only.
@Observable
final class MCPServerController {
    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    static let defaultPort = 47823
    static let portRange = 1024...65535
    private static let enabledKey = "mcp.enabled"
    private static let portKey = "mcp.port"

    private(set) var status: Status = .stopped
    private(set) var isEnabled: Bool
    private(set) var port: Int
    private(set) var token: String

    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private let tools: ChippyMCPTools
    @ObservationIgnored private let defaults: UserDefaults

    init(api: SummaryAPIClient, defaults: UserDefaults = .standard, onSummaryAdded: @escaping @MainActor @Sendable () async -> Void) {
        self.tools = ChippyMCPTools(api: api, onSummaryAdded: onSummaryAdded)
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        let storedPort = defaults.integer(forKey: Self.portKey)
        self.port = Self.portRange.contains(storedPort) ? storedPort : Self.defaultPort
        self.token = MCPAccessToken.load() ?? MCPAccessToken.create()
    }

    /// `http://127.0.0.1:<port>/mcp`
    var endpoint: String { "http://127.0.0.1:\(port)\(MCPHTTPServer.path)" }

    var isBusy: Bool { status == .starting }

    func startIfEnabled() async {
        guard isEnabled, server == nil, status != .starting else { return }
        await start()
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if enabled { await start() } else { await stop() }
    }

    func setPort(_ newPort: Int) async {
        guard Self.portRange.contains(newPort), newPort != port else { return }
        port = newPort
        defaults.set(newPort, forKey: Self.portKey)
        if isEnabled { await restart() }
    }

    /// Issues a new token; clients set up with the old one stop working.
    func regenerateToken() async {
        token = MCPAccessToken.create()
        if isEnabled { await restart() }
    }

    private func restart() async {
        await stop()
        await start()
    }

    private func start() async {
        guard server == nil else { return }
        status = .starting
        let server = MCPHTTPServer(token: token, tools: tools, version: SettingsView.version)
        do {
            try await server.start(port: port)
            self.server = server
            status = .running(port: port)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stop() async {
        await server?.stop()
        server = nil
        status = .stopped
    }
}

/// The bearer token MCP clients send, kept in the keychain.
enum MCPAccessToken {
    private static let service = "com.rxlab.summary-chip.mcp"
    private static let account = "access-token"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Generates, stores and returns a new token.
    static func create() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        let token = "chippy_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
        return token
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
#endif
