import Foundation

/// Identifiers shared by every target (see docs/ARCHITECTURE.md → Identifiers).
public enum SummaryIdentifiers {
    public static let appName = "Chippy"
    public static let appBundleID = "com.rxlab.summary-chip"
    public static let appGroupIdentifier = "group.com.rxlab.summary-chip"
    public static let keychainService = "com.rxlab.summary-chip.oauth"
    public static let keychainAccount = "oauth-token-bundle"
    public static let refreshLockFilename = "oauth-refresh.lock"
    public static let urlScheme = "summarychip"
    public static let defaultSiteHost = "summary.rxlab.app"
}

/// Info.plist keys every target exposes (values come from Configuration/*.xcconfig).
public enum SummaryInfoKey {
    public static let apiBaseURL = "SummaryChipAPIBaseURL"
    public static let siteHost = "SummaryChipSiteHost"
    public static let clientID = "SummaryChipIOSClientID"
    public static let oauthIssuer = "SummaryChipOAuthIssuer"
    public static let redirectURI = "SummaryChipOAuthRedirectURI"
    public static let tokenURL = "SummaryChipAuthTokenURL"
    public static let keychainAccessGroup = "SummaryChipKeychainAccessGroup"
}

/// Runtime configuration read from the bundle's Info.plist.
public struct SummaryConfiguration: Sendable, Hashable {
    public var apiBaseURL: URL
    public var siteHost: String
    public var oauthClientID: String
    public var oauthIssuer: URL
    public var oauthRedirectURI: String
    public var oauthTokenURL: URL
    public var keychainAccessGroup: String?

    public init(
        apiBaseURL: URL,
        siteHost: String = SummaryIdentifiers.defaultSiteHost,
        oauthClientID: String = "client_REPLACE_ME",
        oauthIssuer: URL = URL(string: "https://auth.rxlab.app")!,
        oauthRedirectURI: String = "summarychip://oauth/callback",
        oauthTokenURL: URL = URL(string: "https://auth.rxlab.app/api/oauth/token")!,
        keychainAccessGroup: String? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.siteHost = siteHost
        self.oauthClientID = oauthClientID
        self.oauthIssuer = oauthIssuer
        self.oauthRedirectURI = oauthRedirectURI
        self.oauthTokenURL = oauthTokenURL
        self.keychainAccessGroup = keychainAccessGroup
    }

    #if DEBUG
    static let defaultAPIBaseURL = "http://localhost:3000"
    #else
    static let defaultAPIBaseURL = "https://summary.rxlab.app"
    #endif

    public static func live(bundle: Bundle = .main) -> SummaryConfiguration {
        SummaryConfiguration(
            apiBaseURL: URL(string: value(SummaryInfoKey.apiBaseURL, bundle) ?? defaultAPIBaseURL)!,
            siteHost: value(SummaryInfoKey.siteHost, bundle) ?? SummaryIdentifiers.defaultSiteHost,
            oauthClientID: value(SummaryInfoKey.clientID, bundle) ?? "client_REPLACE_ME",
            oauthIssuer: URL(string: value(SummaryInfoKey.oauthIssuer, bundle) ?? "https://auth.rxlab.app")!,
            oauthRedirectURI: value(SummaryInfoKey.redirectURI, bundle) ?? "summarychip://oauth/callback",
            oauthTokenURL: URL(string: value(SummaryInfoKey.tokenURL, bundle) ?? "https://auth.rxlab.app/api/oauth/token")!,
            keychainAccessGroup: value(SummaryInfoKey.keychainAccessGroup, bundle)
        )
    }

    /// Returns the Info.plist string, or `nil` when missing, empty, or an unexpanded `$(…)`.
    public static func value(_ key: String, _ bundle: Bundle) -> String? {
        sanitized(bundle.object(forInfoDictionaryKey: key) as? String)
    }

    public static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }

    /// Whether the placeholder client id is still configured.
    public var needsClientRegistration: Bool { oauthClientID.contains("REPLACE_ME") }
}

/// Parses public summary links: `https://<site host>/s/<slug>` and `summarychip://s/<slug>`.
public enum SummaryLink {
    public static func slug(from url: URL, siteHost: String? = nil) -> String? {
        if url.scheme == SummaryIdentifiers.urlScheme {
            // summarychip://s/<slug>
            guard url.host() == "s" else { return nil }
            let parts = url.pathComponents.filter { $0 != "/" }
            return parts.first.flatMap(validSlug)
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if let siteHost, let host = url.host()?.lowercased(),
           host != siteHost.lowercased(), host != "localhost", !host.hasPrefix("127.") {
            return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "s" else { return nil }
        // /s/<slug>, but not /s/<slug>/og.png or /s/<slug>/source
        guard parts.count == 2 else { return nil }
        return validSlug(parts[1])
    }

    /// `summarychip://summary/<id>`, used by extensions' "Open in app".
    public static func summaryID(from url: URL) -> String? {
        guard url.scheme == SummaryIdentifiers.urlScheme, url.host() == "summary" else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first
    }

    public static func openInAppURL(summaryID: String) -> URL {
        URL(string: "\(SummaryIdentifiers.urlScheme)://summary/\(summaryID)")!
    }

    /// `summarychip://trip/<id>`: opens a trip diary (the share extension's "Open in Chippy").
    public static func tripID(from url: URL) -> String? {
        guard url.scheme == SummaryIdentifiers.urlScheme, url.host() == "trip" else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first
    }

    public static func openTripURL(tripID: String) -> URL {
        URL(string: "\(SummaryIdentifiers.urlScheme)://trip/\(tripID)")!
    }

    private static func validSlug(_ value: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }
}
