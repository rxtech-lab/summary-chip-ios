import SummaryKit
import SwiftUI

/// The sheets a trip presents. One `sheet(item:)` shows them, so switching from transport details
/// to its editor replaces one sheet with the other.
enum TripSheet: Identifiable, Hashable {
    case meta
    case day(String?)
    case places
    case place(String?)
    case transport(String?)
    case transportDetail(String)
    case hotel(String?)
    case expense(String?)
    case view(String?)
    case notes
    case sources
    case agent
    case expenseAgent
    case currency
    case share
    case editSharing

    var id: String {
        switch self {
        case .meta: "meta"
        case .day(let id): "day:\(id ?? "new")"
        case .places: "places"
        case .place(let id): "place:\(id ?? "new")"
        case .transport(let id): "transport:\(id ?? "new")"
        case .transportDetail(let id): "transport-detail:\(id)"
        case .hotel(let id): "hotel:\(id ?? "new")"
        case .expense(let id): "expense:\(id ?? "new")"
        case .view(let id): "view:\(id ?? "new")"
        case .notes: "notes"
        case .sources: "sources"
        case .agent: "agent"
        case .expenseAgent: "expense-agent"
        case .currency: "currency"
        case .share: "share"
        case .editSharing: "edit-sharing"
        }
    }
}

/// The diary: header, the trip-wide views, a card per day, then places; notes and sources open in sheets. Hotels and
/// costs have their own panes. Reports which day
/// is being read, and how far into it, from where the cards sit against a reading line.
struct TripDiaryView: View {
    let document: TripDocument
    let activeDayID: String?
    @Binding var scrollPosition: ScrollPosition
    /// Distance of the reading line below the top of the visible area, given its height.
    let readingLine: (CGFloat) -> CGFloat
    let onRead: (String, Double) -> Void
    let present: (TripSheet) -> Void

    @State private var tracker = TripReadingTracker()

    nonisolated private static let contentSpace = "trip-diary-content"

    var body: some View {
        let days = document.orderedDays
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                TripHeaderView(document: document) { present(.meta) }
                    .padding(.bottom, 6)

                // Trip-wide views (comparison tables, budgets…); a day's own views sit in its card.
                let tripViews = document.views(forDay: nil)
                if !tripViews.isEmpty {
                    TripSection(title: String(localized: "Planning"), systemImage: "rectangle.3.group") {
                        ForEach(tripViews) { view in
                            TripCustomViewCard(view: view, currency: document.currency) { present(.view(view.id)) }
                                .equatable()
                        }
                    }
                    .accessibilityIdentifier("trip-planning-section")
                }

                if days.isEmpty {
                    ContentUnavailableView {
                        Label("No days yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Add days to write the diary, or share a booking to Chippy and let the agent fill it in.")
                    } actions: {
                        Button("Add Day") { present(.day(nil)) }
                            .buttonStyle(.borderedProminent)
                    }
                }

                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    TripDayCard(
                        document: document,
                        day: day,
                        number: index + 1,
                        isReading: day.id == activeDayID,
                        onEdit: { present(.day(day.id)) },
                        onOpenTransport: { present(.transportDetail($0.id)) },
                        onEditView: { present(.view($0.id)) }
                    )
                    .equatable()
                    .id(day.id)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named(Self.contentSpace))
                    } action: { frame in
                        tracker.frames[day.id] = frame
                        read()
                    }
                }

                VStack(spacing: 8) {
                    TripLinkButton(title: String(localized: "Places"), systemImage: "mappin.and.ellipse", detail: document.places.count.formatted()) { present(.places) }
                        .accessibilityIdentifier("trip-places-button")
                    if !document.notes.isEmpty {
                        TripLinkButton(title: String(localized: "Notes"), systemImage: "note.text", detail: document.notes.count.formatted()) { present(.notes) }
                            .accessibilityIdentifier("trip-notes-button")
                    }
                    if !document.sources.isEmpty {
                        TripLinkButton(title: String(localized: "Sources"), systemImage: "link", detail: document.sources.count.formatted()) { present(.sources) }
                            .accessibilityIdentifier("trip-sources-button")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 48)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .coordinateSpace(.named(Self.contentSpace))
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: TripReadingTracker.Metrics.self, of: TripReadingTracker.Metrics.init) { _, metrics in
            tracker.metrics = metrics
            read()
        }
        .background(Color.summaryGroupedBackground)
    }

    private func emptyRow(_ text: String) -> some View {
        TripEmptyRow(text: text)
    }

    private func read() {
        guard let (dayID, progress) = tracker.read(order: document.orderedDays.map(\.id), readingLine: readingLine) else { return }
        onRead(dayID, progress)
    }
}

/// Where a pane's day sections sit against its reading line. Port of the Northbound `readDay()`:
/// the active day is the last section whose top passed the line. Positions are kept out of
/// observation: they change on every scroll frame.
final class TripReadingTracker {
    struct Metrics: Equatable {
        var top: CGFloat = 0
        var height: CGFloat = 0

        init() {}

        init(_ geometry: ScrollGeometry) {
            top = geometry.contentOffset.y + geometry.contentInsets.top
            height = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
        }
    }

    var frames: [String: CGRect] = [:]
    var metrics = Metrics()
    private var last: (String, Double)?

