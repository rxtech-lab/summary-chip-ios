import Foundation
import Observation
import RxAuthSwift
import SummaryKit

nonisolated enum AuthenticationPresentationState: Sendable, Equatable { case checking, signedOut, signedIn }

/// Something opened from outside the app: a shared summary link or "Open in app".
enum AppRoute: Identifiable, Hashable {
    case slug(String)
    case summaryID(String)

    var id: String {
        switch self {
        case .slug(let slug): "slug:\(slug)"
        case .summaryID(let id): "id:\(id)"
        }
    }

    init?(url: URL, siteHost: String) {
        if let slug = SummaryLink.slug(from: url, siteHost: siteHost) {
            self = .slug(slug)
        } else if let id = SummaryLink.summaryID(from: url) {
            self = .summaryID(id)
        } else {
            return nil
        }
    }
}

@Observable
final class AppEnvironment {
    let configuration: SummaryConfiguration
    let authManager: OAuthManager
    let tokenBroker: SharedTokenBroker
    let api: SummaryAPIClient
    let chatClient: ChatStreamClient
    let chatStore = ChatTranscriptStore()
    let assetLoader: SummaryAssetLoader
    let library: LibraryModel
    private(set) var authenticationState: AuthenticationPresentationState
    var pendingRoute: AppRoute?

    init(configuration: SummaryConfiguration, authManager: OAuthManager, tokenBroker: SharedTokenBroker, authenticationState: AuthenticationPresentationState = .checking) {
        self.configuration = configuration
        self.authManager = authManager
        self.tokenBroker = tokenBroker
        self.api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: tokenBroker)
        self.chatClient = ChatStreamClient(api: api)
        self.assetLoader = SummaryAssetLoader(tokenProvider: tokenBroker)
        self.library = LibraryModel(api: api, offline: OfflineSummaryStore())
        SummaryAssetLoader.retainImagesForOfflineUse()
        self.authenticationState = authenticationState
    }

    static func live() -> AppEnvironment {
        let configuration = SummaryConfiguration.live()
        let vault = SharedKeychainTokenVault(accessGroup: configuration.keychainAccessGroup)
        let storage = RxAuthSharedTokenStorage(vault: vault)
        let manager = OAuthManager(
            configuration: RxAuthConfiguration(
                issuer: configuration.oauthIssuer.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                clientID: configuration.oauthClientID,
                redirectURI: configuration.oauthRedirectURI,
                // The client is only allowed `openid` and `write:profile` (same as sticker-gen);
                // `write:profile` lets the identity provider schedule or cancel account deletion.
                scopes: ["openid", "write:profile"],
                passkeyChallengePath: "/api/oauth/passkey/authenticate/options",
                passkeyVerificationPath: "/api/oauth/passkey/authenticate/verify",
                passkeyRegistrationChallengePath: "/api/oauth/passkey/register/options",
                passkeyRegistrationVerificationPath: "/api/oauth/passkey/register/verify",
                passkeyUpgradeChallengePath: "/api/oauth/passkey/upgrade/options",
                passkeyUpgradeVerificationPath: "/api/oauth/passkey/upgrade/verify",
                passkeyAccountCreationOptionsPath: "/api/oauth/passkey/account-creation/options",
                passkeyAccountCreationVerifyPath: "/api/oauth/passkey/account-creation/verify",
                passkeyRelyingPartyIdentifier: "rxlab.app",
                keychainServiceName: SummaryIdentifiers.keychainService
            ),
            tokenStorage: storage
        )
        let broker = SharedTokenBroker(
            vault: vault,
            tokenURL: configuration.oauthTokenURL,
            clientID: configuration.oauthClientID
        )
        return AppEnvironment(configuration: configuration, authManager: manager, tokenBroker: broker)
    }

    func start() async {
        // Refresh through the extension-safe broker before RxAuth restores user info; the
        // injected storage hides the refresh token from OAuthManager's own timer.
        if (try? await tokenBroker.currentBundle()) != nil {
            _ = try? await tokenBroker.validAccessToken()
        }
        await authManager.checkExistingAuth()
        synchronizeAuthenticationState()
    }

    func authenticationCompleted() {
        synchronizeAuthenticationState()
        Task { await library.reload() }
    }

    func handleIncomingURL(_ url: URL) {
        // The OAuth callback shares the custom scheme and is owned by RxAuthSwift.
        guard let route = AppRoute(url: url, siteHost: configuration.siteHost) else { return }
        pendingRoute = route
    }

    func sessionExpired() async {
        await signOut()
    }

    /// Bytes used by offline summaries and cached images.
    func cacheSize() async -> Int {
        await SummaryAssetLoader.imageCacheSize() + library.offline.fileSize
    }

    /// Drops offline summaries and cached images; the library re-fills them as it loads.
    func clearCache() {
        library.offline.clear()
        try? FileManager.default.removeItem(at: SharedImageCache.temporaryDirectory)
        SummaryAssetLoader.clearImageCache()
    }

    func signOut() async {
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        library.reset()
        pendingRoute = nil
        authenticationState = .signedOut
    }

    private func synchronizeAuthenticationState() {
        switch authManager.authState {
        case .unknown: authenticationState = .checking
        case .authenticated: authenticationState = .signedIn
        case .unauthenticated: authenticationState = .signedOut
        }
    }
}
