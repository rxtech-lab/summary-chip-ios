import SummaryKit
import SwiftUI

/// Dedicated sheet for the owner's reading language (`PATCH /api/v1/summaries/:id` `displayLanguage`).
/// Picking a language only selects it; Done switches to it. A language without a translation yet is
/// translated (summary, key points, category, tags and source text) after the owner confirms. The choice is kept for
/// next time.
struct DisplayLanguageSheet: View {
    let api: SummaryAPIClient
    let summary: Summary
    let onSaved: (Summary) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The language to switch to on Done; `.auto` = the summary as written.
    @State private var selection: SummaryLanguage
    /// Languages already translated (`GET …/translations`); nil while loading or when it failed.
    @State private var translated: SummaryTranslations?
    @State private var confirmsTranslation = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(api: SummaryAPIClient, summary: Summary, onSaved: @escaping (Summary) -> Void) {
        self.api = api
        self.summary = summary
        self.onSaved = onSaved
        self._selection = State(initialValue: Self.current(summary))
    }

    /// The written language is listed as "Original", not again as a translation.
    private var original: SummaryLanguage? { SummaryLanguage(languageTag: summary.originalLanguage) }
    private var choices: [SummaryLanguage] { SummaryLanguage.translations.filter { $0 != original } }
    private var originalName: String { SummaryLanguage.displayName(for: summary.originalLanguage) }
    private var hasChanges: Bool { selection != Self.current(summary) }

    private static func current(_ summary: Summary) -> SummaryLanguage {
        summary.displayLanguage.flatMap(SummaryLanguage.init(languageTag:)) ?? .auto
    }

    /// Whether `language` has a saved translation (the one shown now always does).
    private func isTranslated(_ language: SummaryLanguage) -> Bool {
        guard language != .auto else { return false }
        if translated?.contains(language) == true { return true }
        return summary.isTranslated && SummaryLanguage(languageTag: summary.language) == language
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row(.auto, title: Text("Original"), detail: Text(originalName))
                }
                Section {
                    ForEach(choices) { language in
                        row(language, title: Text(language.title), detail: nil)
                    }
                } header: {
                    HStack {
                        Text("Translate to")
                        if translated == nil {
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    Text("Pick a language and choose Done. Languages that aren't translated yet are translated first: the summary, key points, category, tags and source text. Chippy remembers your choice for this summary. People you share it with read it in their own language.")
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            .navigationTitle("Language")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                        .accessibilityIdentifier("display-language-done")
                }
            }
            .confirmationDialog(
                "Translate to \(selection.title)?",
                isPresented: $confirmsTranslation,
                titleVisibility: .visible
            ) {
                Button("Translate") { Task { await save() } }
                    .accessibilityIdentifier("confirm-translate")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Chippy translates the summary, key points, category, tags and source text into \(selection.title). The source text can take a minute to finish.")
            }
            .overlay {
                if isSaving {
                    ActionStatusOverlay(isTranslated(selection) || selection == .auto
                        ? String(localized: "Switching language…")
                        : String(localized: "Translating…"))
                }
            }
            .interactiveDismissDisabled(isSaving)
            .statusAlert("Couldn't Change Language", message: errorMessage) { errorMessage = nil }
            .sensoryFeedback(.selection, trigger: selection)
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
        .task { await loadTranslations() }
    }

    private func row(_ language: SummaryLanguage, title: Text, detail: Text?) -> some View {
        Button {
            selection = language
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        title.foregroundStyle(.primary)
                        if isTranslated(language) {
                            ChipLabel(String(localized: "Translated"), systemImage: "translate", tint: .accentColor)
                                .accessibilityIdentifier("display-language-translated-\(language.rawValue)")
                        }
                    }
                    if let detail { detail.font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selection == language {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == language ? .isSelected : [])
        .accessibilityIdentifier("display-language-\(language.rawValue)")
    }

    /// Unchanged: close. A language that needs translating asks first; any other switches at once.
    private func done() {
        guard hasChanges else { return dismiss() }
        if selection == .auto || isTranslated(selection) {
            Task { await save() }
        } else {
            confirmsTranslation = true
        }
    }

    private func loadTranslations() async {
        // Without the list every language still works; only the "Translated" marks are missing.
        translated = try? await api.translations(id: summary.id)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await api.updateSummary(id: summary.id, patch: SummaryPatch(displayLanguage: selection))
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
