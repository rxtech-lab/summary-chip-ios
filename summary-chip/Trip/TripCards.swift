import SummaryKit
import SwiftUI

/// Title, subtitle, dates and introduction at the top of the diary.
struct TripHeaderView: View {
    let document: TripDocument
    let onEdit: () -> Void

    @Environment(\.tripReading) private var reading
    @State private var showsIntro = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if let eyebrow = document.titleParts.eyebrow {
                        Text(eyebrow)
                            .font(.caption.weight(.semibold))
                            .textCase(.uppercase)
                            .kerning(0.8)
                            .foregroundStyle(.tint)
                    }
                    Text(document.titleParts.main)
                        .font(.title.weight(.bold))
                        .kerning(-0.4)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle = document.conciseSubtitle {
                        Label(subtitle, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
                TripEditButton(title: String(localized: "Edit trip details"), action: onEdit)
            }

            Text(document.headerFacts)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let reading, reading.isTranslated || reading.translatingTo != nil {
                TripTranslationNote(reading: reading)
            }

            if let intro = document.intro, !intro.isEmpty {
                Button { showsIntro = true } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(intro)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        Text("Read more")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .sensoryFeedback(.impact(weight: .light), trigger: showsIntro) { _, new in new }
                .sheet(isPresented: $showsIntro) {
                    TripIntroSheet(title: document.title, subtitle: document.subtitle, intro: intro)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Translated from English to Japanese" under the header. For the owner it opens the language
/// sheet, and says why the edit buttons are gone.
private struct TripTranslationNote: View {
    let reading: TripReadingLanguage

    var body: some View {
        if let changeLanguage = reading.changeLanguage {
            Button(action: changeLanguage) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        label
                        if reading.translatingTo != nil {
                            Text("You'll get a notification when it's ready.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Switch to the original to edit.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Change language"))
            .accessibilityIdentifier("trip-translated-note")
        } else {
            label.accessibilityIdentifier("trip-translated-note")
        }
    }

    private var label: some View {
        Label {
            if let target = reading.translatingTo {
                Text("Translating to \(SummaryLanguage.displayName(for: target))…")
            } else {
                Text("Translated from \(SummaryLanguage.displayName(for: reading.originalLanguage)) to \(SummaryLanguage.displayName(for: reading.language))")
            }
        } icon: {
            Image(systemName: reading.translatingTo != nil ? "hourglass" : "translate")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// The trip's full introduction, opened from the header.
private struct TripIntroSheet: View {
    let title: String
    let subtitle: String?
    let intro: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(intro)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension TripDocument {
    private static let separator = " · "

    /// "Northbound Japan · Autumn 2026" → main "Northbound Japan", eyebrow "Autumn 2026".
    var titleParts: (main: String, eyebrow: String?) {
        let parts = title.components(separatedBy: Self.separator).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1, let main = parts.first, !main.isEmpty else { return (title, nil) }
        return (main, parts.dropFirst().joined(separator: Self.separator))
    }

    /// The subtitle without the date and length parts the header pills already show:
    /// "2026 年 10 月 10–20 日 · 千叶、东北与函馆 · 11 天 10 夜" → "千叶、东北与函馆".
    var conciseSubtitle: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        let parts = subtitle.components(separatedBy: Self.separator).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1 else { return subtitle }
        let kept = parts.filter { $0.rangeOfCharacter(from: .decimalDigits) == nil }
        return kept.isEmpty ? subtitle : kept.joined(separator: Self.separator)
    }

    /// "Oct 10 – 20 · 11 days · Tokyo": the header's facts in one line.
    var headerFacts: String {
        let length = days.count == 1 ? String(localized: "1 day") : String(localized: "\(days.count) days")
        return [dateRangeText, length, timeZoneCity].filter { !$0.isEmpty }.joined(separator: Self.separator)
    }

    /// "Asia/Tokyo" → "Tokyo".
    var timeZoneCity: String {
        (timeZone.split(separator: "/").last.map(String.init) ?? timeZone)
            .replacingOccurrences(of: "_", with: " ")
    }
}

/// The language a trip's diary is shown in.
struct TripReadingLanguage {
    let language: String
    let originalLanguage: String
    /// A background run is translating the trip into this language; shown as written until then.
    var translatingTo: String?
    /// Opens the language sheet; nil when the reader can't change it (someone else's trip).
    let changeLanguage: (() -> Void)?

    var isTranslated: Bool { language != originalLanguage }
}

extension EnvironmentValues {
    /// False for someone else's trip, or one shown translated: edit and add buttons are hidden.
    @Entry var tripEditable = true
    /// The language the diary is shown in; nil while the trip loads.
    @Entry var tripReading: TripReadingLanguage?
    /// Edit and delete for the transport and hotel cards' context menus.
    @Entry var tripRecordActions: TripRecordActions?
}

/// A transport or hotel a context menu acts on.
struct TripRecord: Identifiable, Hashable {
    enum Kind { case transport, hotel }

    let kind: Kind
    let id: String
    let name: String

    var collection: TripCollection { kind == .transport ? .transports : .hotels }
    var editSheet: TripSheet { kind == .transport ? .transport(id) : .hotel(id) }

    var deleteTitle: String {
        kind == .transport ? String(localized: "Delete Transport") : String(localized: "Delete Hotel")
    }

    var deleteMessage: String {
        kind == .transport
            ? String(localized: "The transport and its options are removed from the trip.")
            : String(localized: "Days staying here will show no hotel.")
    }
}

struct TripRecordActions {
    let edit: (TripRecord) -> Void
    let delete: (TripRecord) -> Void
}

/// Edit and Delete on a transport or hotel card, for the trip's owner.
private struct TripRecordContextMenu: ViewModifier {
    let record: TripRecord
    @Environment(\.tripEditable) private var editable
    @Environment(\.tripRecordActions) private var actions

    func body(content: Content) -> some View {
        if editable, let actions {
            content.contextMenu {
                Button { actions.edit(record) } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) { actions.delete(record) } label: {
                    Label(record.deleteTitle, systemImage: "trash")
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func tripRecordContextMenu(_ record: TripRecord) -> some View {
        modifier(TripRecordContextMenu(record: record))
    }
}

struct TripEditButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.tripEditable) private var editable

    var body: some View {
        if editable { button }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.subheadline.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}

/// One diary day, kept to a glance: date, title, the moments in a line each, the transport taken,
/// the places as chips and where the night is spent. The blurb, full moments, place guides,
/// day views and tip open in the day's details sheet.
/// Equatable on its data so scrolling, which re-renders the diary for the map, skips the cards;
/// the actions only route to sheets.
struct TripDayCard: View, Equatable {
    let document: TripDocument
    let day: TripDay
    let number: Int
    let isReading: Bool
    let onEdit: () -> Void
    let onOpenTransport: (TripTransport) -> Void
    let onOpenDetails: () -> Void

    /// Moments shown before "+N more".
    private static let momentLimit = 4

    private var accent: Color { TripStyle.color(for: day.route?.kind) }

    private var highlightsReadingOutline: Bool {
        #if os(iOS)
        false
        #else
        isReading
        #endif
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.document == rhs.document && lhs.day == rhs.day && lhs.number == rhs.number && lhs.isReading == rhs.isReading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DAY \(number) · \(document.dayLabel(day.date))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Text(day.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let short = day.short ?? day.route?.summary {
                        Text(short)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                TripEditButton(title: String(localized: "Edit day"), action: onEdit)
            }

            if !day.moments.isEmpty {
                CompactMoments(moments: day.moments, limit: Self.momentLimit, tint: accent)
            }

            let transports = day.transportIds.compactMap { document.transport(id: $0) }
            if !transports.isEmpty {
                VStack(spacing: 8) {
                    ForEach(transports) { transport in
                        TransportSummaryButton(document: document, transport: transport) { onOpenTransport(transport) }
                    }
                }
            }

            let places = document.guidePlaces(for: day)
            if !places.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(places) { TripPlaceChip(place: $0) }
                    }
                }
                .scrollIndicators(.hidden)
                // Scroll edge to edge of the card, clipped by it, with the chips starting in line with the text.
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
                .accessibilityIdentifier("trip-day-places-\(day.id)")
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(highlightsReadingOutline ? accent : (day.highlight ? accent.opacity(0.4) : Color.primary.opacity(0.06)), lineWidth: highlightsReadingOutline ? 2 : 1)
        }
        .animation(.easeInOut(duration: 0.2), value: isReading)
        .accessibilityIdentifier("trip-day-\(day.id)")
    }

    /// Where the night is spent, and the way into the rest of the day.
    private var footer: some View {
        HStack(spacing: 8) {
            if let hotel = document.hotel(id: day.stayId) {
                Label(hotel.name, systemImage: "moon.stars")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.indigo)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: onOpenDetails) {
                HStack(spacing: 4) {
                    if day.tip != nil {
                        Image(systemName: "lightbulb").accessibilityHidden(true)
                    }
                    Text("Details")
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Day \(number) details"))
            .accessibilityIdentifier("trip-day-details-\(day.id)")
        }
    }
}

extension TripDocument {
    /// The places a day visits that have something to show: its route, moment stops (even when the
    /// route only names the cities between them) and its hotel, each once.
    func guidePlaces(for day: TripDay) -> [TripPlace] {
        let ids = (day.route?.placeIds ?? []) + day.moments.compactMap(\.placeId)
            + [hotel(id: day.stayId)?.placeId].compactMap { $0 }
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let place = place(id: id), place.hasDetails else { return nil }
            return place
        }
    }
}

/// The day's moments in a line each: time (or slot) and what happens, then "+N more".
private struct CompactMoments: View {
    let moments: [TripMoment]
    let limit: Int
    let tint: Color

    var body: some View {
        let shown = moments.prefix(limit)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(shown.indices, id: \.self) { index in
                let moment = shown[index]
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text(moment.time ?? moment.slot.title)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .leading)
                    Text(moment.text)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            if moments.count > limit {
                Text("+\(moments.count - limit) more")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
        }
    }
}

/// A place a day visits, as a small chip: thumbnail and name. Opens the place's details.
private struct TripPlaceChip: View {
    let place: TripPlace
    @Environment(\.tripShowPlace) private var showPlace

    var body: some View {
        Button { showPlace?(place.id) } label: {
            HStack(spacing: 6) {
                if let photo = place.photos.first?.imageURL {
                    SummaryRemoteImage(url: photo) { Circle().fill(.quaternary) }
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                } else {
                    Image(systemName: place.kind.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                Text(place.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(showPlace == nil)
        .accessibilityHint("Shows the place's details")
    }
}

/// Everything about one day: the blurb, the full moments, place guides, transport, the day's
/// views and its tip. Opened from the day card's Details.
struct TripDayDetailSheet: View {
    let document: TripDocument
    let day: TripDay
    let onEdit: () -> Void
    let onOpenTransport: (TripTransport) -> Void
    let onEditView: (TripView) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tripEditable) private var editable

    private var accent: Color { TripStyle.color(for: day.route?.kind) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document.dayLabel(day.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                        Text(day.title)
                            .font(.title2.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let short = day.short ?? day.route?.summary {
                            Text(short).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let hotel = document.hotel(id: day.stayId) {
                            Label(hotel.name, systemImage: "moon.stars")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.indigo)
                                .padding(.top, 4)
                        }
                    }

                    if let blurb = day.blurb {
                        Text(blurb)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }

                    if !day.moments.isEmpty {
                        section("Moments") {
                            MomentsTimeline(document: document, moments: day.moments, tint: accent)
                        }
                    }

                    let transports = day.transportIds.compactMap { document.transport(id: $0) }
                    if !transports.isEmpty {
                        section("Transport") {
                            VStack(spacing: 8) {
                                ForEach(transports) { transport in
                                    TransportSummaryButton(document: document, transport: transport) { onOpenTransport(transport) }
                                }
                            }
                        }
                    }

                    let places = document.guidePlaces(for: day)
                    if !places.isEmpty {
                        section("Places") {
                            VStack(spacing: 10) {
                                ForEach(places) { TripPlacePreviewCard(place: $0) }
                            }
                        }
                    }

                    ForEach(document.views(forDay: day.id)) { view in
                        TripCustomViewCard(view: view, currency: document.currency, embedded: true) { onEditView(view) }
                            .equatable()
                    }

                    if let tip = day.tip {
                        Label {
                            Text(tip)
                        } icon: {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                        }
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(document.dayNumber(of: day.id).map { String(localized: "Day \($0)") } ?? day.title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if editable {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit", action: onEdit)
                            .accessibilityIdentifier("trip-day-detail-edit")
                    }
                }
            }
        }
        .summarySheetSize()
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }
}

private struct MomentsTimeline: View {
    let document: TripDocument
    let moments: [TripMoment]
    let tint: Color
    @Environment(\.tripShowPlace) private var showPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(moments.indices, id: \.self) { index in
                let moment = moments[index]
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 5)
                        if index < moments.count - 1 {
                            Rectangle().fill(tint.opacity(0.3)).frame(width: 2).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(moment.slot.title)
                            if let time = moment.time { Text(time).monospacedDigit() }
                            if let place = document.place(id: moment.placeId) {
                                if let showPlace {
                                    Button { showPlace(place.id) } label: {
                                        Text("· \(place.name)").lineLimit(1).foregroundStyle(.tint)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityHint("Shows the place's details")
                                } else {
                                    Text("· \(place.name)").lineLimit(1)
                                }
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        Text(moment.text)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, index < moments.count - 1 ? 12 : 0)
                }
            }
        }
    }
}

/// A day's transport: label, the chosen option's times and its status, and the live status of
/// its tracked flights. Opens the details.
struct TransportSummaryButton: View {
    let document: TripDocument
    let transport: TripTransport
    let action: () -> Void
    @Environment(\.tripFlights) private var flights

    var body: some View {
        let tracked = flights.tracked(transportID: transport.id, optionID: transport.selectedOption?.id)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: (transport.selectedOption?.segments.first?.mode ?? .train).systemImage)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(TripStyle.color(for: .out), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transport.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let line = transport.selectedOption?.summaryLine(timeZone: document.resolvedTimeZone), !line.isEmpty {
                            Text(line).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 6)
                    StatusChip(status: transport.status)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                ForEach(tracked) { item in
                    Divider()
                    TrackedFlightStatusView(item: item)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .tripRecordContextMenu(TripRecord(kind: .transport, id: transport.id, name: transport.label))
        .accessibilityIdentifier("trip-transport-\(transport.id)")
    }
}

struct StatusChip: View {
    let status: TripBookingStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(status.tint)
            .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// A titled group under the days (Hotels, Expenses, Places, Notes), with an add button.
struct TripSection<Content: View>: View {
    let title: String
    let systemImage: String
    var addTitle: String?
    var onAdd: (() -> Void)?
    /// When set, the add button becomes a menu: fill in the form, or let the agent fill it in.
    var onAddWithAI: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.tripEditable) private var editable

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.title3.weight(.semibold))
                Spacer()
                if editable, let onAdd, let addTitle {
                    if let onAddWithAI {
                        Menu {
                            Button(action: onAdd) { Label("Fill In Form", systemImage: "square.and.pencil") }
                            Button(action: onAddWithAI) { Label("Fill with AI", systemImage: "sparkles") }
                        } label: {
                            addIcon
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .accessibilityLabel(addTitle)
                    } else {
                        Button(action: onAdd) { addIcon }
                            .buttonStyle(.plain)
                            .accessibilityLabel(addTitle)
                    }
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var addIcon: some View {
        Image(systemName: "plus")
            .font(.subheadline.weight(.semibold))
            .frame(width: 30, height: 30)
            .background(.quaternary, in: Circle())
    }
}

/// A row under the days that opens a secondary section (Notes, Sources) in its own sheet.
struct TripLinkButton: View {
    let title: String
    let systemImage: String
    /// Shown before the chevron: a count, or the current setting.
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 6)
                Text(detail)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct TripNotesSheet: View {
    let notes: [TripNote]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title).font(.headline)
                    Text(note.text).font(.subheadline)
                }
                .textSelection(.enabled)
                .padding(.vertical, 2)
            }
            .navigationTitle("Notes")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .summarySheetSize()
    }
}

struct TripSourcesSheet: View {
    let sources: [TripSource]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(sources, id: \.self) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title).font(.subheadline.weight(.semibold))
                            Text(url.host() ?? source.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text(source.title).font(.subheadline)
                }
            }
            .navigationTitle("Sources")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .summarySheetSize()
    }
}

struct HotelCard: View {
    let document: TripDocument
    let hotel: TripHotel
    let onEdit: () -> Void

    private var nights: Int { max(0, TripDate.daysBetween(hotel.checkIn, hotel.checkOut) ?? 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(hotel.name).font(.headline)
                    Text("\(document.dayLabel(hotel.checkIn)) → \(document.dayLabel(hotel.checkOut))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusChip(status: hotel.status)
                TripEditButton(title: String(localized: "Edit hotel"), action: onEdit)
            }
            HStack(spacing: 12) {
                Label(nights == 1 ? String(localized: "1 night") : String(localized: "\(nights) nights"), systemImage: "moon")
                if let time = hotel.checkInTime {
                    Label(String(localized: "Check-in \(time)"), systemImage: "clock")
                }
                if let price = hotel.price {
                    Label(price.formatted, systemImage: "creditcard")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let address = hotel.address ?? document.place(id: hotel.placeId)?.address {
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            if let confirmation = hotel.confirmation {
                Label(String(localized: "Confirmation \(confirmation)"), systemImage: "checkmark.seal")
                    .font(.caption.weight(.medium))
                    .textSelection(.enabled)
            }
            if let link = hotel.url.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    Label("Website", systemImage: "safari").font(.caption.weight(.semibold))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        #if os(iOS)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18, style: .continuous))
        #endif
        .tripRecordContextMenu(TripRecord(kind: .hotel, id: hotel.id, name: hotel.name))
    }
}

/// Totals per currency (pass-covered costs left out), per category, and every cost.
struct ExpensesSummaryView: View {
    let document: TripDocument
    let onEdit: (TripExpense) -> Void
    @State private var converter = CurrencyConverter.shared

    private func totalsText(_ totals: [TripCurrencyTotal]) -> String {
        totals.map(\.money.formatted).joined(separator: " + ")
    }

    /// The totals, then "≈" the same in the chosen currency when any of them is in another one.
    private func totalsLine(_ totals: [TripCurrencyTotal]) -> String {
        guard let converted = converter.convert(totals) else { return totalsText(totals) }
        return "\(totalsText(totals)) ≈ \(converted.formatted)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let totals = document.expenseTotals()
            VStack(alignment: .leading, spacing: 2) {
                Text("Total")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(totals.isEmpty ? TripMoney(amount: 0, currency: document.currency).formatted : totalsText(totals))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let converted = converter.convert(totals) {
                    Text("≈ \(converted.formatted)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("expenses-converted-total")
                }
            }
            let categories = TripExpenseCategory.allCases.filter { category in
                document.expenses.contains { $0.category == category && !$0.isCovered }
            }
            if categories.count > 1 {
                VStack(spacing: 6) {
                    ForEach(categories) { category in
                        HStack {
                            Label(category.title, systemImage: category.systemImage)
                            Spacer()
                            Text(totalsLine(document.expenseTotals(category: category))).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
            Divider()
            ForEach(document.expenses) { expense in
                Button { onEdit(expense) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expense.category.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(expense.title).foregroundStyle(.primary)
                            if let pass = document.expense(id: expense.coveredByExpenseId) {
                                Text("Covered by \(pass.title)").font(.caption).foregroundStyle(.green)
                            } else if let date = expense.date {
                                Text(document.dayLabel(date)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(expense.amount.formatted)
                                .strikethrough(expense.isCovered)
                                .foregroundStyle(expense.isCovered ? .secondary : .primary)
                            if let converted = converter.convert(expense.amount) {
                                Text("≈ \(converted.formatted)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("expense-converted-amount")
                            }
                        }
                        .monospacedDigit()
                        Image(systemName: expense.paid ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(expense.paid ? .green : .secondary)
                            .accessibilityLabel(expense.paid ? String(localized: "Paid") : String(localized: "Not paid"))
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task(id: converter.target) { await converter.refreshIfNeeded() }
    }
}

/// The trip's places, like Notes in its own sheet. Tapping a place opens its details (photos,
/// info, prices, directions) in place of this sheet; the add button opens a blank editor.
struct TripPlacesSheet: View {
    let places: [TripPlace]
    let onOpen: (TripPlace) -> Void
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tripEditable) private var editable

    var body: some View {
        NavigationStack {
            List(places) { place in
                Button { onOpen(place) } label: {
                    HStack(spacing: 10) {
                        if let photo = place.photos.first?.imageURL {
                            SummaryRemoteImage(url: photo) { Rectangle().fill(.quaternary) }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        } else {
                            Image(systemName: place.kind.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name).foregroundStyle(.primary)
                            if let detail = place.address ?? place.description {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
                .accessibilityIdentifier("trip-place-\(place.id)")
            }
            .overlay {
                if places.isEmpty {
                    ContentUnavailableView {
                        Label("No places yet", systemImage: "mappin.and.ellipse")
                    } description: {
                        Text("Add places to draw routes on the map.")
                    }
                }
            }
            .navigationTitle("Places")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if editable {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: onAdd) { Label("Add Place", systemImage: "plus") }
                            .accessibilityIdentifier("trip-add-place")
                    }
                }
            }
        }
        .summarySheetSize()
    }
}

/// The transport's options and legs: "05:53 → 14:04", train category and seat, flight number and
/// terminal, fares and warnings. Editing opens the transport editor. Tracked flights get a
/// dedicated Live Status tab.
struct TransportDetailSheet: View {
    private enum Tab: Hashable { case details, liveStatus }

    let document: TripDocument
    let transport: TripTransport
    let onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tripEditable) private var editable
    @Environment(\.tripFlights) private var flights
    @State private var optionID: String
    @State private var tab: Tab = .details

    init(document: TripDocument, transport: TripTransport, onEdit: @escaping () -> Void) {
        self.document = document
        self.transport = transport
        self.onEdit = onEdit
        _optionID = State(initialValue: transport.selectedOption?.id ?? "")
    }

    private var option: TripTransportOption? {
        transport.options.first { $0.id == optionID } ?? transport.selectedOption
    }

    private var tracked: [TripFlight] {
        guard let option else { return [] }
        return flights.tracked(transportID: transport.id, optionID: option.id)
    }

    /// The Live Status tab only when the shown option has tracked flights.
    private var shownTab: Tab { tracked.isEmpty ? .details : tab }

    var body: some View {
        NavigationStack {
            Group {
                switch shownTab {
                case .details: details
                case .liveStatus: liveStatus
                }
            }
            .navigationTitle("Transport")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !tracked.isEmpty {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $tab) {
                            Text("Details").tag(Tab.details)
                            Text("Live Status").tag(Tab.liveStatus)
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .accessibilityIdentifier("transport-detail-tabs")
                    }
                }
                if editable {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit", action: onEdit)
                            .accessibilityIdentifier("transport-detail-edit")
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: optionID)
        .sensoryFeedback(.selection, trigger: tab)
        .summarySheetSize()
    }

    /// Live flight status of the option's tracked flights, as last stored by the backend.
    private var liveStatus: some View {
        List {
            Section {
                ForEach(tracked) { item in
                    if let flight = item.flight, item.state == .found {
                        FlightInfoCard(flight: flight, showsUpdated: true)
                            .padding(.vertical, 4)
                    } else {
                        TrackedFlightStatusView(item: item)
                    }
                }
            } footer: {
                Text("Chippy checks tracked flights and sends alerts when the gate, times or status change.")
            }
        }
    }

    private var details: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(document.dayLabel(transport.date))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        StatusChip(status: transport.status)
                    }
                    Text(transport.label).font(.title2.weight(.bold))
                }
                if transport.options.count > 1 {
                    Picker("Option", selection: $optionID) {
                        ForEach(transport.options) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let option {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(option.label).font(.headline)
                            if option.id == transport.selectedOption?.id && transport.options.count > 1 {
                                Text("Chosen").font(.caption.weight(.bold)).foregroundStyle(.green)
                            }
                            Spacer()
                            if let fare = option.fare {
                                Text(fare.formatted).font(.headline).monospacedDigit()
                            }
                        }
                        if let times = TripTimes.range(option.effectiveDeparture, option.effectiveArrival) {
                            HStack {
                                Text(times).font(.title3.weight(.semibold)).monospacedDigit()
                                if let duration = option.duration { Text(duration).font(.subheadline).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if let warning = option.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                if !option.segments.isEmpty {
                    Section("Legs") {
                        ForEach(option.segments.indices, id: \.self) { index in
                            SegmentDetailRow(segment: option.segments[index])
                        }
                    }
                }
                if !option.notes.isEmpty {
                    Section("Notes") {
                        ForEach(option.notes, id: \.self) { Text($0).font(.subheadline) }
                    }
                }
            }
        }
    }
}

private struct SegmentDetailRow: View {
    let segment: TripSegment

    private var details: [String] {
        var parts: [String] = []
        if let train = segment.train {
            let name = [train.name, train.number].compactMap { $0 }.joined(separator: " ")
            if !name.isEmpty { parts.append(name) }
            parts.append(train.category.title)
            if let line = train.line { parts.append(line) }
            if let seatClass = train.seatClass { parts.append(seatClass.title) }
            if let car = train.carNumber { parts.append(String(localized: "Car \(car)")) }
            if let seat = train.seat { parts.append(String(localized: "Seat \(seat)")) }
        }
        if let flight = segment.flight {
            parts.append([flight.airline, flight.flightNumber].compactMap { $0 }.joined(separator: " "))
            if let from = flight.fromIATA, let to = flight.toIATA { parts.append("\(from) → \(to)") }
            if let terminal = flight.terminal { parts.append(String(localized: "Terminal \(terminal)")) }
            if let gate = flight.gate { parts.append(String(localized: "Gate \(gate)")) }
            if let seatClass = flight.seatClass { parts.append(seatClass.title) }
            if let seat = flight.seat { parts.append(String(localized: "Seat \(seat)")) }
            if let reference = flight.bookingRef { parts.append(String(localized: "Ref \(reference)")) }
        }
        return parts
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: segment.mode.systemImage)
                .foregroundStyle(TripStyle.color(for: .out))
                .frame(width: 24)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                if let times = TripTimes.range(segment.departure, segment.arrival) {
                    Text(times).font(.headline).monospacedDigit()
                }
                Text("\(segment.fromName) → \(segment.toName)").font(.subheadline.weight(.semibold))
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let price = segment.price {
                        Text(price.formatted).font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    if let link = segment.sourceUrl.flatMap(URL.init(string:)) {
                        Link(destination: link) {
                            Label("Source", systemImage: "link").font(.caption)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
