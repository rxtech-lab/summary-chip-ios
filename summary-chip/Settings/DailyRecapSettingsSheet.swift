import SwiftUI
import SummaryKit

struct DailyRecapSettingsSheet: View {
    let api: SummaryAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var language: SummaryLanguage = .en
    @State private var hour = 7
    @State private var timeZone = TimeZone.current.identifier
    @State private var settings: DailyRecapSettings?
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Automatic Daily Recap", isOn: $enabled)
                        .accessibilityIdentifier("daily-recap-enabled")
                } footer: {
                    Text("Off by default. When enabled, automatic recap generation consumes your credits. Turn this off and save to stop future automatic recaps.")
                }
                Section {
                    Picker("Language", selection: $language) {
                        ForEach(SummaryLanguage.allCases.filter { $0 != .auto }) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    Picker("Generate at", selection: $hour) {
                        ForEach(0..<24, id: \.self) { value in
                            Text(String(format: "%02d:00", value)).tag(value)
                        }
                    }
                    LabeledContent("Time Zone", value: timeZone)
                    if timeZone != TimeZone.current.identifier {
                        Button("Use Current Time Zone") { timeZone = TimeZone.current.identifier }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("Each day, create a private 1080p video from the previous day’s summary chips. Recaps highlight the main stories and stay under three minutes. Cloud generation continues while the app is closed. Days without chips are skipped.")
                }
                .disabled(!enabled)
                if enabled, let nextAt = settings?.nextAt {
                    Section("Next Recap") {
                        LabeledContent("Next Run", value: nextAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let run = settings?.lastRun {
                    Section("Last Recap") {
                        LabeledContent("Day", value: run.date)
                        LabeledContent("Status", value: statusTitle(run.status))
                        if let message = run.error { Text(message).foregroundStyle(.secondary) }
                        Text("Open that day in the Feed to watch the recap. Video progress is available in Background Jobs.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(loading || saving)
            .navigationTitle("Daily Recap")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(loading || saving || settings == nil)
                        .accessibilityIdentifier("daily-recap-save")
                }
            }
            .overlay {
                if loading || saving {
                    ProgressView(saving ? "Saving schedule…" : "Loading schedule…")
                        .padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                } else if saved {
                    Label("Schedule saved", systemImage: "checkmark.circle.fill")
                        .padding(24).background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .sensoryFeedback(.selection, trigger: enabled)
            .sensoryFeedback(.selection, trigger: hour)
            .sensoryFeedback(.selection, trigger: language)
            .sensoryFeedback(.success, trigger: saved)
            .sensoryFeedback(.error, trigger: error)
            .alert("Daily Recap", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .task { await load() }
        }
        #if os(macOS)
        .frame(width: 520, height: 580)
        #endif
    }

    private func statusTitle(_ status: String) -> String {
        switch status {
        case "queued": String(localized: "Queued")
        case "generating": String(localized: "Generating audio")
        case "rendering": String(localized: "Designing or rendering video")
        case "ready": String(localized: "Ready")
        case "skipped": String(localized: "Skipped")
        case "failed": String(localized: "Needs attention")
        default: String(localized: "Needs attention")
        }
    }

    private func load() async {
        defer { loading = false }
        do {
            let value = try await api.dailyRecapSettings()
            settings = value
            enabled = value.enabled
            language = SummaryLanguage(rawValue: value.language) ?? .en
            hour = value.hour
            if value.enabled || value.lastRun != nil { timeZone = value.timeZone }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            settings = try await api.saveDailyRecapSettings(enabled: enabled, timeZone: timeZone, language: language.rawValue, hour: hour)
            saved = true
            try? await Task.sleep(for: .milliseconds(900))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
