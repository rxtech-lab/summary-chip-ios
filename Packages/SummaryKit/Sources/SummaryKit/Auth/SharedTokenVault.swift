import Foundation
import Security

/// The one OAuth token bundle every Summary Chip process shares via the keychain access group.
public struct SharedTokenBundle: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresAt: Date
    public var subject: String?

    public init(accessToken: String, refreshToken: String?, idToken: String?, expiresAt: Date, subject: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresAt = expiresAt
        self.subject = subject
    }

    public var isUsable: Bool { !accessToken.isEmpty && expiresAt > Date() }

    /// True when the bundle can produce an access token (directly or by refreshing).
    public var hasSession: Bool { isUsable || !(refreshToken ?? "").isEmpty }

    public func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expiresAt <= now.addingTimeInterval(interval)
    }
}

public protocol SharedTokenVaultProtocol: Sendable {
    func load() throws -> SharedTokenBundle?
    func replace(with bundle: SharedTokenBundle) throws
    func clear() throws
}

public enum TokenVaultError: Error, LocalizedError {
    case keychain(OSStatus)
    case invalidPayload
    case missingSharedAccessGroup

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "The secure token store failed (\(status))."
        case .invalidPayload: "The secure token bundle is invalid."
        case .missingSharedAccessGroup: "The shared Keychain access group is not configured."
        }
    }
}

public final class SharedKeychainTokenVault: SharedTokenVaultProtocol, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?
    private let allowUnsharedFallback: Bool
    private let lock = NSLock()
    /// Set after the shared group proved unavailable (unsigned simulator builds): the vault then
    /// keeps working as a per-process item so development is not blocked.
    private var usesFallback = false

    public init(
        service: String = SummaryIdentifiers.keychainService,
        account: String = SummaryIdentifiers.keychainAccount,
        accessGroup: String? = SummaryConfiguration.value(SummaryInfoKey.keychainAccessGroup, .main),
        allowUnsharedFallback: Bool = SharedKeychainTokenVault.defaultAllowsFallback
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.allowUnsharedFallback = allowUnsharedFallback
    }

    public static var defaultAllowsFallback: Bool {
        #if targetEnvironment(simulator) || os(macOS)
        true
        #else
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        #endif
    }

    public func load() throws -> SharedTokenBundle? {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        return try withFallback { try loadUnlocked() }
    }

    public func replace(with bundle: SharedTokenBundle) throws {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        try withFallback { try replaceUnlocked(with: bundle) }
    }

    public func clear() throws {
        try validateConfiguration()
        lock.lock()
        defer { lock.unlock() }
        try withFallback {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenVaultError.keychain(status)
            }
        }
    }

    private func withFallback<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch TokenVaultError.keychain(let status) where status == errSecMissingEntitlement && allowUnsharedFallback && !usesFallback {
            usesFallback = true
            return try body()
        }
    }

    private func loadUnlocked() throws -> SharedTokenBundle? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TokenVaultError.keychain(status)
        }
        return try TokenBundleCodec.decode(data)
    }

    private func replaceUnlocked(with bundle: SharedTokenBundle) throws {
        let data = try TokenBundleCodec.encode(bundle)
        let query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = data
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let insertionStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard insertionStatus == errSecSuccess else { throw TokenVaultError.keychain(insertionStatus) }
        } else if updateStatus != errSecSuccess {
            throw TokenVaultError.keychain(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup, !usesFallback { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func validateConfiguration() throws {
        guard accessGroup != nil || allowUnsharedFallback else {
            throw TokenVaultError.missingSharedAccessGroup
        }
    }
}

/// In-memory vault for tests and previews.
public final class InMemoryTokenVault: SharedTokenVaultProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var bundle: SharedTokenBundle?

    public init(_ bundle: SharedTokenBundle? = nil) { self.bundle = bundle }

    public func load() throws -> SharedTokenBundle? { lock.withLock { bundle } }
    public func replace(with bundle: SharedTokenBundle) throws { lock.withLock { self.bundle = bundle } }
    public func clear() throws { lock.withLock { bundle = nil } }
}

public enum TokenBundleCodec {
    public static func encode(_ bundle: SharedTokenBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(bundle)
    }

    public static func decode(_ data: Data) throws -> SharedTokenBundle {
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = SummaryJSON.parseISO8601(value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expiresAt is not ISO-8601")
        }
        if let decoded = try? isoDecoder.decode(SharedTokenBundle.self, from: data) { return decoded }

        let secondsDecoder = JSONDecoder()
        secondsDecoder.dateDecodingStrategy = .secondsSince1970
        if let decoded = try? secondsDecoder.decode(SharedTokenBundle.self, from: data) { return decoded }
        throw TokenVaultError.invalidPayload
    }
}

public enum JWTClaims {
    public static func subject(in token: String) -> String? {
        payload(in: token)?["sub"] as? String
    }

    public static func expiration(in token: String) -> Date? {
        guard let seconds = payload(in: token)?["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func payload(in token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
