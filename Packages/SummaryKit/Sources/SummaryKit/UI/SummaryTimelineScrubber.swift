#if os(macOS)
import SwiftUI

/// A dated anchor on the feed timeline: the content offset of a day header or its first card.
struct SummaryTimelineMarker: Identifiable, Equatable {
    let id: Date
    var date: Date { id }
    let offset: CGFloat
}

/// Scroll position and day markers of a timeline feed. Observed only by the scrubber, so scroll
/// updates don't invalidate the whole masonry feed.
@Observable
final class SummaryTimelineMetrics {
    struct Value: Equatable {
        /// Content offset of the visible top edge, `0...maxOffset`.
        var offset: CGFloat = 0
        /// Largest scrollable offset (`contentHeight - containerHeight`).
        var maxOffset: CGFloat = 0
        /// Inset under the toolbar; `ScrollPosition` offsets include it.
        var topInset: CGFloat = 0
    }

    var value = Value()
    /// Day markers, ordered by content offset (top to bottom).
    private(set) var markers: [SummaryTimelineMarker] = []

    /// Installed by the feed to perform programmatic scrolls to a content offset.
    @ObservationIgnored var scrollHandler: ((CGFloat) -> Void)?

    @ObservationIgnored private var groups: [[[SummaryFeedEntry]]] = []
    @ObservationIgnored private var columnWidth: CGFloat = 0
    @ObservationIgnored private var topPadding: CGFloat = 0
    @ObservationIgnored private var spacing: CGFloat = 0
    @ObservationIgnored private var headerHeight: CGFloat = 0
    @ObservationIgnored private var sectionSpacing: CGFloat = 0
    @ObservationIgnored private var frames: [String: CGRect] = [:]
    @ObservationIgnored private var headerFrames: [Date: CGRect] = [:]

    func scroll(to offset: CGFloat) {
        scrollHandler?(min(value.maxOffset, max(0, offset)))
    }

    func setLayout(groups: [[[SummaryFeedEntry]]], columnWidth: CGFloat, topPadding: CGFloat, spacing: CGFloat, headerHeight: CGFloat, sectionSpacing: CGFloat) {
        self.groups = groups
        self.columnWidth = columnWidth
        self.topPadding = topPadding
        self.spacing = spacing
        self.headerHeight = headerHeight
        self.sectionSpacing = sectionSpacing
        let entries = groups.flatMap { $0.flatMap { $0 } }
        let ids = Set(entries.map(\.id))
        frames = frames.filter { ids.contains($0.key) }
        let days = Set(entries.map { Calendar.current.startOfDay(for: $0.date) })
        headerFrames = headerFrames.filter { days.contains($0.key) }
        rebuildMarkers()
    }

    /// Records a card's laid-out frame in content coordinates.
    func record(id: String, frame: CGRect) {
        guard frames[id] != frame else { return }
        frames[id] = frame
        rebuildMarkers()
    }

    func recordHeader(day: Date, frame: CGRect) {
        guard headerFrames[day] != frame else { return }
        headerFrames[day] = frame
        rebuildMarkers()
    }

    private static func isOrderedBefore(_ lhs: SummaryTimelineMarker, _ rhs: SummaryTimelineMarker) -> Bool {
        if lhs.offset != rhs.offset { return lhs.offset < rhs.offset }
        return lhs.date > rhs.date
    }

    /// Cards in a lazy stack only report frames once laid out, so the rest are placed below the
    /// last measured card in their column using the masonry height estimate.
    private func rebuildMarkers() {
        let calendar = Calendar.current
        var dayOffsets: [Date: CGFloat] = [:]
        var groupY = topPadding
        for columns in groups {
            let day = columns.joined().first.map { calendar.startOfDay(for: $0.date) }
            let header = day.flatMap { headerFrames[$0] }
            if headerHeight > 0, let day {
                groupY = header?.minY ?? groupY
                dayOffsets[day] = groupY
            }
            let cardsY = groupY + (headerHeight > 0 ? (header?.height ?? headerHeight) + spacing : 0)
            var groupBottom = cardsY
            for column in columns {
                var y = cardsY
                for entry in column {
                    let height: CGFloat
                    if let frame = frames[entry.id] {
                        y = frame.minY
                        height = frame.height
                    } else {
                        let style = SummaryTileView.Style.style(for: entry.summary)
                        height = style.estimatedHeight(title: entry.summary.title) * columnWidth
                    }
                    if headerHeight == 0 {
                        let day = calendar.startOfDay(for: entry.date)
                        dayOffsets[day] = min(dayOffsets[day] ?? .greatestFiniteMagnitude, y)
                    }
                    groupBottom = max(groupBottom, y + height)
                    y += height + spacing
                }
            }
            groupY = groupBottom + sectionSpacing
        }
        let newMarkers = dayOffsets
            .map { day, offset in SummaryTimelineMarker(id: day, offset: offset) }
            .sorted(by: Self.isOrderedBefore)
        if newMarkers != markers { markers = newMarkers }
    }
}

