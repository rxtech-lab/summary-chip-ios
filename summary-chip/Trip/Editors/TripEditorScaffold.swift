import SummaryKit
import SwiftUI

/// Shared chrome for the trip's create/edit sheets: a form with Cancel / Save, a status overlay
/// while saving or deleting, a confirmation before deleting, and success / error haptics.
/// `save` and `delete` throw to keep the sheet open with the error.
struct TripEditorScaffold<Content: View>: View {
    let title: String
    var canSave = true
    /// "Delete Day", … Nil hides the delete button (new records).
    var deleteTitle: String?
    var deleteMessage: String?
    var savingMessage = String(localized: "Saving…")
    let save: () async throws -> Void
    var delete: (() async throws -> Void)?
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var succeeded = 0
    @State private var failed = 0

    private var isBusy: Bool { status != nil }

    var body: some View {
        NavigationStack {
            Form {
                content()
                #if !os(macOS)
                if let deleteTitle, delete != nil {
                    Section {
                        Button(deleteTitle, role: .destructive) { confirmsDelete = true }
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("trip-editor-delete")
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isBusy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await run(savingMessage, save) } }
                        .fontWeight(.semibold)
                        .disabled(!canSave || isBusy)
                        .accessibilityIdentifier("trip-editor-save")
                }
                #if os(macOS)
                // macOS sheets show no primary-action toolbar; delete sits at the leading end of
                // the bottom bar, across from Cancel / Save.
                if let deleteTitle, delete != nil {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(deleteTitle, systemImage: "trash", role: .destructive) { confirmsDelete = true }
                            .help(deleteTitle)
                            .disabled(isBusy)
                            .accessibilityIdentifier("trip-editor-delete")
                    }
                }
                #endif
            }
            .confirmationDialog(deleteTitle ?? "", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(deleteTitle ?? String(localized: "Delete"), role: .destructive) {
                    guard let delete else { return }
                    Task { await run(String(localized: "Deleting…"), delete) }
                }
            } message: {
                if let deleteMessage { Text(deleteMessage) }
            }
        }
        .overlay {
            if let status { ActionStatusOverlay(status) }
        }
        .interactiveDismissDisabled(isBusy)
        .statusAlert("Couldn't Save", message: errorMessage) { errorMessage = nil }
        .sensoryFeedback(.success, trigger: succeeded)
        .sensoryFeedback(.error, trigger: failed)
        .summarySheetSize()
    }

    private func run(_ message: String, _ action: () async throws -> Void) async {
        status = message
        do {
            try await action()
            status = nil
            succeeded += 1
            dismiss()
        } catch {
            status = nil
            failed += 1
            errorMessage = error.localizedDescription
        }
    }
}

/// A `YYYY-MM-DD` document date edited with a date picker in the trip's time zone.
struct TripDateField: View {
    let title: String
    @Binding var value: String
    let timeZone: TimeZone
    var range: ClosedRange<Date>?

    var body: some View {
        let binding = Binding<Date>(
            get: { TripDate.date(from: value, timeZone: timeZone) ?? Date() },
            set: { value = TripDate.string(from: $0, timeZone: timeZone) }
        )
        Group {
            if let range {
                DatePicker(title, selection: binding, in: range, displayedComponents: .date)
            } else {
                DatePicker(title, selection: binding, displayedComponents: .date)
            }
        }
        .environment(\.timeZone, timeZone)
    }
}

/// An optional `YYYY-MM-DDTHH:mm` local time: a toggle, then a date and time picker.
struct TripLocalTimeField: View {
    let title: String
    @Binding var value: String?
    let timeZone: TimeZone
    /// `YYYY-MM-DD` the picker starts on when the time is first set.
    let defaultDate: String

    var body: some View {
        let isSet = Binding<Bool>(
            get: { value != nil },
            set: { value = $0 ? (value ?? "\(defaultDate)T09:00") : nil }
        )
        let date = Binding<Date>(
            get: { value.flatMap { TripDate.localDateTime(from: $0, timeZone: timeZone) } ?? Date() },
            set: { value = TripDate.localDateTimeString(from: $0, timeZone: timeZone) }
        )
        Toggle(title, isOn: isSet.animation())
        if value != nil {
            DatePicker(title, selection: date)
                .labelsHidden()
                .environment(\.timeZone, timeZone)
        }
    }
}

/// An optional `HH:mm` clock time.
struct TripClockField: View {
    let title: String
    @Binding var value: String?

    var body: some View {
        let utc = TimeZone(identifier: "UTC") ?? .current
        let isSet = Binding<Bool>(
            get: { value != nil },
            set: { value = $0 ? (value ?? "09:00") : nil }
        )
        let date = Binding<Date>(
            get: { value.flatMap { TripDate.localDateTime(from: "2000-01-01T\($0)", timeZone: utc) } ?? Date() },
            set: { value = TripDate.clockString(from: $0, timeZone: utc) }
        )
        Toggle(title, isOn: isSet.animation())
        if value != nil {
            DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.timeZone, utc)
        }
    }
}

/// Optional money: amount and ISO currency.
struct TripMoneyField: View {
    let title: String
    @Binding var value: TripMoney?
    let defaultCurrency: String

    var body: some View {
        let amount = Binding<Double?>(
            get: { value?.amount },
            set: { newValue in
                if let newValue {
                    value = TripMoney(amount: max(0, newValue), currency: value?.currency ?? defaultCurrency)
                } else {
                    value = nil
                }
            }
        )
        let currency = Binding<String>(
            get: { value?.currency ?? defaultCurrency },
            set: { code in if value != nil { value?.currency = code } }
        )
        LabeledContent(title) {
            HStack {
                TextField(title, value: amount, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                CurrencyPicker(selection: currency)
                    .disabled(value == nil)
            }
        }
    }
}

/// A required money amount.
struct TripRequiredMoneyField: View {
    let title: String
    @Binding var value: TripMoney

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: $value.amount, format: .number)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                CurrencyPicker(selection: $value.currency)
            }
        }
    }
}

/// ISO 4217 codes, common ones first.
struct CurrencyPicker: View {
    @Binding var selection: String

    static let common = ["JPY", "USD", "EUR", "GBP", "CNY", "HKD", "TWD", "KRW", "SGD", "AUD", "CAD", "CHF", "THB"]
    static let all: [String] = {
        let codes = Set(Locale.commonISOCurrencyCodes)
        return common + codes.subtracting(common).sorted()
    }()

    var body: some View {
        Picker("Currency", selection: $selection) {
            if !Self.all.contains(selection) { Text(selection).tag(selection) }
            ForEach(Self.all, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Picks one of the trip's places, or none.
struct TripPlacePicker: View {
    let title: String
    @Binding var selection: String?
    let places: [TripPlace]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(String?.none)
            ForEach(places) { place in
                Label(place.name, systemImage: place.kind.systemImage).tag(String?.some(place.id))
            }
        }
    }
}

extension Binding where Value == String? {
    /// Edits an optional string as text; blank text stores nil.
    var text: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
