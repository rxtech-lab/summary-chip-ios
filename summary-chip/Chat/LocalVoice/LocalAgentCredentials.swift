#if os(macOS)
import Foundation
import Security
import SummaryKit

/// The API key local agents use to reach the user's library through Chippy's MCP server.
/// It's a normal key, listed under Settings → MCP Server, and can be revoked there.
enum LocalAgentCredentials {
    private struct Stored: Codable {
        let id: String
        let key: String
    }

    private static let service = "com.rxlab.summary-chip.local-agent-key"

    /// Reuses the saved key while the signed-in account still lists it. A revoked key, or a
    /// different account signing in, gets a new one.
    static func token(api: SummaryAPIClient) async throws -> String {
        let account = api.baseURL.absoluteString
        let current = try await api.apiKeys()
        if let stored = load(account: account), current.contains(where: { $0.id == stored.id }) { return stored.key }
        let device = Host.current().localizedName ?? "Mac"
        let created = try await api.createAPIKey(name: String("Live Voice on \(device)".prefix(60)))
        save(Stored(id: created.apiKey.id, key: created.key), account: account)
        return created.key
    }

    private static func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func load(account: String) -> Stored? {
        var search = query(account: account)
        search[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func save(_ stored: Stored, account: String) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        let base = query(account: account)
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
#endif