/// Google Photos–style fast-scroll rail laid out beside a timeline feed. Month / year labels sit
/// at the proportional position of the first card they cover; dragging or clicking the rail
/// scrolls the feed, and a date pill beside the thumb shows the day currently in view. The pill
/// stays inside the rail so it never covers cards.
struct SummaryTimelineScrubber: View {
    let metrics: SummaryTimelineMetrics

    private var markers: [SummaryTimelineMarker] { metrics.markers }
    private var contentOffset: CGFloat { metrics.value.offset }
    private var maxOffset: CGFloat { metrics.value.maxOffset }

    /// Pointer y while dragging the rail. Hover events don't fire during a drag, so the drag
    /// location drives the indicator directly.
    @State private var dragY: CGFloat?
    @State private var hoverY: CGFloat?
    /// Day under the finger while dragging; each change ticks a selection haptic.
    @State private var scrubbedDay: Date?

    private var isDragging: Bool { dragY != nil }

    private static let verticalInset: CGFloat = 12
    private static let thumbHeight: CGFloat = 26
    private static let minimumLabelSpacing: CGFloat = 18
    static let railWidth: CGFloat = 76
    private static let trackInset: CGFloat = 6
    private static let labelTrailingInset: CGFloat = 14
    /// Month labels this close to the date pill are hidden to avoid overlap.
    private static let pillClearance: CGFloat = 14

