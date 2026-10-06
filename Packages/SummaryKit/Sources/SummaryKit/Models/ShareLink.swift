import Foundation

/// Who may open an extra share link.
public enum ShareLinkAccess: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Anyone holding the link, signed in or not.
    case anyone
    /// Only signed-in people whose email is on the link's list.
    case invited

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ShareLinkAccess(rawValue: raw) ?? .invited
    }

    public var title: String {
        switch self {
        case .anyone: String(localized: "Anyone with the link", bundle: .module, comment: "Share link access")
        case .invited: String(localized: "Only invited people", bundle: .module, comment: "Share link access")
        }
    }

    public var detail: String {
        switch self {
        case .anyone: String(localized: "No sign-in needed, even while the summary is private.", bundle: .module)
        case .invited: String(localized: "People sign in to Chippy with an email address you added.", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .anyone: "link"
        case .invited: "person.2.fill"
        }
    }
}

/// An extra link to a summary besides its own (`/api/v1/summaries/:id/links`), with its own
/// lifetime. It opens the summary even while the summary is private.
public struct SummaryShareLink: Codable, Sendable, Hashable, Identifiable {
    public struct Invitee: Codable, Sendable, Hashable, Identifiable {
        public var email: String
        public var addedAt: Date
        public var id: String { email }

        public init(email: String, addedAt: Date) {
            self.email = email
            self.addedAt = addedAt
        }
    }

    public var id: String
    public var url: URL
    public var label: String?
    public var access: ShareLinkAccess
    public var ttlDays: Int?
    public var expiresAt: Date?
    public var isExpired: Bool
    public var emails: [Invitee]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String, url: URL, label: String? = nil, access: ShareLinkAccess = .anyone, ttlDays: Int?, expiresAt: Date?,
        isExpired: Bool = false, emails: [Invitee] = [], createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.url = url
        self.label = label
        self.access = access
        self.ttlDays = ttlDays
        self.expiresAt = expiresAt
        self.isExpired = isExpired
        self.emails = emails
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The label, or a name made from the link's token.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return String(localized: "Link \(url.lastPathComponent.prefix(4).description)", bundle: .module, comment: "Unnamed share link; the argument is the start of its token")
    }
}

public struct ShareLinkList: Codable, Sendable, Hashable {
    public var items: [SummaryShareLink]
}

/// Body of `POST` (all fields) and `PATCH` (only set fields) for share links. `ttl = .never` sends
/// `null`; on `PATCH` a new `ttl` restarts the lifetime and `emails` replaces the invited list.
public struct ShareLinkChanges: Encodable, Sendable, Hashable {
    public var label: String?
    public var access: ShareLinkAccess?
    public var ttl: TTLOption?
    public var emails: [String]?

    public init(label: String? = nil, access: ShareLinkAccess? = nil, ttl: TTLOption? = nil, emails: [String]? = nil) {
        self.label = label
        self.access = access
        self.ttl = ttl
        self.emails = emails
    }

    private enum CodingKeys: String, CodingKey { case label, access, ttlDays, emails }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(access, forKey: .access)
        if let ttl {
            if let days = ttl.ttlDays { try c.encode(days, forKey: .ttlDays) } else { try c.encodeNil(forKey: .ttlDays) }
        }
        try c.encodeIfPresent(emails, forKey: .emails)
    }
}

public enum EmailAddress {
    /// A loose check (the server validates again); lowercased and trimmed when valid.
    public static func normalized(_ value: String) -> String? {
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard email.count <= 254, email.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil else { return nil }
        return email
    }
}
