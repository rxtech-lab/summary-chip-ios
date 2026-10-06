import Foundation
import Observation
import RxAuthSwift
import SummaryKit

nonisolated enum AuthenticationPresentationState: Sendable, Equatable { case checking, signedOut, signedIn }

/// Something opened from outside the app: a shared summary link or "Open in app".
enum AppRoute: Identifiable, Hashable {
    case slug(String)
    case summaryID(String)
    /// A trip diary: `summarychip://trip/<id>` or a `tripId` push.
    case tripID(String)

    var id: String {
        switch self {
        case .slug(let slug): "slug:\(slug)"
        case .summaryID(let id): "id:\(id)"
        case .tripID(let id): "trip:\(id)"
        }
    }

    init?(url: URL, siteHost: String) {
        if let slug = SummaryLink.slug(from: url, siteHost: siteHost) {
            self = .slug(slug)
        } else if let id = SummaryLink.summaryID(from: url) {
            self = .summaryID(id)
        } else if let id = SummaryLink.tripID(from: url) {
            self = .tripID(id)
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
    let likes: LikesModel
    let credits = SummaryCreditsStore()
    var pendingTopUp = false
    private(set) var authenticationState: AuthenticationPresentationState
    var pendingRoute: AppRoute?
    /// An item from a link sheet to open in the main navigation (Library) once the sheet closes.
    var pendingLibraryItem: Summary?
    /// Text or link sent from another app through the macOS Services menu.
    var pendingServiceText: String?
    /// A file dropped on the window or opened with the app (Finder "Open With", the Dock icon).
    /// Replacing or clearing it discards a staged copy nobody will summarise.
    var pendingFile: DroppedSummaryFile? {
        didSet { if let oldValue, oldValue != pendingFile, !isHandingOffFile { oldValue.discard() } }
    }
    @ObservationIgnored private var isHandingOffFile = false

    init(configuration: SummaryConfiguration, authManager: OAuthManager, tokenBroker: SharedTokenBroker, authenticationState: AuthenticationPresentationState = .checking, session: URLSession = .shared) {
        self.configuration = configuration
        self.authManager = authManager
        self.tokenBroker = tokenBroker
        self.api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: tokenBroker, session: session)
        self.chatClient = ChatStreamClient(api: api)
        self.assetLoader = SummaryAssetLoader(tokenProvider: tokenBroker)
        let offline = OfflineSummaryStore()
        self.library = LibraryModel(api: api, offline: offline)
        self.likes = LikesModel(api: api, offline: offline)
        SummaryAssetLoader.retainImagesForOfflineUse()
        self.authenticationState = authenticationState
    }

    static func live() -> AppEnvironment {
        let configuration = SummaryConfiguration.live()
        return live(configuration: configuration, vault: SharedKeychainTokenVault(accessGroup: configuration.keychainAccessGroup))
    }

    /// `vault`, `session` and `authenticationState` are swapped for offline preview fixtures.
    static func live(
        configuration: SummaryConfiguration,
        vault: any SharedTokenVaultProtocol,
        session: URLSession = .shared,
        authenticationState: AuthenticationPresentationState = .checking
    ) -> AppEnvironment {
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
        return AppEnvironment(configuration: configuration, authManager: manager, tokenBroker: broker,
                              authenticationState: authenticationState, session: session)
    }

    func start() async {
        // Refresh through the extension-safe broker before RxAuth restores user info; the
        // injected storage hides the refresh token from OAuthManager's own timer.
        if (try? await tokenBroker.currentBundle()) != nil {
            _ = try? await tokenBroker.validAccessToken()
        }
        await authManager.checkExistingAuth()
        synchronizeAuthenticationState()
        if authenticationState == .signedIn {
            Task { await credits.refresh(api: api, broker: tokenBroker) }
            await SummaryNotifications.shared.synchronize()
        }
    }

    func authenticationCompleted() {
        synchronizeAuthenticationState()
        Task {
            await SummaryNotifications.shared.synchronize()
            await library.reload()
            await credits.refresh(api: api, broker: tokenBroker)
        }
    }

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            pendingFile = DroppedSummaryFile(url: url, isStagedCopy: false)
            return
        }
        if url.scheme == "summarychip", url.host() == "top-up" {
            pendingTopUp = true
            return
        }
        // The OAuth callback shares the custom scheme and is owned by RxAuthSwift.
        guard let route = AppRoute(url: url, siteHost: configuration.siteHost) else { return }
        pendingRoute = route
    }

    /// Hands the pending file to the caller, which presents it and owns it from then on.
    func takePendingFile() -> DroppedSummaryFile? {
        guard let file = pendingFile else { return nil }
        isHandingOffFile = true
        pendingFile = nil
        isHandingOffFile = false
        return file
    }

    /// Stars or unstars a summary, then updates it in the library and Likes. Returns the updated summary.
    func setLiked(_ summary: Summary, _ liked: Bool) async throws -> Summary {
        var updated = summary
        updated.likedAt = try await api.setLiked(id: summary.id, liked: liked)
        library.upsert(updated)
        likes.apply(updated)
        return updated
    }

    /// Stars or unstars a trip, which is known by id only while its diary is open. Returns the new date.
    func setTripLiked(id: String, _ liked: Bool) async throws -> Date? {
        let likedAt = try await api.setLiked(id: id, liked: liked)
        if let item = library.items.first(where: { $0.id == id }) {
            var updated = item
            updated.likedAt = likedAt
            library.upsert(updated)
        }
        if liked {
            Task { await likes.reload() }
        } else {
            likes.remove(id: id)
        }
        return likedAt
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
        authenticationState = .signedOut
        await SummaryNotifications.shared.signOut()
        try? await tokenBroker.logout()
        await authManager.logout()
        SharedLogoutPurger.purge()
        library.reset()
        likes.reset()
        credits.reset()
        pendingTopUp = false
        pendingRoute = nil
        pendingServiceText = nil
        pendingFile = nil
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
