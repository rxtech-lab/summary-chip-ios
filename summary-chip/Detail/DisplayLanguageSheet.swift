import SummaryKit
import SwiftUI

/// Dedicated sheet for the owner's reading language (`PATCH /api/v1/summaries/:id` `displayLanguage`)
/// of a summary or a trip. Picking a language only selects it; Done switches to it. A language
/// without a translation yet is translated (a summary's key points, tags and source text; a trip's
/// whole diary) after the owner confirms. The choice is kept for next time.
struct DisplayLanguageSheet: View {
    /// What is being read: a summary card, or a trip diary (whose translations are read-only).
    enum Kind {
        case summary
        case trip
    }

    let api: SummaryAPIClient
    let id: String
    let kind: Kind
    /// The language it is written in.
    let originalLanguage: String
    /// The language it is shown in now.
    let language: String
    let onSaved: (Summary) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The language to switch to on Done; `.auto` = the summary as written.
    @State private var selection: SummaryLanguage
    /// Languages already translated (`GET …/translations`); nil while loading or when it failed.
    @State private var translated: SummaryTranslations?
    @State private var confirmsTranslation = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// The chosen display language, as shown now.
    private let current: SummaryLanguage

    init(api: SummaryAPIClient, summary: Summary, onSaved: @escaping (Summary) -> Void) {
        self.init(
            api: api, id: summary.id, kind: .summary, originalLanguage: summary.originalLanguage,
            language: summary.language, displayLanguage: summary.displayLanguage, onSaved: onSaved
        )
    }

    init(api: SummaryAPIClient, trip: Trip, onSaved: @escaping (Summary) -> Void) {
        self.init(
            api: api, id: trip.id, kind: .trip, originalLanguage: trip.originalLanguage,
            language: trip.language, displayLanguage: trip.displayLanguage, onSaved: onSaved
        )
    }

    private init(
        api: SummaryAPIClient, id: String, kind: Kind, originalLanguage: String, language: String,
        displayLanguage: String?, onSaved: @escaping (Summary) -> Void
    ) {
        self.api = api
        self.id = id
        self.kind = kind
        self.originalLanguage = originalLanguage
        self.language = language
        self.onSaved = onSaved
        let current = displayLanguage.flatMap(SummaryLanguage.init(languageTag:)) ?? .auto
        self.current = current
        self._selection = State(initialValue: current)
    }

    /// The written language is listed as "Original", not again as a translation.
    private var original: SummaryLanguage? { SummaryLanguage(languageTag: originalLanguage) }
    private var choices: [SummaryLanguage] { SummaryLanguage.translations.filter { $0 != original } }
    private var originalName: String { SummaryLanguage.displayName(for: originalLanguage) }
    private var hasChanges: Bool { selection != current }

    /// Whether `language` has a saved translation (the one shown now always does).
    private func isTranslated(_ language: SummaryLanguage) -> Bool {
        guard language != .auto else { return false }
        if translated?.contains(language) == true { return true }
        return self.language != originalLanguage && SummaryLanguage(languageTag: self.language) == language
    }

    /// A trip translation written before the trip changed: choosing it translates what changed, after asking.
    private func isOutdated(_ language: SummaryLanguage) -> Bool {
        guard kind == .trip, let item = translated?.item(for: language) else { return false }
        return !item.upToDate && !item.translating
    }

    /// Switching to `language` needs no translating: the original, or a translation that is up to date.
    private func switchesAtOnce(_ language: SummaryLanguage) -> Bool {
        language == .auto || (isTranslated(language) && !isOutdated(language))
    }

    private var footer: Text {
        switch kind {
        case .summary:
            Text("Pick a language and choose Done. Languages that aren't translated yet are translated first: the summary, key points, category, tags and source text. Chippy remembers your choice for this summary. People you share it with read it in their own language.")
        case .trip:
            Text("Pick a language and choose Done. Languages that aren't translated yet are translated first: the days, places, transport, notes and views. A translated trip is read-only; switch back to Original to edit it. People you share it with read it in their own language.")
        }
    }

    private var confirmationTitle: Text {
        isOutdated(selection) ? Text("Update the \(selection.title) translation?") : Text("Translate to \(selection.title)?")
    }

    private var confirmationMessage: Text {
        if isOutdated(selection) {
            return Text("The trip changed since it was translated into \(selection.title). Chippy translates what's new or changed; the rest is reused for free. While it's shown translated, the trip can't be edited.")
        }
        return switch kind {
        case .summary:
            Text("Chippy translates the summary, key points, category, tags and source text into \(selection.title). The source text can take a minute to finish.")
        case .trip:
            Text("Chippy translates the trip's days, places, transport, notes and views into \(selection.title). While it's shown translated, the trip can't be edited.")
        }
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
                    footer
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
                confirmationTitle,
                isPresented: $confirmsTranslation,
                titleVisibility: .visible
            ) {
                Button(isOutdated(selection) ? "Update Translation" : "Translate") { Task { await save() } }
                    .accessibilityIdentifier("confirm-translate")
                Button("Cancel", role: .cancel) {}
            } message: {
                confirmationMessage
            }
            .overlay {
                if isSaving {
                    ActionStatusOverlay(switchesAtOnce(selection)
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
                        if translated?.item(for: language)?.translating == true {
                            ChipLabel(String(localized: "Translating…"), systemImage: "hourglass", tint: .secondary)
                                .accessibilityIdentifier("display-language-translating-\(language.rawValue)")
                        } else if isOutdated(language) {
                            ChipLabel(String(localized: "Outdated"), systemImage: "arrow.clockwise", tint: .orange)
                                .accessibilityIdentifier("display-language-outdated-\(language.rawValue)")
                        } else if isTranslated(language) {
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

    /// Unchanged: close. A language that needs translating (or an outdated trip translation
    /// updating) asks first; any other switches at once.
    private func done() {
        guard hasChanges else { return dismiss() }
        if switchesAtOnce(selection) {
            Task { await save() }
        } else {
            confirmsTranslation = true
        }
    }

    private func loadTranslations() async {
        // Without the list every language still works; only the "Translated" marks are missing.
        translated = switch kind {
        case .summary: try? await api.translations(id: id)
        case .trip: try? await api.tripTranslations(id: id)
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await api.updateSummary(id: id, patch: SummaryPatch(displayLanguage: selection))
            onSaved(updated)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