    /// The day being read and how far through it, or nil while unmeasured or unchanged. Sections
    /// sit in a lazy stack, so those never scrolled near have no frame yet and are skipped.
    func read(order: [String], readingLine: (CGFloat) -> CGFloat) -> (String, Double)? {
        let measured = order.compactMap { id in frames[id].map { (id, $0) } }
        guard !measured.isEmpty, metrics.height > 0 else { return nil }
        let line = metrics.top + readingLine(metrics.height)
        guard let position = TripReading.position(
            frames: measured.map { (minY: Double($0.1.minY), maxY: Double($0.1.maxY)) },
            line: Double(line)
        ) else { return nil }
        let dayID = measured[position.index].0
        // Steps of 0.5% are smooth on the map without re-rendering it for every point scrolled.
        let progress = (position.progress * 200).rounded() / 200
        if let last, last.0 == dayID, last.1 == progress { return nil }
        last = (dayID, progress)
        return (dayID, progress)
    }
}

/// The day picker: one capsule per day, the day being read filled. Tapping jumps the diary.
struct TripDayStrip: View {
    let document: TripDocument
    let activeDayID: String?
    let onSelect: (String) -> Void

    var body: some View {
        let days = document.orderedDays
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        let isActive = day.id == activeDayID
                        Button { onSelect(day.id) } label: {
                            VStack(spacing: 0) {
                                Text(index + 1, format: .number)
                                    .font(.subheadline.weight(.bold))
                                    .monospacedDigit()
                                Text(shortDate(day.date))
                                    .font(.caption2)
                                    .monospacedDigit()
                            }
                            .frame(minWidth: 44)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 4)
                            .foregroundStyle(isActive ? Color.white : Color.primary)
                            .background(isActive ? TripStyle.color(for: day.route?.kind) : Color.primary.opacity(0.07), in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(day.id)
                        .accessibilityLabel(Text("Day \(index + 1), \(document.dayLabel(day.date))"))
                        .accessibilityAddTraits(isActive ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeDayID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("trip-day-strip")
    }

    private func shortDate(_ date: String) -> String {
        let zone = document.resolvedTimeZone
        guard let day = TripDate.date(from: date, timeZone: zone) else { return date }
        var style = Date.FormatStyle().month(.defaultDigits).day(.defaultDigits)
        style.timeZone = zone
        return day.formatted(style)
    }
}

/// What the trip pane shows: the day-by-day diary (with its custom views), or bookings (transport
/// and hotels) or costs on their own.
enum TripPane: String, CaseIterable, Identifiable {
    case diary, bookings, expenses

    var id: String { rawValue }

    var title: String {
        switch self {
        case .diary: String(localized: "Diary")
        case .bookings: String(localized: "Bookings")
        case .expenses: String(localized: "Expenses")
        }
    }

    var systemImage: String {
        switch self {
        case .diary: "book"
        case .bookings: "suitcase"
        case .expenses: "creditcard"
        }
    }
}

/// Above the diary: the day being read and the day picker. All the iPhone sheet shows when collapsed. All the iPhone sheet shows when collapsed.
struct TripDiaryBar: View {
    let document: TripDocument
    let activeDayID: String?
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let day = document.day(id: activeDayID), let number = document.dayNumber(of: day.id) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DAY \(number)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(TripStyle.color(for: day.route?.kind))
                    Text(day.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(document.dayLabel(day.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: day.id)
            }
            if !document.days.isEmpty {
                TripDayStrip(document: document, activeDayID: activeDayID, onSelect: onSelect)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TripEmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }
}

/// A non-diary pane: one section, scrolled on its own.
private struct TripPaneScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 48)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .background(Color.summaryGroupedBackground)
    }
}

/// Transport and hotels, each in date order.
struct TripBookingsPane: View {
    let document: TripDocument
    let present: (TripSheet) -> Void

    var body: some View {
        TripPaneScroll {
            TripSection(title: String(localized: "Transport"), systemImage: "tram", addTitle: String(localized: "Add Transport"), onAdd: { present(.transport(nil)) }) {
                if document.transports.isEmpty {
                    TripEmptyRow(text: String(localized: "No transport yet."))
                }
                ForEach(document.transports.sorted { $0.date < $1.date }) { transport in
                    TransportSummaryButton(document: document, transport: transport) { present(.transportDetail(transport.id)) }
                }
            }
            TripSection(title: String(localized: "Hotels"), systemImage: "bed.double", addTitle: String(localized: "Add Hotel"), onAdd: { present(.hotel(nil)) }) {
                if document.hotels.isEmpty {
                    TripEmptyRow(text: String(localized: "No hotels yet."))
                }
                ForEach(document.hotels.sorted { $0.checkIn < $1.checkIn }) { hotel in
                    HotelCard(document: document, hotel: hotel) { present(.hotel(hotel.id)) }
                }
            }
        }
        .accessibilityIdentifier("trip-bookings-pane")
    }
}

struct TripExpensesPane: View {
    let document: TripDocument
    let present: (TripSheet) -> Void
    @State private var converter = CurrencyConverter.shared

    var body: some View {
        TripPaneScroll {
            TripSection(
                title: String(localized: "Expenses"),
                systemImage: "creditcard",
                addTitle: String(localized: "Add Expense"),
                onAdd: { present(.expense(nil)) },
                onAddWithAI: { present(.expenseAgent) }
            ) {
                if document.expenses.isEmpty {
                    TripEmptyRow(text: String(localized: "No costs yet."))
                } else {
                    ExpensesSummaryView(document: document) { present(.expense($0.id)) }
                }
            }
            TripLinkButton(
                title: String(localized: "Currency Conversion"),
                systemImage: "arrow.left.arrow.right",
                detail: converter.target ?? String(localized: "Off")
            ) { present(.currency) }
            .accessibilityIdentifier("trip-currency-conversion")
        }
        .accessibilityIdentifier("trip-expenses-pane")
    }
}