    var body: some View {
        let isVisible = maxOffset > 0 && !markers.isEmpty
        ZStack {
            if isVisible {
                rail.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isVisible)
    }

    private var rail: some View {
        GeometryReader { proxy in
            let trackHeight = max(1, proxy.size.height - Self.verticalInset * 2)
            let thumbY = Self.verticalInset + progress * trackHeight
            let indicatorY = dragY.map { clampedTrackY($0, trackHeight: trackHeight) } ?? hoverY ?? thumbY
            let isActive = isDragging || hoverY != nil
            let labelWidth = proxy.size.width - Self.labelTrailingInset

            ZStack(alignment: .topTrailing) {
                // Wide transparent hit area so the rail is easy to grab.
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())

                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 2, height: trackHeight)
                    .position(x: proxy.size.width - Self.trackInset, y: Self.verticalInset + trackHeight / 2)
                    .allowsHitTesting(false)

                ForEach(visibleLabels(trackHeight: trackHeight), id: \.marker.id) { label in
                    let y = Self.verticalInset + label.position
                    labelView(label)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: y)
                        .opacity(abs(y - indicatorY) < Self.pillClearance ? 0 : 1)
                        .allowsHitTesting(false)
                }

                thumb
                    .position(x: proxy.size.width - Self.trackInset, y: thumbY)
                    .allowsHitTesting(false)

                if let marker = marker(atTrackY: indicatorY - Self.verticalInset, trackHeight: trackHeight) {
                    datePill(for: marker.date, isActive: isActive)
                        .frame(width: labelWidth, alignment: .trailing)
                        .position(x: labelWidth / 2, y: indicatorY)
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragY = value.location.y
                        scrub(to: value.location.y, trackHeight: trackHeight)
                        let trackY = clampedTrackY(value.location.y, trackHeight: trackHeight) - Self.verticalInset
                        scrubbedDay = marker(atTrackY: trackY, trackHeight: trackHeight)?.id
                    }
                    .onEnded { value in
                        dragY = nil
                        scrubbedDay = nil
                        // The pointer is still over the rail; keep the pill where it was
                        // released instead of the pre-drag hover.
                        hoverY = value.location.y
                    }
            )
            // Tick as the pill passes each day, but not on grab or release.
            .sensoryFeedback(.selection, trigger: scrubbedDay) { old, new in old != nil && new != nil }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverY = location.y
                case .ended: hoverY = nil
                }
            }
            .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .frame(width: Self.railWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("feed-timeline")
        .accessibilityAdjustableAction { direction in
            let step = maxOffset * 0.1
            switch direction {
            case .increment: metrics.scroll(to: contentOffset + step)
            case .decrement: metrics.scroll(to: contentOffset - step)
            @unknown default: break
            }
        }
    }

    // MARK: - Geometry

    private var progress: CGFloat {
        guard maxOffset > 0 else { return 0 }
        return min(1, max(0, contentOffset / maxOffset))
    }

    private func trackPosition(forOffset offset: CGFloat, trackHeight: CGFloat) -> CGFloat {
        guard maxOffset > 0 else { return 0 }
        return min(1, max(0, offset / maxOffset)) * trackHeight
    }

    private func clampedTrackY(_ y: CGFloat, trackHeight: CGFloat) -> CGFloat {
        min(Self.verticalInset + trackHeight, max(Self.verticalInset, y))
    }

    private func scrub(to y: CGFloat, trackHeight: CGFloat) {
        let fraction = min(1, max(0, (y - Self.verticalInset) / trackHeight))
        metrics.scroll(to: fraction * maxOffset)
    }

    /// The last marker whose track position is at or above `trackY`.
    private func marker(atTrackY trackY: CGFloat, trackHeight: CGFloat) -> SummaryTimelineMarker? {
        let target = min(1, max(0, trackY / trackHeight)) * maxOffset
        return markers.last { $0.offset <= target + 1 } ?? markers.first
    }

    // MARK: - Labels

    private struct TimelineLabel {
        let marker: SummaryTimelineMarker
        let text: String
        let isYear: Bool
        let position: CGFloat
    }

    /// One label per month (year labels when the year changes), dropping any that would collide
    /// with the previous visible label.
    private func visibleLabels(trackHeight: CGFloat) -> [TimelineLabel] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: .now)
        var labels: [TimelineLabel] = []
        var lastMonth: DateComponents?
        var lastYear: Int?
        var lastPosition: CGFloat = -.greatestFiniteMagnitude

        for marker in markers {
            let month = calendar.dateComponents([.year, .month], from: marker.date)
            guard month != lastMonth else { continue }
            lastMonth = month

            let year = month.year ?? currentYear
            let isYear = lastYear != nil && year != lastYear
            let isFirst = lastYear == nil
            lastYear = year

            let position = trackPosition(forOffset: marker.offset, trackHeight: trackHeight)
            // Year changes win over the spacing rule so the rail never hides a year boundary
            // behind a neighbouring month label.
            if position - lastPosition < Self.minimumLabelSpacing {
                guard isYear, let last = labels.last, !last.isYear else { continue }
                labels.removeLast()
            }

            let text: String
            if isYear || (isFirst && year != currentYear) {
                text = String(year)
            } else {
                text = marker.date.formatted(.dateTime.month(.abbreviated))
            }
            labels.append(TimelineLabel(marker: marker, text: text, isYear: isYear, position: position))
            lastPosition = position
        }
        return labels
    }

    private func labelView(_ label: TimelineLabel) -> some View {
        Text(label.text)
            .font(.system(size: 10, weight: label.isYear ? .bold : .medium).monospacedDigit())
            .foregroundStyle(label.isYear ? .secondary : .tertiary)
            .lineLimit(1)
            .fixedSize()
            .opacity(isDragging || hoverY != nil ? 1 : 0.85)
    }

    // MARK: - Thumb & date pill

    private var thumb: some View {
        Capsule(style: .continuous)
            .fill(isDragging ? Color.accentColor : Color.secondary.opacity(0.6))
            .frame(width: 4, height: Self.thumbHeight)
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }

    private func datePill(for date: Date, isActive: Bool) -> some View {
        Text(Self.pillText(for: date))
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.summaryCardBackground)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(isActive ? 0 : 0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    /// Month and day, plus the year for dates outside the current year.
    private static func pillText(for date: Date) -> String {
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }

    private var accessibilityValue: String {
        guard let marker = markers.last(where: { $0.offset <= contentOffset + 1 }) ?? markers.first else {
            return ""
        }
        return marker.date.formatted(date: .abbreviated, time: .omitted)
    }
}
#endif
