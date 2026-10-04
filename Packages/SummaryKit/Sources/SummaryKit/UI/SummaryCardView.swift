#if os(iOS) || os(macOS)
import SwiftUI

/// A shared summary as a card: OG image, title, two-line excerpt, category chip,
/// visibility + expiry, and a clearly visible date.
public struct SummaryCardView: View {
    public enum DateKind: Sendable, Hashable {
        case created
        case viewed

        /// The card's date line: the formatted date, or "Viewed <date>" for others' summaries.
        func label(_ formattedDate: String) -> String {
            switch self {
            case .created: formattedDate
            case .viewed: String(localized: "Viewed \(formattedDate)", bundle: .module)
            }
        }

        var systemImage: String {
            switch self {
            case .created: "calendar"
            case .viewed: "eye"
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
            VStack(alignment: .leading, spacing: compact ? 6 : 10) {
                HStack(spacing: 6) {
                    Text(summary.sourceLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TranslationBadge(summary: summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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
                if !compact, !summary.summary.isEmpty {
                    Text(summary.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if !compact {
                    HStack(spacing: 6) {
                        ChipLabel(summary.category, tint: summary.theme.accentColor)
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
}

/// Home-feed tile: a soft white card with the date on top, a large bold title, and either the
/// excerpt, the generated image inset below the title, or the image full-bleed behind the title.
/// Theme artwork stands in while the image loads or when there is none.
public struct SummaryTileView: View {
    public enum Style: Sendable, Hashable {
        case text
        case inset
        case hero

        /// Stable per summary so a card keeps its look across launches and reloads.
        public static func style(for summary: Summary) -> Style {
            let hash = summary.id.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
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

    public init(summary: Summary, date: Date? = nil, dateKind: SummaryCardView.DateKind = .created, style: Style? = nil) {
        self.summary = summary
        self.date = date ?? summary.createdAt
        self.dateKind = dateKind
        self.style = style ?? .style(for: summary)
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
        .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(dateKind.label(stamp)))
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
            // Progressive blur behind the title: the generated image often carries its own
            // text, which clashes with ours. Fades out towards the bottom.
            .overlay {
                artwork
                    .blur(radius: 18, opaque: true)
                    .mask {
                        LinearGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 0.8)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: scrim.opacity(summary.theme.mode == .dark ? 0.5 : 0.6), location: 0),
                        .init(color: scrim.opacity(summary.theme.mode == .dark ? 0.3 : 0.4), location: 0.5),
                        .init(color: scrim.opacity(0), location: 0.8),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .topLeading) {
                header(ink: ink, secondary: ink.opacity(0.8))
                    .shadow(color: .black.opacity(summary.theme.mode == .dark ? 0.25 : 0), radius: 3)
                    .padding(18)
            }
    }

    private var artwork: some View {
        SummaryRemoteImage(url: summary.tileImageUrl, authorized: summary.isOwner) {
            ThemeArtwork(theme: summary.theme)
        }
    }

    private func header(ink: Color, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if dateKind == .viewed {
                    Image(systemName: "eye.fill").imageScale(.small)
                }
                Text(stamp).lineLimit(1)
                    .accessibilityHidden(true)
                TranslationBadge(summary: summary)
                    .padding(.leading, 4)
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
private let summaryFeedContentSpace = "summary-feed-content"

/// Scrolling masonry feed of `SummaryTileView`s, newest first. Two columns on compact widths,
/// three on regular (iPad). Cards push `Summary` values; register
/// `.navigationDestination(for: Summary.self)` on the enclosing stack, or pass `onSelect` to
/// handle taps yourself. `menuItems` builds each
/// card's long-press context menu. `showsDateHeaders` groups cards by their local activity day.
/// With `showsTimeline`, macOS adds a date scrubber beside the feed;
/// use it only for feeds sorted newest first.
public struct SummaryCardFeed<Footer: View, MenuItems: View>: View {
    let entries: [SummaryFeedEntry]
    let onReachEnd: () -> Void
    let menuItems: (Summary) -> MenuItems
    let footer: Footer
    let showsTimeline: Bool
    let showsDateHeaders: Bool
    let onSelect: ((Summary) -> Void)?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @State private var availableWidth: CGFloat = 800
    @State private var timeline = SummaryTimelineMetrics()
    @State private var scrollPosition = ScrollPosition()
    #endif

    private static var spacing: CGFloat { 14 }
    private static var horizontalPadding: CGFloat { 16 }
    private static var topPadding: CGFloat { 8 }

    public init(
        entries: [SummaryFeedEntry],
        showsTimeline: Bool = false,
        showsDateHeaders: Bool = false,
        onReachEnd: @escaping () -> Void = {},
        onSelect: ((Summary) -> Void)? = nil,
        @ViewBuilder menuItems: @escaping (Summary) -> MenuItems,
        @ViewBuilder footer: () -> Footer
    ) {
        self.entries = entries
        self.showsTimeline = showsTimeline
        self.showsDateHeaders = showsDateHeaders
        self.onReachEnd = onReachEnd
        self.onSelect = onSelect
        self.menuItems = menuItems
        self.footer = footer()
    }

    public var body: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            feed
            if showsTimeline {
                SummaryTimelineScrubber(metrics: timeline)
            }
        }
        #else
        feed
        #endif
    }

    private var feed: some View {
        #if os(macOS)
        let columnCount = max(2, min(5, Int(availableWidth / 260)))
        #else
        let columnCount = sizeClass == .regular ? 3 : 2
        #endif
        let sections = feedSections(columnCount: columnCount)
        // Columns end at different entries, so any of the final few appearing means we're at the end.
        let tail = Set(entries.suffix(columnCount).map(\.id))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: showsDateHeaders ? 28 : Self.spacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        if showsDateHeaders {
                            dateHeader(for: section)
                        }
                        masonryColumns(section.columns, tail: tail)
                    }
                }
                footer.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.top, Self.topPadding)
            .padding(.bottom, 24)
            .coordinateSpace(.named(summaryFeedContentSpace))
        }
        #if os(macOS)
        .scrollPosition($scrollPosition)
        // The timeline rail replaces the system scroller.
        .scrollIndicators(showsTimeline ? .never : .automatic)
        .onScrollGeometryChange(for: SummaryTimelineMetrics.Value.self) { geometry in
            let top = geometry.contentInsets.top
            let visibleHeight = geometry.containerSize.height - top - geometry.contentInsets.bottom
            return SummaryTimelineMetrics.Value(
                offset: geometry.contentOffset.y + top,
                maxOffset: max(0, geometry.contentSize.height - visibleHeight),
                topInset: top
            )
        } action: { _, value in
            if showsTimeline { timeline.value = value }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .onChange(of: TimelineLayout(entries: entries, columnCount: columnCount, width: availableWidth), initial: true) { _, layout in
            guard showsTimeline else { return }
            let gaps = Self.spacing * CGFloat(layout.columnCount - 1)
            timeline.setLayout(
                groups: sections.map(\.columns),
                columnWidth: max(0, (layout.width - Self.horizontalPadding * 2 - gaps) / CGFloat(layout.columnCount)),
                topPadding: Self.topPadding,
                spacing: Self.spacing,
                headerHeight: showsDateHeaders ? 24 : 0,
                sectionSpacing: showsDateHeaders ? 28 : Self.spacing
            )
        }
        .onAppear {
            timeline.scrollHandler = { offset in
                scrollPosition.scrollTo(y: offset - timeline.value.topInset)
            }
        }
        #endif
    }

    private struct FeedSection: Identifiable {
        var id: Date
        var entries: [SummaryFeedEntry]
        var columns: [[SummaryFeedEntry]]
    }

    private func feedSections(columnCount: Int) -> [FeedSection] {
        guard showsDateHeaders else {
            return [FeedSection(id: .distantPast, entries: entries, columns: Self.distribute(entries, into: columnCount))]
        }
        let grouped = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            let items = grouped[day] ?? []
            return FeedSection(id: day, entries: items, columns: Self.distribute(items, into: columnCount))
        }
    }

    private func dateHeader(for section: FeedSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Calendar.current.isDateInToday(section.id) ? DateSection.today.title : SummaryDateFormatter.tile(section.id))
                .font(.headline)
            Text(section.entries.count == 1 ? String(localized: "1 summary", bundle: .module) : String(localized: "\(section.entries.count) summaries", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("feed-date-header")
        #if os(macOS)
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(summaryFeedContentSpace))
        } action: { frame in
            if showsTimeline { timeline.recordHeader(day: section.id, frame: frame) }
        }
        #endif
    }

    private func masonryColumns(_ columns: [[SummaryFeedEntry]], tail: Set<String>) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(columns.indices, id: \.self) { index in
                LazyVStack(spacing: Self.spacing) {
                    ForEach(columns[index]) { entry in
                        tileLink(for: entry)
                        .buttonStyle(TilePressStyle())
                        #if os(iOS)
                        .contentShape(
                            .contextMenuPreview,
                            RoundedRectangle(cornerRadius: SummaryTileView.cornerRadius, style: .continuous)
                        )
                        #endif
                        .contextMenu { menuItems(entry.summary) }
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                        .onAppear {
                            if tail.contains(entry.id) { onReachEnd() }
                        }
                        #if os(macOS)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named(summaryFeedContentSpace))
                        } action: { frame in
                            if showsTimeline { timeline.record(id: entry.id, frame: frame) }
                        }
                        #endif
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// Pushes onto the enclosing `NavigationStack`, or hands the summary to `onSelect` when set.
    @ViewBuilder
    private func tileLink(for entry: SummaryFeedEntry) -> some View {
        let tile = SummaryTileView(summary: entry.summary, date: entry.date, dateKind: entry.dateKind)
        if let onSelect {
            Button { onSelect(entry.summary) } label: { tile }
        } else {
            NavigationLink(value: entry.summary) { tile }
        }
    }

    #if os(macOS)
    private struct TimelineLayout: Equatable {
        var entries: [SummaryFeedEntry]
        var columnCount: Int
        var width: CGFloat
    }
    #endif

    /// Greedy masonry: each entry goes to the currently shortest column, preserving feed order
    /// row by row.
    static func distribute(_ entries: [SummaryFeedEntry], into count: Int) -> [[SummaryFeedEntry]] {
        var columns = Array(repeating: [SummaryFeedEntry](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        for entry in entries {
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[target].append(entry)
            heights[target] += SummaryTileView.Style.style(for: entry.summary).estimatedHeight(title: entry.summary.title) + 0.08
        }
        return columns
    }
}

private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

public extension SummaryCardFeed where MenuItems == EmptyView {
    init(entries: [SummaryFeedEntry], onReachEnd: @escaping () -> Void = {}, @ViewBuilder footer: () -> Footer) {
        self.init(entries: entries, onReachEnd: onReachEnd, menuItems: { _ in EmptyView() }, footer: footer)
    }
}

public extension SummaryCardFeed where Footer == EmptyView, MenuItems == EmptyView {
    init(entries: [SummaryFeedEntry], onReachEnd: @escaping () -> Void = {}) {
        self.init(entries: entries, onReachEnd: onReachEnd) { EmptyView() }
    }
}
#endif
