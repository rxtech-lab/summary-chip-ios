#if os(iOS) || os(macOS)
import SwiftUI
import Observation

private let summaryFeedContentSpace = "summary-feed-content"

/// Owned by the list screen so its viewing position survives detail navigation.
@Observable
public final class SummaryFeedScrollState {
    var offset: CGFloat?
    var isNavigating = false
    var anchorID: String?
    var anchor: UnitPoint = .top
    var viewportFrame = CGRect.zero
    var cardFrames: [String: CGRect] = [:]
    public init() {}

    func opening(_ id: String) {
        isNavigating = true
        #if os(macOS)
        guard let frame = cardFrames[id], viewportFrame.height > frame.height else { return }
        anchorID = id
        anchor = UnitPoint(x: 0, y: (frame.minY - viewportFrame.minY) / (viewportFrame.height - frame.height))
        #endif
    }
    public func reset() {
        offset = nil
        anchorID = nil
        isNavigating = false
    }
}

/// Scrolling masonry feed of `SummaryTileView`s, newest first; a podcast about one listed chip is
/// stacked under that chip's card instead of shown on its own. Two columns on compact widths,
/// three on regular (iPad). Cards push `Summary` values; register
/// `.navigationDestination(for: Summary.self)` on the enclosing stack, or pass `onSelect` to
/// handle taps yourself. `menuItems` builds each
/// card's long-press context menu. `showsDateHeaders` groups cards by their local activity day.
/// With `showsTimeline`, macOS adds a date scrubber beside the feed;
/// use it only for feeds sorted newest first.
public struct SummaryCardFeed<Footer: View, MenuItems: View>: View {
    let entries: [SummaryFeedEntry]
    private let retainedScrollState: SummaryFeedScrollState?
    @State private var fallbackScrollState = SummaryFeedScrollState()
    @State private var isFeedVisible = false
    #if os(macOS)
    @State private var scrollPosition = ScrollPosition(idType: String.self)
    #else
    @State private var scrollPosition = ScrollPosition()
    #endif
    private var viewport: SummaryFeedScrollState { retainedScrollState ?? fallbackScrollState }
    let editorPickIDs: Set<String>
    let onReachEnd: () -> Void
    let menuItems: (Summary) -> MenuItems
    let footer: Footer
    private let header: AnyView?
    let showsTimeline: Bool
    let showsDateHeaders: Bool
    let onPlayDay: ((Date) -> Void)?
    let onSelect: ((Summary) -> Void)?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    @State private var availableWidth: CGFloat = 800
    @State private var timeline = SummaryTimelineMetrics()
    #endif

    private static var spacing: CGFloat { 14 }
    private static var horizontalPadding: CGFloat { 16 }
    private static var topPadding: CGFloat { 8 }

