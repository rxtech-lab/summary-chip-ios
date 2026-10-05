import SummaryKit
import SwiftUI

/// Chooses the currency trip costs are also shown in. Applies to every trip on this device.
struct CurrencyConversionSheet: View {
    let defaultCurrency: String
    @Environment(\.dismiss) private var dismiss
    @State private var converter = CurrencyConverter.shared

    private static let currencies: [(code: String, name: String)] = Locale.commonISOCurrencyCodes
        .map { ($0, Locale.current.localizedString(forCurrencyCode: $0) ?? $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    private var isOn: Binding<Bool> {
        Binding(
            get: { converter.target != nil },
            set: { converter.setTarget($0 ? Locale.current.currency?.identifier ?? defaultCurrency : nil) }
        )
    }

    private var currency: Binding<String> {
        Binding(get: { converter.target ?? defaultCurrency }, set: { converter.setTarget($0) })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Convert Totals", isOn: isOn)
                        .accessibilityIdentifier("currency-conversion-toggle")
                    if converter.target != nil {
                        Picker("Currency", selection: currency) {
                            ForEach(Self.currencies, id: \.code) { currency in
                                Text("\(currency.name) (\(currency.code))").tag(currency.code)
                            }
                        }
                        #if os(iOS)
                        .pickerStyle(.navigationLink)
                        #endif
                        .accessibilityIdentifier("currency-conversion-picker")
                    }
                } footer: {
                    Text("Totals in other currencies are also shown converted into this one. Applies to all your trips on this device.")
                }

                if converter.target != nil {
                    Section {
                        if let rates = converter.rates {
                            LabeledContent("Rates From", value: rates.publishedAt.formatted(date: .abbreviated, time: .shortened))
                        } else if !converter.isLoading {
                            Text("No rates yet.").foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await converter.refresh() }
                        } label: {
                            HStack {
                                Text("Refresh Rates")
                                if converter.isLoading {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(converter.isLoading)
                        if let error = converter.lastError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Exchange Rates")
                    } footer: {
                        Link("Rates by Exchange Rate API", destination: CurrencyConverter.attributionURL)
                            .font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Currency Conversion")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: converter.target) { await converter.refreshIfNeeded() }
        }
        .sensoryFeedback(.selection, trigger: converter.target)
        .summarySheetSize()
    }
}
