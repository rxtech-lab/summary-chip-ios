import Foundation

public struct OAuthRefreshResponse: Decodable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var expiresIn: TimeInterval

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        idToken = try c.decodeIfPresent(String.self, forKey: .idToken)
        expiresIn = try c.decodeIfPresent(TimeInterval.self, forKey: .expiresIn) ?? 3600
    }
}

public protocol OAuthRefreshTransport: Sendable {
    func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse
}

public struct URLSessionOAuthRefreshTransport: OAuthRefreshTransport {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func refresh(tokenURL: URL, clientID: String, refreshToken: String) async throws -> OAuthRefreshResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        // Bounds how long the shared refresh lock can be held.
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TokenBrokerError.transientRefresh(nil) }
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 {
                throw TokenBrokerError.refreshRejected(response.statusCode)
            }
            throw TokenBrokerError.transientRefresh(response.statusCode)
        }
        return try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
    }
}

public enum TokenBrokerError: Error, LocalizedError, Equatable {
    case missingSession
    case refreshRejected(Int?)
    case transientRefresh(Int?)
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingSession: String(localized: "Please open \(SummaryIdentifiers.appName) and sign in.", bundle: .module)
        case .refreshRejected: String(localized: "Your session expired. Please sign in again.", bundle: .module)
        case .transientRefresh: String(localized: "The authentication service is temporarily unavailable.", bundle: .module)
        case .lockUnavailable: String(localized: "The shared session is temporarily unavailable.", bundle: .module)
        }
    }
}

/// Supplies bearer tokens to the API clients.
public protocol AccessTokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

public extension Notification.Name {
    /// Same name RxAuthSwift uses (`.rxAuthSessionExpired`), so the app reacts to either source.
    static let summarySessionExpired = Notification.Name("rxAuthSessionExpired")
}

/// Refreshes the shared token bundle. Used by the app, the share extension and the iMessage
/// extension; a cross-process `flock` in the App Group container makes sure only one process
/// rotates the refresh token at a time.
public actor SharedTokenBroker: AccessTokenProvider {
    private let vault: any SharedTokenVaultProtocol
    private let transport: any OAuthRefreshTransport
    private let tokenURL: URL
    private let clientID: String
    private let lockURL: URL?
    private let expiryLeeway: TimeInterval
    private var refreshTask: Task<String, any Error>?
    private var isLoggingOut = false
    private var sessionEpoch: UInt64 = 0

    public init(
        vault: any SharedTokenVaultProtocol,
        transport: any OAuthRefreshTransport = URLSessionOAuthRefreshTransport(),
        tokenURL: URL,
        clientID: String,
        lockURL: URL? = SharedTokenBroker.defaultLockURL(),
        expiryLeeway: TimeInterval = 90
    ) {
        self.vault = vault
        self.transport = transport
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.lockURL = lockURL
        self.expiryLeeway = expiryLeeway
    }

    /// Convenience for extensions: everything from the bundle's Info.plist.
    public static func live(configuration: SummaryConfiguration = .live()) -> SharedTokenBroker {
        SharedTokenBroker(
            vault: SharedKeychainTokenVault(accessGroup: configuration.keychainAccessGroup),
            tokenURL: configuration.oauthTokenURL,
            clientID: configuration.oauthClientID
        )
    }

    public nonisolated func accessToken(forceRefresh: Bool) async throws -> String {
        try await validAccessToken(forceRefresh: forceRefresh)
    }

    public func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard !isLoggingOut else { throw TokenBrokerError.missingSession }
        let startingEpoch = sessionEpoch
        if !forceRefresh, let bundle = try vault.load(), !bundle.accessToken.isEmpty, !bundle.expires(within: expiryLeeway) {
            return bundle.accessToken
        }
        if let refreshTask {
            let token = try await refreshTask.value
            guard !isLoggingOut, sessionEpoch == startingEpoch else { throw TokenBrokerError.missingSession }
            return token
        }

        // Run the cross-process critical section outside actor isolation so a second caller
        // can await `refreshTask` instead of blocking the actor on flock.
        let vault = self.vault
        let transport = self.transport
        let tokenURL = self.tokenURL
        let clientID = self.clientID
        guard let lockURL = self.lockURL else { throw TokenBrokerError.lockUnavailable }
        let expiryLeeway = self.expiryLeeway
        let task = Task.detached(priority: nil) { () async throws -> String in
            let processLock = try AppGroupProcessLock(url: lockURL, unavailableError: TokenBrokerError.lockUnavailable)
            try processLock.lock()
            defer { processLock.unlock() }

            // Another process may have rotated while this one waited.
            if !forceRefresh, let current = try vault.load(), !current.accessToken.isEmpty, !current.expires(within: expiryLeeway) {
                return current.accessToken
            }
            guard let current = try vault.load(), let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
                throw TokenBrokerError.missingSession
            }
            do {
                let response = try await transport.refresh(tokenURL: tokenURL, clientID: clientID, refreshToken: refreshToken)
                let replacement = SharedTokenBundle(
                    accessToken: response.accessToken,
                    refreshToken: response.refreshToken ?? current.refreshToken,
                    idToken: response.idToken ?? current.idToken,
                    expiresAt: Date().addingTimeInterval(max(30, response.expiresIn)),
                    subject: JWTClaims.subject(in: response.accessToken) ?? current.subject
                )
                try processLock.ensureHeld()
                try vault.replace(with: replacement)
                return replacement.accessToken
            } catch {
                if case TokenBrokerError.refreshRejected = error {
                    try? vault.clear()
                    NotificationCenter.default.post(name: .summarySessionExpired, object: nil)
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        let token = try await task.value
        guard !isLoggingOut, sessionEpoch == startingEpoch else { throw TokenBrokerError.missingSession }
        return token
    }

    public func currentBundle() throws -> SharedTokenBundle? { try vault.load() }

    /// Whether a session exists that can yield an access token (used for signed-out states).
    public func hasSession() -> Bool {
        (try? vault.load())?.hasSession ?? false
    }

    public func logout() async throws {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        sessionEpoch &+= 1
        defer { isLoggingOut = false }
        if let refreshTask { _ = try? await refreshTask.value }
        guard let lockURL else { throw TokenBrokerError.lockUnavailable }
        let vault = self.vault
        try await Task.detached {
            let lock = try AppGroupProcessLock(url: lockURL, unavailableError: TokenBrokerError.lockUnavailable)
            try lock.lock()
            defer { lock.unlock() }
            // Re-read under the lock so an extension refresh that started before logout
            // cannot resurrect credentials.
            _ = try vault.load()
            try vault.clear()
        }.value
    }

    public static func defaultLockURL(fileManager: FileManager = .default) -> URL? {
        lockURL(
            containerURL: fileManager.containerURL(forSecurityApplicationGroupIdentifier: SummaryIdentifiers.appGroupIdentifier),
            temporaryDirectory: fileManager.temporaryDirectory,
            allowTemporaryFallback: SharedKeychainTokenVault.defaultAllowsFallback
        )
    }

    public static func lockURL(containerURL: URL?, temporaryDirectory: URL, allowTemporaryFallback: Bool) -> URL? {
        if let containerURL { return containerURL.appending(path: SummaryIdentifiers.refreshLockFilename) }
        guard allowTemporaryFallback else { return nil }
        return temporaryDirectory.appending(path: "summary-chip-\(SummaryIdentifiers.refreshLockFilename)")
    }
}

/// A fixed token, for previews and tests.
public struct StaticTokenProvider: AccessTokenProvider {
    public let token: String
    public init(token: String) { self.token = token }
    public func accessToken(forceRefresh: Bool) async throws -> String { token }
}