    public init(
        entries: [SummaryFeedEntry],
        scrollState: SummaryFeedScrollState? = nil,
        editorPickIDs: Set<String> = [],
        showsTimeline: Bool = false,
        showsDateHeaders: Bool = false,
        header: AnyView? = nil,
        onReachEnd: @escaping () -> Void = {},
        onSelect: ((Summary) -> Void)? = nil,
        onPlayDay: ((Date) -> Void)? = nil,
        @ViewBuilder menuItems: @escaping (Summary) -> MenuItems,
        @ViewBuilder footer: () -> Footer
    ) {
        self.entries = SummaryFeedEntry.stackingPodcasts(entries)
        self.retainedScrollState = scrollState
        self.editorPickIDs = editorPickIDs
        self.showsTimeline = showsTimeline
        self.showsDateHeaders = showsDateHeaders
        self.onReachEnd = onReachEnd
        self.onSelect = onSelect
        self.onPlayDay = onPlayDay
        self.menuItems = menuItems
        self.header = header
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
        return GeometryReader { geometry in
            let gaps = Self.spacing * CGFloat(columnCount - 1)
            let columnWidth = max(0, (geometry.size.width - Self.horizontalPadding * 2 - gaps) / CGFloat(columnCount))
            ScrollView {
                // Headers and bands are flat rows of one lazy stack, so a long day loads band by
                // band instead of as one giant row of nested lazy columns.
                LazyVStack(alignment: .leading, spacing: Self.spacing) {
                    if let header { header.padding(.horizontal, -Self.horizontalPadding) }
                    ForEach(sections) { section in
                        if showsDateHeaders {
                            dateHeader(for: section)
                                .padding(.top, section.id == sections.first?.id ? 0 : 28 - Self.spacing)
                        }
                        ForEach(section.bands) { band in
                            masonryColumns(band.columns, tail: tail, columnWidth: columnWidth)
                        }
                    }
                    footer.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, Self.horizontalPadding)
                .padding(.top, Self.topPadding)
                .padding(.bottom, 24)
                .coordinateSpace(.named(summaryFeedContentSpace))
            }
            .accessibilityIdentifier("summary-card-feed")
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                if isFeedVisible && !viewport.isNavigating { viewport.offset = offset }
            }
            // Day grouping can lift the last-loaded cards above the bottom, and their `onAppear`
            // fires once, so also page whenever the bottom comes within a screen. The entry count
            // makes it fire again when a page lands but the feed is still near its end.
            .onScrollGeometryChange(for: Int?.self) { geometry in
                let remaining = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
                return remaining < max(geometry.containerSize.height, 400) ? entries.count : nil
            } action: { old, count in
                SummaryLog.feed.debug("near-end changed \(String(describing: old), privacy: .public) -> \(String(describing: count), privacy: .public)")
                if count != nil { onReachEnd() }
            }
            #if os(macOS)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                viewport.viewportFrame = frame
            }
            #endif
            .onAppear {
                restoreScrollPosition()
                viewport.isNavigating = false
                isFeedVisible = true
            }
            .onDisappear { isFeedVisible = false }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting {
                    viewport.isNavigating = false
                    viewport.anchorID = nil
                }
            }
            #if os(macOS)
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
                    headerHeight: showsDateHeaders ? (onPlayDay == nil ? 24 : 44) : 0,
                    sectionSpacing: showsDateHeaders ? 28 : Self.spacing
                )
            }
            .onAppear {
                timeline.scrollHandler = { offset in
                    scrollPosition.scrollTo(y: offset)
                }
            }
            #endif
            // Keep card insertion, removal, and masonry layout changes immediate.
            .transaction {
                $0.animation = nil
                $0.disablesAnimations = true
            }
        }
    }

    private func restoreScrollPosition() {
        #if os(macOS)
        // Lazy masonry re-estimates offscreen card heights on Mac; restore the visible card.
        if let id = viewport.anchorID, entries.contains(where: { $0.id == id }) {
            scrollPosition.scrollTo(id: id, anchor: viewport.anchor)
            return
        }
        #endif
        // iOS includes the collapsing navigation bar in its content insets.
        if let offset = viewport.offset { scrollPosition.scrollTo(y: offset) }
    }

    private struct FeedSection: Identifiable {
        var id: Date
        var entries: [SummaryFeedEntry]
        var bands: [FeedBand]
        /// Each column's entries across all bands, for the timeline's position estimates.
        var columns: [[SummaryFeedEntry]] {
            guard let count = bands.first?.columns.count else { return [] }
            return (0..<count).map { index in bands.flatMap { $0.columns[index] } }
        }

    }

    /// A short masonry block; the feed stacks these lazily.
    private struct FeedBand: Identifiable {
        var columns: [[SummaryFeedEntry]]
        var id: String { columns.lazy.compactMap(\.first?.id).first ?? "" }
    }

    private func feedSections(columnCount: Int) -> [FeedSection] {
        func section(_ id: Date, _ items: [SummaryFeedEntry]) -> FeedSection {
            FeedSection(id: id, entries: items, bands: Self.bands(items, into: columnCount).map(FeedBand.init))
        }
        guard showsDateHeaders else { return [section(.distantPast, entries)] }
        let grouped = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in section(day, grouped[day] ?? []) }
    }

    private func dateHeader(for section: FeedSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Calendar.current.isDateInToday(section.id) ? DateSection.today.title : SummaryDateFormatter.tile(section.id))
                .font(.headline)
            Text(section.entries.count == 1 ? String(localized: "1 summary", bundle: .module) : String(localized: "\(section.entries.count) summaries", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let onPlayDay {
                Button { onPlayDay(section.id) } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(Text("Play daily podcast", bundle: .module))
                .accessibilityIdentifier("daily-podcast-play")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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

    private func masonryColumns(_ columns: [[SummaryFeedEntry]], tail: Set<String>, columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(columns.indices, id: \.self) { index in
                // Eager within a band: bands are short, and the outer stack provides laziness.
                VStack(spacing: Self.spacing) {
                    ForEach(columns[index]) { entry in
                        tileLink(for: entry)
                        .accessibilityIdentifier("summary-card-\(entry.id)")
                        #if os(macOS)
                        .id(entry.id)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                            if isFeedVisible && !viewport.isNavigating { viewport.cardFrames[entry.id] = frame }
                        }
                        #endif
                        .buttonStyle(.plain)
                        #if os(iOS)
                        .contentShape(
                            .contextMenuPreview,
                            RoundedRectangle(cornerRadius: SummaryTileView.cornerRadius, style: .continuous)
                        )
                        #endif
                        .contextMenu { menuItems(entry.summary) }
                        .transition(.identity)
                        .onAppear {
                            if tail.contains(entry.id) {
                                SummaryLog.feed.debug("tail card appeared \(entry.id, privacy: .public) of \(entries.count) entries")
                                onReachEnd()
                            }
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
                #if os(macOS)
                .scrollTargetLayout()
                #endif
                // Fixed-size metadata must not widen a column into the feed's gutters.
                .frame(width: columnWidth, alignment: .top)
            }
        }
    }

    /// Pushes onto the enclosing `NavigationStack`, or hands the summary to `onSelect` when set.
    @ViewBuilder
    private func tileLink(for entry: SummaryFeedEntry) -> some View {
        let tile = SummaryTileView(summary: entry.summary, date: entry.date, dateKind: entry.dateKind,
                                   isEditorsPick: editorPickIDs.contains(entry.id), hasPodcast: entry.stackedPodcastID != nil)
        if let onSelect {
            Button { viewport.opening(entry.id); onSelect(entry.summary) } label: { tile }
        } else {
            NavigationLink(value: entry.summary) { tile }
                .simultaneousGesture(TapGesture().onEnded { viewport.opening(entry.id) })
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
    /// row by row. The result is cut into bands, each closed once its columns are nearly level
    /// (or at most `maxRows` deep), so stacked bands read as one continuous waterfall.
    static func bands(_ entries: [SummaryFeedEntry], into count: Int) -> [[[SummaryFeedEntry]]] {
        let minRows = 3, maxRows = 8
        let levelTolerance: CGFloat = 0.25
        var bands: [[[SummaryFeedEntry]]] = []
        var columns = Array(repeating: [SummaryFeedEntry](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var placed = 0
        for entry in entries {
            let target = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[target].append(entry)
            heights[target] += SummaryTileView.Style.style(for: entry.summary).estimatedHeight(title: entry.summary.title) + 0.08
                + (entry.stackedPodcastID == nil ? 0 : 0.1)
            placed += 1
            let spread = (heights.max() ?? 0) - (heights.min() ?? 0)
            if placed >= count * maxRows || (placed >= count * minRows && spread < levelTolerance) {
                bands.append(columns)
                columns = Array(repeating: [], count: count)
                heights = Array(repeating: 0, count: count)
                placed = 0
            }
        }
        if placed > 0 { bands.append(columns) }
        return bands
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
