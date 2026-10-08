import AgentMarkdownUI
import SummaryKit
import SwiftUI

/// The summary's source, kept as Markdown on the server, rendered for reading.
/// The owner can switch the reading language from here (`PATCH displayLanguage`), as in `DisplayLanguageSheet`.
struct SourceMarkdownSheet: View {
    let api: SummaryAPIClient
    /// Called with the saved summary after the owner switches language; nil for others' summaries.
    var onLanguageChanged: ((Summary) -> Void)?
    @State private var summary: Summary
    @Environment(\.dismiss) private var dismiss
    @State private var markdown: String?
    /// The translation into the reader's language is still being written; `markdown` is the original.
    @State private var translationPending = false
    /// The language `markdown` is in; nil until loaded (or from older servers).
    @State private var language: String?
    @State private var errorMessage: String?
    @State private var attempt = 0
    /// Languages already translated (`GET …/translations`); nil while loading or when it failed.
    @State private var translated: SummaryTranslations?
    /// A language without a translation yet, waiting for the owner to confirm translating it.
    @State private var pendingLanguage: SummaryLanguage?
    @State private var isSwitching = false
    @State private var switchError: String?

    init(api: SummaryAPIClient, summary: Summary, onLanguageChanged: ((Summary) -> Void)? = nil) {
        self.api = api
        self.onLanguageChanged = onLanguageChanged
        self._summary = State(initialValue: summary)
    }

    var body: some View {
        NavigationStack {
            sourceContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(summary.sourceTitle ?? summary.title)
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #endif
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if onLanguageChanged != nil {
                    ToolbarItem(placement: Self.sharePlacement) {
                        languageMenu
                    }
                }
                if let markdown {
                    ToolbarItem(placement: Self.sharePlacement) {
                        ShareLink(item: markdown, preview: SharePreview(summary.sourceTitle ?? summary.title)) {
                            Label("Share Source", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .confirmationDialog(
                "Translate to \(pendingLanguage?.title ?? "")?",
                isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } }),
                titleVisibility: .visible,
                presenting: pendingLanguage
            ) { language in
                Button("Translate") { Task { await switchLanguage(to: language) } }
                    .accessibilityIdentifier("source-confirm-translate")
                Button("Cancel", role: .cancel) {}
            } message: { language in
                Text("Chippy translates the summary, key points, category, tags and source text into \(language.title). The source text can take a minute to finish.")
            }
            .overlay {
                if isSwitching { ActionStatusOverlay(String(localized: "Switching language…")) }
            }
            .statusAlert("Couldn't Change Language", message: switchError) { switchError = nil }
        }
        .summarySheetSize()
        .interactiveDismissDisabled(isSwitching)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .sensoryFeedback(.error, trigger: switchError) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: summary.displayLanguage)
        .task(id: attempt) { await load() }
        .task { if onLanguageChanged != nil { translated = try? await api.translations(id: summary.id) } }
        .task(id: translationPending) { await pollTranslation() }
        .sensoryFeedback(.success, trigger: translationPending) { old, new in old && !new }
    }

    private var sourceContent: some View {
        Group {
            if let markdown {
                ScrollView {
                    if let language, language != summary.originalLanguage, !translationPending {
                        Label("Translated from \(SummaryLanguage.displayName(for: summary.originalLanguage)) to \(SummaryLanguage.displayName(for: language))", systemImage: "translate")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 700, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("source-translated-note")
                    }
                    if translationPending {
                        Label("Translating the source text… Showing the original for now.", systemImage: "translate")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 700, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("source-translation-pending")
                    }
                    MarkdownView(text: markdown, baseURL: summary.sourceUrl, style: Self.documentStyle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                        .frame(maxWidth: 700, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("source-markdown")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Source unavailable", systemImage: "doc.plaintext")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { attempt += 1 }
                }
            } else {
                ProgressView("Loading source…")
            }
        }
    }

    /// Reading typography: a larger body with airy lines and paragraph spacing, like a printed article.
    private static let documentStyle = MarkdownStyle(
        bodyFontSize: documentFontSize,
        lineSpacing: 6,
        blockSpacing: 16,
        cornerRadius: 10
    )

    #if os(macOS)
    private static let documentFontSize: CGFloat = 15
    /// `.primaryAction` lands in a Mac sheet's bottom bar; `.automatic` keeps Share in the top toolbar.
    private static let sharePlacement: ToolbarItemPlacement = .automatic
    #else
    private static let documentFontSize: CGFloat = 17
    private static let sharePlacement: ToolbarItemPlacement = .primaryAction
    #endif

    private var currentLanguage: SummaryLanguage {
        summary.displayLanguage.flatMap(SummaryLanguage.init(languageTag:)) ?? .auto
    }

    /// Whether `language` has a saved translation (the one shown now always does).
    private func isTranslated(_ language: SummaryLanguage) -> Bool {
        guard language != .auto else { return false }
        if translated?.contains(language) == true { return true }
        return summary.isTranslated && SummaryLanguage(languageTag: summary.language) == language
    }

    /// Original, saved translations, then languages that would be translated first (after confirming).
    private var languageMenu: some View {
        let original = SummaryLanguage(languageTag: summary.originalLanguage)
        let choices = SummaryLanguage.translations.filter { $0 != original }
        let selection = Binding(get: { currentLanguage }, set: { pick($0) })
        return Menu {
            Picker("Language", selection: selection) {
                Text("Original (\(SummaryLanguage.displayName(for: summary.originalLanguage)))").tag(SummaryLanguage.auto)
            }
            let saved = choices.filter(isTranslated)
            if !saved.isEmpty {
                Section("Translated") {
                    Picker("Translated", selection: selection) {
                        ForEach(saved) { Text($0.title).tag($0) }
                    }
                }
            }
            Section("Translate to") {
                Picker("Translate to", selection: selection) {
                    ForEach(choices.filter { !isTranslated($0) }) { Text($0.title).tag($0) }
                }
            }
        } label: {
            Label("Language", systemImage: "translate")
        }
        .pickerStyle(.inline)
        .disabled(isSwitching)
        .accessibilityIdentifier("source-language")
    }

    /// A saved translation (or the original) switches at once; any other language asks first.
    private func pick(_ language: SummaryLanguage) {
        guard language != currentLanguage else { return }
        if language == .auto || isTranslated(language) {
            Task { await switchLanguage(to: language) }
        } else {
            pendingLanguage = language
        }
    }

    private func switchLanguage(to language: SummaryLanguage) async {
        isSwitching = true
        defer { isSwitching = false }
        do {
            let updated = try await api.updateSummary(id: summary.id, patch: SummaryPatch(displayLanguage: language))
            summary = updated
            onLanguageChanged?(updated)
            translated = try? await api.translations(id: summary.id)
            await load()
        } catch {
            switchError = error.localizedDescription
        }
    }

    /// Swaps in the translated document once the server has written it.
    private func pollTranslation() async {
        while translationPending {
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            await load()
        }
    }

    #if os(macOS)
    /// The document's language in the Mac window's subtitle.
    private var subtitle: String {
        if translationPending { return String(localized: "Translating…") }
        guard let language else { return "" }
        return SummaryLanguage.displayName(for: language)
    }
    #endif

    private func load() async {
        errorMessage = nil
        do {
            let document = try await api.sourceDocument(id: summary.id)
            markdown = document.markdown
            translationPending = document.translationPending
            language = document.language
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
