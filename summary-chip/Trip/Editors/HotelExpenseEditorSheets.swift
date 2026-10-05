import SummaryKit
import SwiftUI

/// Creates or edits a hotel stay. New stays are set as the night's stay for the days they cover
/// that have none yet.
struct HotelEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var hotel: TripHotel

    init(model: TripEditorModel, document: TripDocument, hotel: TripHotel?) {
        self.model = model
        self.document = document
        self.isNew = hotel == nil
        let nextDay = TripDate.dates(from: document.startDate, through: document.endDate).dropFirst().first ?? document.endDate
        _hotel = State(initialValue: hotel ?? TripHotel(id: TripDocument.makeID("hotel"), name: "", checkIn: document.startDate, checkOut: nextDay))
    }

    private var zone: TimeZone { document.resolvedTimeZone }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New Hotel") : String(localized: "Edit Hotel"),
            canSave: hotel.name.nilIfBlank != nil && hotel.checkOut >= hotel.checkIn,
            deleteTitle: isNew ? nil : String(localized: "Delete Hotel"),
            deleteMessage: String(localized: "Days staying here will show no hotel."),
            save: save,
            delete: delete
        ) {
            Section {
                TextField("Name", text: $hotel.name)
                    .accessibilityIdentifier("hotel-name-field")
                Picker("Status", selection: $hotel.status) {
                    ForEach(TripBookingStatus.allCases) { Text($0.title).tag($0) }
                }
                if !document.places.isEmpty {
                    TripPlacePicker(title: String(localized: "Place on map"), selection: $hotel.placeId, places: document.places)
                }
                TextField("Address", text: $hotel.address.text, axis: .vertical)
                    .lineLimit(1...3)
            }
            Section {
                TripDateField(title: String(localized: "Check-in"), value: $hotel.checkIn, timeZone: zone)
                TripDateField(
                    title: String(localized: "Check-out"),
                    value: $hotel.checkOut,
                    timeZone: zone,
                    range: (TripDate.date(from: hotel.checkIn, timeZone: zone) ?? .distantPast)...Date.distantFuture
                )
                TripClockField(title: String(localized: "Check-in time"), value: $hotel.checkInTime)
            }
            .onChange(of: hotel.checkIn) { _, checkIn in
                if hotel.checkOut < checkIn { hotel.checkOut = checkIn }
            }
            Section {
                TextField("Confirmation number", text: $hotel.confirmation.text)
                TripMoneyField(title: String(localized: "Price"), value: $hotel.price, defaultCurrency: document.currency)
                TextField("Website", text: $hotel.url.text, prompt: Text("https://…"))
                    .summaryInputCapitalization()
                    .autocorrectionDisabled()
            }
        }
    }

    private func save() async throws {
        var hotel = hotel
        hotel.name = hotel.name.nilIfBlank ?? hotel.name
        hotel.address = hotel.address?.nilIfBlank
        hotel.confirmation = hotel.confirmation?.nilIfBlank
        hotel.url = hotel.url?.nilIfBlank.flatMap { URL(string: $0)?.scheme?.hasPrefix("http") == true ? $0 : nil }
        let isNew = isNew
        try await model.update { document in
            document.upsert(hotel)
            guard isNew else { return }
            for index in document.days.indices
            where document.days[index].stayId == nil && document.days[index].date >= hotel.checkIn && document.days[index].date < hotel.checkOut {
                document.days[index].stayId = hotel.id
            }
        }
    }

    private func delete() async throws {
        let id = hotel.id
        try await model.update { $0.remove(.hotels, id: id) }
    }
}

/// Creates or edits a cost. A cost can be covered by a pass (left out of totals) and linked to
/// the transport or hotel it pays for.
struct ExpenseEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var expense: TripExpense
    @State private var converter = CurrencyConverter.shared

    init(model: TripEditorModel, document: TripDocument, expense: TripExpense?) {
        self.model = model
        self.document = document
        self.isNew = expense == nil
        _expense = State(initialValue: expense ?? TripExpense(
            id: TripDocument.makeID("expense"),
            category: .food,
            title: "",
            amount: TripMoney(amount: 0, currency: document.currency)
        ))
    }

    private var passes: [TripExpense] {
        document.expenses.filter { $0.category == .pass && $0.id != expense.id }
    }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New Expense") : String(localized: "Edit Expense"),
            canSave: expense.title.nilIfBlank != nil && expense.amount.amount >= 0,
            deleteTitle: isNew ? nil : String(localized: "Delete Expense"),
            save: save,
            delete: delete
        ) {
            Section {
                TextField("Title", text: $expense.title)
                    .accessibilityIdentifier("expense-title-field")
                Picker("Category", selection: $expense.category) {
                    ForEach(TripExpenseCategory.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                TripRequiredMoneyField(title: String(localized: "Amount"), value: $expense.amount)
                if let converted = converter.convert(expense.amount) {
                    LabeledContent("Converted", value: "≈ \(converted.formatted)")
                        .monospacedDigit()
                        .accessibilityIdentifier("expense-converted-amount")
                }
                Toggle("Paid", isOn: $expense.paid)
            }
            Section {
                Picker("Day", selection: $expense.dayId) {
                    Text("None").tag(String?.none)
                    ForEach(document.orderedDays) { day in
                        Text("\(document.dayLabel(day.date)) · \(day.title)").tag(String?.some(day.id))
                    }
                }
                Picker("For", selection: $expense.linkedId) {
                    Text("Nothing specific").tag(String?.none)
                    ForEach(document.transports) { Label($0.label, systemImage: "tram").tag(String?.some($0.id)) }
                    ForEach(document.hotels) { Label($0.name, systemImage: "bed.double").tag(String?.some($0.id)) }
                }
                if expense.category != .pass && !passes.isEmpty {
                    Picker("Covered by", selection: $expense.coveredByExpenseId) {
                        Text("Not covered").tag(String?.none)
                        ForEach(passes) { Text($0.title).tag(String?.some($0.id)) }
                    }
                }
            } footer: {
                Text("Costs covered by a pass are listed but left out of the totals.")
            }
        }
        .onChange(of: expense.dayId) { _, dayID in
            if let day = document.day(id: dayID) { expense.date = day.date }
        }
        .task(id: converter.target) { await converter.refreshIfNeeded() }
    }

    private func save() async throws {
        var expense = expense
        expense.title = expense.title.nilIfBlank ?? expense.title
        if expense.category == .pass { expense.coveredByExpenseId = nil }
        try await model.update { $0.upsert(expense) }
    }

    private func delete() async throws {
        let id = expense.id
        try await model.update { $0.remove(.expenses, id: id) }
    }
}
