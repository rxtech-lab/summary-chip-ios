#if os(iOS) || os(macOS)
import SwiftUI

/// A shared summary as a card: OG image, title, two-line excerpt, category chip,
/// visibility + expiry, and a clearly visible date.
public struct SummaryCardView: View {
    public enum DateKind: Sendable, Hashable {
        case created
        case viewed
        case liked

        /// The card's date line: the formatted date, "Viewed <date>" for others' summaries, or "Liked <date>" in Likes.
        func label(_ formattedDate: String) -> String {
            switch self {
            case .created: formattedDate
            case .viewed: String(localized: "Viewed \(formattedDate)", bundle: .module)
            case .liked: String(localized: "Liked \(formattedDate)", bundle: .module, comment: "Card date line in Likes: when the summary was starred")
            }
        }

        var systemImage: String {
            switch self {
            case .created: "calendar"
            case .viewed: "eye"
            case .liked: "star"
            }
        }
    }

    let summary: Summary
    let date: Date
    let dateKind: DateKind
    let compact: Bool

    public init(summary: Summary, date: Date? = nil, dateKind: DateKind = .created, compact: Bool = false) {
        self.summary = summary
        self.date = date ?? summary.createdAt
        self.dateKind = dateKind
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryOGImage(summary: summary)
                .grayscale(summary.isExpired ? 1 : 0)
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                HStack(spacing: 6) {
                    if let badge = KindBadge(kind: summary.kind) {
                        badge
                    } else {
                        Text(summary.sourceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if summary.isExpired {
                        ExpiredBadge()
                    } else {
                        TranslationBadge(summary: summary)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Label(dateKind.label(SummaryDateFormatter.display(date)), systemImage: dateKind.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                Text(summary.title)
                    .font(compact ? .subheadline.weight(.semibold) : .headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !compact, summary.kind != .trip, !summary.summary.isEmpty {
                    Text(summary.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !compact {
                    HStack(spacing: 6) {
                        ChipLabel(summary.displayCategory, tint: summary.theme.accentColor)
                        if summary.isOwner {
                            VisibilityBadge(summary.visibility)
                        }
                        Spacer(minLength: 4)
                        if summary.isOwner && summary.visibility == .public {
                            ExpiryLabel(summary.expiresAt)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(compact ? 10 : 14)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }
}

/// Marks a starred summary whose link expired (or went private), so it can no longer be opened.
public struct ExpiredBadge: View {
    public init() {}

    public var body: some View {
        Label {
            Text("Expired", bundle: .module, comment: "Badge on a liked summary whose share link expired")
        } icon: {
            Image(systemName: "hourglass.bottomhalf.filled")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.red)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .accessibilityIdentifier("expired-badge")
    }
}

/// Marks a summary shown in another language than it was written in: the language it is read in
/// ("translate 日本語"), or a spinner while the translation is still being written. Empty otherwise.
public struct TranslationBadge: View {
    let summary: Summary

    public init(summary: Summary) {
        self.summary = summary
    }

    public var body: some View {
        if summary.translationPending {
            HStack(spacing: 3) {
                ProgressView().controlSize(.mini)
                Image(systemName: "translate").imageScale(.small)
            }
            .help(Text("Translating…", bundle: .module))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Translating", bundle: .module))
            .accessibilityIdentifier("translation-badge-pending")
        } else if summary.isTranslated {
            Label {
                Text(SummaryLanguage.displayName(for: summary.language)).lineLimit(1)
            } icon: {
                Image(systemName: "translate").imageScale(.small)
            }
            .labelStyle(.titleAndIcon)
            .help(Text("Translated from \(SummaryLanguage.displayName(for: summary.originalLanguage))", bundle: .module))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Translated to \(SummaryLanguage.displayName(for: summary.language))", bundle: .module))
            .accessibilityIdentifier("translation-badge")
        }
    }
}

/// Marks a library item that opens as a trip diary, podcast, paper, or Clip.
public struct KindBadge: View {
    let kind: SummaryKind

    /// Nil for kinds that open as a plain summary and carry no badge.
    public init?(kind: SummaryKind) {
        guard kind == .trip || kind == .podcast || kind == .paper || kind == .miniApp else { return nil }
        self.kind = kind
    }

    public var body: some View {
        Label {
            title
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint, in: Capsule())
        .lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier("\(kind.rawValue)-badge")
    }

    private var title: Text {
        switch kind {
        case .trip: Text("Trip", bundle: .module, comment: "Badge on a library tile that is a trip diary")
        case .podcast: Text("Podcast", bundle: .module)
        case .miniApp: Text("Clip", bundle: .module, comment: "Badge on a library tile that is a Clip")
        default: Text("Paper", bundle: .module, comment: "Badge on a library tile that is a LaTeX paper")
        }
    }

    private var systemImage: String {
        switch kind {
        case .trip: "map.fill"
        case .podcast: "waveform"
        case .miniApp: "app.badge.fill"
        default: "doc.richtext.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .trip: Color(red: 0.95, green: 0.5, blue: 0.35)
        case .miniApp: Color(red: 0.12, green: 0.55, blue: 0.48)
        default: Color(red: 0.36, green: 0.42, blue: 0.85)
        }
    }
}

/// One card in a feed: the summary plus the date the feed sorts by.
public struct SummaryFeedEntry: Identifiable, Hashable, Sendable {
    public var summary: Summary
    public var date: Date
    public var dateKind: SummaryCardView.DateKind
    public var id: String { summary.id }

    public init(summary: Summary, date: Date, dateKind: SummaryCardView.DateKind) {
        self.summary = summary
        self.date = date
        self.dateKind = dateKind
    }

    /// Library entry: dated by creation for your own summaries, by last view for others'.
    public init(summary: Summary) {
        self.init(summary: summary, date: summary.activityDate, dateKind: summary.viewedAt == nil ? .created : .viewed)
    }

    /// Likes entry: dated by when the summary was starred.
    public init(likedSummary summary: Summary) {
        self.init(summary: summary, date: summary.likedAt ?? summary.activityDate, dateKind: .liked)
    }
}

/// Home-feed tile: a soft white card with the date on top, a large bold title, and either the
/// excerpt, the generated image inset below the title, or the image full-bleed behind the title.
/// Theme artwork stands in while the image loads or when there is none.
public struct SummaryTileView: View {
    public enum Style: Sendable, Hashable {
        case text
        case inset
        case hero

        /// Stable per summary so a card keeps its look across launches and reloads. Trips and papers
        /// always show their cover, with the title laid over it.
        public static func style(for summary: Summary) -> Style {
            let hash = summary.id.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
            if summary.kind == .trip || summary.kind == .paper { return .hero }
            switch hash % 5 {
            case 0, 1: return summary.summary.isEmpty ? .inset : .text
            case 2, 3: return .inset
            default: return .hero
            }
        }

        /// Rough height relative to column width, used to balance masonry columns.
        func estimatedHeight(title: String) -> CGFloat {
            let titleLines = CGFloat(min(4, max(1, title.count / 14 + 1))) * 0.17
            switch self {
            case .text: return 0.3 + titleLines + 0.6
            case .inset: return 0.3 + titleLines + 0.85
            case .hero: return 1.25
            }
        }
    }

    static let cornerRadius: CGFloat = 30
    private static let insetMargin: CGFloat = 10

    let summary: Summary
    let date: Date
    let dateKind: SummaryCardView.DateKind
    let style: Style
    let isEditorsPick: Bool

    public init(summary: Summary, date: Date? = nil, dateKind: SummaryCardView.DateKind = .created, style: Style? = nil, isEditorsPick: Bool = false) {
        self.summary = summary
        self.date = date ?? summary.createdAt
        self.dateKind = dateKind
        self.style = style ?? .style(for: summary)
        self.isEditorsPick = isEditorsPick
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
    }

    public var body: some View {
        Group {
            switch style {
            case .text, .inset: standard
            case .hero: hero
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.summaryCardBackground, in: shape)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isEditorsPick ? Color.orange : Color.primary.opacity(0.06), lineWidth: isEditorsPick ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(dateKind.label(stamp)))
        .transition(.identity)
        .transaction {
            $0.animation = nil
            $0.disablesAnimations = true
        }
    }

    private var stamp: String { SummaryDateFormatter.tile(date) }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(ink: .primary, secondary: .secondary)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, style == .text ? 20 : 12)
            if style == .inset {
                Color.clear
                    .aspectRatio(1.1, contentMode: .fit)
                    .overlay { artwork }
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius - Self.insetMargin, style: .continuous))
                    .padding([.horizontal, .bottom], Self.insetMargin)
            }
        }
    }

    private var hero: some View {
        let scrim: Color = summary.theme.mode == .dark ? .black : .white
        let ink = summary.theme.foreground
        return Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .background { artwork }
            // Blur behind the title only: the generated image often carries its own text,
            // which clashes with ours. Sized to the header, with a short fade below it.
            .overlay {
                ZStack {
                    artwork
                        .blur(radius: 18, opaque: true)
                    scrim.opacity(summary.theme.mode == .dark ? 0.4 : 0.5)
                }
                .mask { headerMask(ink: ink) }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                header(ink: ink, secondary: ink.opacity(0.8))
                    .shadow(color: .black.opacity(summary.theme.mode == .dark ? 0.25 : 0), radius: 3)
                    .padding(18)
            }
    }

    /// Opaque region matching the hero header's laid-out height, fading out just below it.
    private func headerMask(ink: Color) -> some View {
        VStack(spacing: 0) {
            header(ink: ink, secondary: ink)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .background(Color.black)
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 28)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var artwork: some View {
        SummaryRemoteImage(url: summary.tileImageUrl, authorized: summary.isOwner) {
            ThemeArtwork(theme: summary.theme)
        }
    }

    private var editorsPickBadge: some View {
        Label(String(localized: "Editor’s Pick", bundle: .module), systemImage: "star.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.yellow, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("summary-editors-pick")
    }

    private func header(ink: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditorsPick {
                editorsPickBadge
            }
            HStack(spacing: 4) {
                if let badge = KindBadge(kind: summary.kind) {
                    badge
                        .padding(.trailing, 4)
                }
                if dateKind == .viewed {
                    Image(systemName: "eye.fill").imageScale(.small)
                } else if dateKind == .liked {
                    Image(systemName: "star.fill").imageScale(.small)
                }
                Text(stamp).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
                TranslationBadge(summary: summary)
                    .padding(.leading, 4)
                if summary.kind == .summary {
                    Spacer(minLength: 6)
                    Label {
                        Text(summary.sourceLabel)
                            .truncationMode(.tail)
                    } icon: {
                        summary.source.image
                            .imageScale(.small)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .help(summary.sourceLabel)
                    .accessibilityIdentifier("summary-tile-source")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(secondary)

            Text(summary.title)
                .font(.title2.weight(.bold))
                .kerning(-0.6)
                .foregroundStyle(ink)
                .lineLimit(4)
                .minimumScaleFactor(0.85)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if style == .text {
                Text(summary.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 6)
            }
        }
    }
}

/// Coordinate space of the feed's scroll content, used to place cards on the timeline.
#endif
