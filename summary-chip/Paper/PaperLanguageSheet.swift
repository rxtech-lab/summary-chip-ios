import SummaryKit
import SwiftUI

/// Paid translation and switching languages belong to one dedicated sheet; the source stays intact.
struct PaperLanguageSheet: View {
    let api: SummaryAPIClient
    let paper: Paper
    let onSaved: (Paper) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SummaryLanguage
    @State private var translations: SummaryTranslations?
    @State private var isSaving = false
    @State private var confirmsTranslation = false
    @State private var errorMessage: String?
    @State private var finished = 0

    init(api: SummaryAPIClient, paper: Paper, onSaved: @escaping (Paper) -> Void) {
        self.api = api
        self.paper = paper
        self.onSaved = onSaved
        _selection = State(initialValue: paper.isTranslated ? SummaryLanguage(languageTag: paper.readingLanguage) ?? .auto : .auto)
    }

    private var needsTranslation: Bool {
        selection != .auto && translations?.item(for: selection)?.upToDate != true
    }

    var body: some View {
        NavigationStack {
            languageForm
                .navigationTitle("Language")
                .summaryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            if needsTranslation { confirmsTranslation = true }
                            else { Task { await save() } }
                        }
                        .fontWeight(.semibold)
                        .disabled(isSaving || translations == nil)
                        .accessibilityIdentifier("paper-language-done")
                    }
                }
                .confirmationDialog(
                    translations?.contains(selection) == true ? Text("Update the \(selection.title) translation?") : Text("Translate to \(selection.title)?"),
                    isPresented: $confirmsTranslation, titleVisibility: .visible
                ) {
                    Button("Translate") { Task { await save() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Chippy translates the paper's title and text using your points. Existing translations are reused; only new or changed text is translated. Equations, references and images are preserved. Switch to Original to edit the paper.")
                }
                .overlay {
                    if isSaving { ActionStatusOverlay(needsTranslation ? String(localized: "Translating…") : String(localized: "Switching language…")) }
                }
                .interactiveDismissDisabled(isSaving)
                .statusAlert("Couldn't Change Language", message: errorMessage) { errorMessage = nil }
                .sensoryFeedback(.selection, trigger: selection)
                .sensoryFeedback(.warning, trigger: confirmsTranslation) { _, shown in shown }
                .sensoryFeedback(.success, trigger: finished)
                .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
        .task { await load() }
    }

    private var languageForm: some View {
        Form {
            Section {
                row(.auto, title: String(localized: "Original"))
            } footer: {
                Text(SummaryLanguage.displayName(for: paper.writtenLanguage))
            }
            Section {
                ForEach(SummaryLanguage.translations.filter { $0 != SummaryLanguage(languageTag: paper.writtenLanguage) }) { language in
                    row(language, title: language.title)
                }
            } header: {
                Text("Translate to")
            } footer: {
                Text("Translations are read-only and become outdated when the original paper changes. Choose an outdated language to update it before exporting.")
            }
            if translations == nil {
                Section {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
    }

    private func row(_ language: SummaryLanguage, title: String) -> some View {
        Button { selection = language } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                if let item = translations?.item(for: language) {
                    ChipLabel(item.upToDate ? String(localized: "Translated") : String(localized: "Outdated"),
                              systemImage: item.upToDate ? "translate" : "arrow.clockwise", tint: item.upToDate ? .accentColor : .orange)
                }
                Spacer()
                if selection == language { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == language ? .isSelected : [])
        .accessibilityIdentifier("paper-language-\(language.rawValue)")
    }

    private func load() async {
        do { translations = try await api.paperTranslations(id: paper.id) }
        catch { errorMessage = error.localizedDescription }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let fresh = try await api.translatePaper(id: paper.id, language: selection)
            finished += 1
            onSaved(fresh)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
