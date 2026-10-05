import SummaryKit
import SwiftUI

/// Title, dates, time zone and currency shared by the meta editor and "New Trip".
struct TripMetaFields: View {
    @Binding var title: String
    @Binding var subtitle: String?
    @Binding var intro: String?
    @Binding var startDate: String
    @Binding var endDate: String
    @Binding var timeZone: String
    @Binding var currency: String

    private var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    var body: some View {
        Section {
            TextField("Title", text: $title)
                .accessibilityIdentifier("trip-title-field")
            TextField("Subtitle", text: $subtitle.text)
            TextField("Introduction", text: $intro.text, axis: .vertical)
                .lineLimit(2...6)
        }
        Section {
            TripDateField(title: String(localized: "Starts"), value: $startDate, timeZone: zone)
            TripDateField(
                title: String(localized: "Ends"),
                value: $endDate,
                timeZone: zone,
                range: (TripDate.date(from: startDate, timeZone: zone) ?? .distantPast)...Date.distantFuture
            )
        } footer: {
            Text("Dates and times in this trip are local to its time zone.")
        }
        Section {
            Picker("Time Zone", selection: $timeZone) {
                ForEach(TimeZonePickerOptions.identifiers(including: timeZone), id: \.self) { identifier in
                    Text(TimeZonePickerOptions.title(for: identifier)).tag(identifier)
                }
            }
            LabeledContent("Currency") { CurrencyPicker(selection: $currency) }
        }
        .onChange(of: startDate) { _, start in
            if endDate < start { endDate = start }
        }
    }
}

enum TimeZonePickerOptions {
    static func identifiers(including current: String) -> [String] {
        var all = TimeZone.knownTimeZoneIdentifiers
        if !all.contains(current) { all.insert(current, at: 0) }
        return all
    }

    /// "Asia/Tokyo (GMT+9)".
    static func title(for identifier: String) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let city = identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
        let offset = zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.abbreviation() ?? ""
        return "\(city) (\(offset))"
    }
}

/// Edits the trip's title, dates, time zone and currency; also where the trip is deleted.
struct TripMetaEditorSheet: View {
    let model: TripEditorModel
    let onDeleted: () -> Void

    @State private var title: String
    @State private var subtitle: String?
    @State private var intro: String?
    @State private var startDate: String
    @State private var endDate: String
    @State private var timeZone: String
    @State private var currency: String

    init(model: TripEditorModel, document: TripDocument, onDeleted: @escaping () -> Void) {
        self.model = model
        self.onDeleted = onDeleted
        _title = State(initialValue: document.title)
        _subtitle = State(initialValue: document.subtitle)
        _intro = State(initialValue: document.intro)
        _startDate = State(initialValue: document.startDate)
        _endDate = State(initialValue: document.endDate)
        _timeZone = State(initialValue: document.timeZone)
        _currency = State(initialValue: document.currency)
    }

    var body: some View {
        TripEditorScaffold(
            title: String(localized: "Trip Details"),
            canSave: title.nilIfBlank != nil && endDate >= startDate,
            deleteTitle: String(localized: "Delete Trip"),
            deleteMessage: String(localized: "The trip, its diary and its share link are deleted. This can't be undone."),
            save: save,
            delete: delete
        ) {
            TripMetaFields(
                title: $title, subtitle: $subtitle, intro: $intro, startDate: $startDate,
                endDate: $endDate, timeZone: $timeZone, currency: $currency
            )
        }
    }

    private func save() async throws {
        let title = title.nilIfBlank ?? title
        let subtitle = subtitle?.nilIfBlank, intro = intro?.nilIfBlank
        let (startDate, endDate, timeZone, currency) = (startDate, endDate, timeZone, currency)
        try await model.update { document in
            document.title = title
            document.subtitle = subtitle
            document.intro = intro
            document.startDate = startDate
            document.endDate = endDate
            document.timeZone = timeZone
            document.currency = currency
        }
    }

    private func delete() async throws {
        try await model.delete()
        onDeleted()
    }
}

/// "New Trip": the basics, then `POST /api/v1/trips`; optionally one empty diary day per date.
struct NewTripSheet: View {
    let api: SummaryAPIClient
    let onCreated: (Trip) -> Void

    @State private var title = ""
    @State private var subtitle: String?
    @State private var intro: String?
    @State private var startDate: String
    @State private var endDate: String
    @State private var timeZone = TimeZone.current.identifier
    @State private var currency = Locale.current.currency?.identifier ?? "USD"
    @State private var addsDays = true
    @State private var visibility: SummaryVisibility = .private

    init(api: SummaryAPIClient, onCreated: @escaping (Trip) -> Void) {
        self.api = api
        self.onCreated = onCreated
        let today = TripDate.string(from: Date(), timeZone: .current)
        let inAWeek = TripDate.string(from: Date().addingTimeInterval(6 * 86_400), timeZone: .current)
        _startDate = State(initialValue: today)
        _endDate = State(initialValue: inAWeek)
    }

    private var dayCount: Int { TripDate.dates(from: startDate, through: endDate).count }

    var body: some View {
        TripEditorScaffold(
            title: String(localized: "New Trip"),
            canSave: title.nilIfBlank != nil && endDate >= startDate,
            savingMessage: String(localized: "Creating trip…"),
            save: create
        ) {
            TripMetaFields(
                title: $title, subtitle: $subtitle, intro: $intro, startDate: $startDate,
                endDate: $endDate, timeZone: $timeZone, currency: $currency
            )
            Section {
                Toggle(isOn: $addsDays) {
                    Text("Add a day for each date")
                    Text(dayCount == 1 ? String(localized: "1 day") : String(localized: "\(dayCount) days"))
                }
                Picker("Visibility", selection: $visibility) {
                    ForEach(SummaryVisibility.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Share a booking or timetable to Chippy later and the agent fills the trip in.")
            }
        }
    }

    private func create() async throws {
        var document = TripDocument(
            title: title.nilIfBlank ?? title,
            subtitle: subtitle?.nilIfBlank,
            intro: intro?.nilIfBlank,
            startDate: startDate,
            endDate: endDate,
            timeZone: timeZone,
            currency: currency
        )
        if addsDays {
            document.days = TripDate.dates(from: startDate, through: endDate).enumerated().map { index, date in
                TripDay(id: TripDocument.makeID("day"), date: date, title: String(localized: "Day \(index + 1)"))
            }
        }
        let trip = try await api.createTrip(document: document, visibility: visibility)
        onCreated(trip)
    }
}
