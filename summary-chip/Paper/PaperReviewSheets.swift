import SummaryKit
import SwiftUI

// MARK: - Compose

/// The half sheet that follows **Add Review** in the reader's selection menu: the selected
/// passage, and a comment on what to change. Saving asks the paper's agent through MCP.
struct PaperReviewComposeSheet: View {
    let quote: String
    let reviews: PaperReviewModel
    let source: PaperSource?
    @State private var comment = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var failed = 0
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool

    private var canSave: Bool { !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    quoteView
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What should change?")
                            .font(.subheadline.weight(.semibold))
                        TextField("Make this clearer, add a citation, shorten it…", text: $comment, axis: .vertical)
                            .lineLimit(3...8)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .focused($editing)
                            .accessibilityIdentifier("paper-review-comment")
                    }
                    Text("Your agent reads reviews with get_paper_reviews, edits the paper and marks them finished; you then approve the change here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("Add Review")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving { ProgressView() } else { Text("Add") }
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("paper-review-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
        .statusAlert("Couldn't Add Review", message: errorMessage) { errorMessage = nil }
        .sensoryFeedback(.error, trigger: failed)
        .onAppear { editing = true }
        .summarySheetSize()
        .accessibilityIdentifier("paper-review-compose")
    }

    private var quoteView: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(Color.yellow).frame(width: 4)
            Text(quote)
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("paper-review-quote")
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await reviews.add(quote: quote, comment: comment, in: source)
            dismiss()
        } catch {
            failed += 1
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - List

/// Every review of the paper: the ones the agent finished first (tap to read the change and
/// mark it finished), then the ones still waiting, then the finished ones.
struct PaperReviewsSheet: View {
    let reviews: PaperReviewModel
    @State private var path: [PaperReview]
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    /// `initialReview` opens that review's diff right away (deep links and tests).
    init(reviews: PaperReviewModel, initialReview: PaperReview? = nil) {
        self.reviews = reviews
        _path = State(initialValue: initialReview.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                section(reviews.ready, title: String(localized: "Ready to Review"), footer: String(localized: "Your agent edited the paper for these. Read the change and mark the review as finished."))
                section(reviews.open, title: String(localized: "Waiting for Your Agent"), footer: nil)
                section(reviews.resolved, title: String(localized: "Finished"), footer: nil)
            }
            .overlay {
                if reviews.reviews.isEmpty {
                    ContentUnavailableView(
                        "No Reviews", systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(reviews.loadError ?? String(localized: "Select text in the reader and choose Add Review to ask your agent for a change."))
                    )
                }
            }
            .navigationTitle("Reviews")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: PaperReview.self) { review in
                PaperReviewDiffView(review: reviews.reviews.first { $0.id == review.id } ?? review, reviews: reviews) { path = [] }
            }
            .refreshable { await reviews.load() }
        }
        .task { await reviews.load() }
        .statusAlert("Something Went Wrong", message: errorMessage) { errorMessage = nil }
        .summarySheetSize()
        .accessibilityIdentifier("paper-reviews")
    }

    @ViewBuilder
    private func section(_ items: [PaperReview], title: String, footer: String?) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { review in row(review) }
            } header: {
                Text(title)
            } footer: {
                if let footer { Text(footer) }
            }
        }
    }

    private func row(_ review: PaperReview) -> some View {
        Button {
            if review.hasChanges { path = [review] }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: review.status.systemImage)
                    .foregroundStyle(review.status == .addressed ? Color.green : review.status == .resolved ? Color.secondary : Color.accentColor)
                    .frame(width: 22)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(review.comment)
                        .foregroundStyle(.primary)
                    Text("“\(review.quote)”")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let note = review.agentNote, !note.isEmpty {
                        Label(note, systemImage: "sparkles")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(detail(review))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if review.hasChanges {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await attempt { try await reviews.delete(review) } }
            } label: { Label("Delete", systemImage: "trash") }
            if review.status == .resolved || review.status == .addressed {
                Button {
                    Task { await attempt { try await reviews.reopen(review) } }
                } label: { Label("Ask Again", systemImage: "arrow.uturn.backward") }
                .tint(.orange)
            }
        }
        .accessibilityIdentifier("paper-review-\(review.id)")
    }

    private func detail(_ review: PaperReview) -> String {
        var parts = [review.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let file = review.file { parts.append(file) }
        if let addressed = review.addressedVersion { parts.append(String(localized: "v\(review.version) → v\(addressed)")) }
        return parts.joined(separator: " · ")
    }

    private func attempt(_ action: () async throws -> Void) async {
        do { try await action() } catch { errorMessage = error.localizedDescription }
    }
}

// MARK: - Diff

/// What the agent changed for a review, file by file: removed lines in red, added lines in
/// green, with the lines around them. **Mark as Finished** accepts the change.
struct PaperReviewDiffView: View {
    let review: PaperReview
    let reviews: PaperReviewModel
    let onFinished: () -> Void
    @State private var diff: PaperDiff?
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let diff {
                    if diff.isEmpty {
                        ContentUnavailableView("Nothing Changed", systemImage: "equal.circle", description: Text("The paper's source is the same in both versions."))
                    } else {
                        ForEach(diff.files) { file in PaperDiffFileView(file: file) }
                    }
                } else if let loadError {
                    ContentUnavailableView("Couldn't Load the Change", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else {
                    ProgressView("Comparing versions…").frame(maxWidth: .infinity).padding(.vertical, 40)
                }
            }
            .padding(16)
        }
        .background(Color.paperReaderBackground)
        .navigationTitle("Review Changes")
        .summaryInlineNavigationTitle()
        .safeAreaInset(edge: .bottom) {
            if review.status == .addressed {
                Button {
                    Task { await finish() }
                } label: {
                    Label(isSaving ? String(localized: "Finishing…") : String(localized: "Mark as Finished"), systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .padding(16)
                .background(.bar)
                .accessibilityIdentifier("paper-review-finish")
            }
        }
        .task(id: review.id) { await load() }
        .statusAlert("Couldn't Finish Review", message: errorMessage) { errorMessage = nil }
        .accessibilityIdentifier("paper-review-diff")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Capsule().fill(Color.yellow).frame(width: 4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("“\(review.quote)”")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    Text(review.comment)
                        .font(.body.weight(.medium))
                }
            }
            if let note = review.agentNote, !note.isEmpty {
                Label {
                    Text(note)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                }
                .font(.subheadline)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("paper-review-agent-note")
            }
            if let addressed = review.addressedVersion, let diff {
                Text("Version \(review.version) → \(addressed) · +\(diff.added) −\(diff.removed)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if review.status == .resolved {
                Label("Finished", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
    }

    private func load() async {
        do {
            diff = try await reviews.diff(for: review)
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await reviews.resolve(review)
            onFinished()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// One file's hunks, each line with its numbers and a tint for added and removed lines.
private struct PaperDiffFileView: View {
    let file: PaperDiff.File

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isImage ? "photo" : "doc.text")
                Text(file.path).font(.subheadline.weight(.semibold).monospaced())
                Spacer()
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(labelColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(labelColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.08))
            if file.isImage {
                Text(file.change == .modified ? "The image was replaced." : file.change == .added ? "The image was added." : "The image was removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { index, hunk in
                    if index > 0 { Divider().padding(.vertical, 2) }
                    ForEach(hunk.lines) { line in lineView(line) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
        .accessibilityIdentifier("paper-diff-\(file.path)")
    }

    private var label: String {
        switch file.change {
        case .added: String(localized: "Added")
        case .removed: String(localized: "Removed")
        case .modified: "+\(file.added) −\(file.removed)"
        }
    }

    private var labelColor: Color {
        switch file.change {
        case .added: .green
        case .removed: .red
        case .modified: .secondary
        }
    }

    private func lineView(_ line: PaperDiff.Line) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 34, alignment: .trailing)
                .padding(.trailing, 6)
            Text(marker(line))
                .frame(width: 12)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
        .padding(.vertical, 2)
        .padding(.trailing, 8)
        .background(background(line))
    }

    private func marker(_ line: PaperDiff.Line) -> String {
        switch line.kind {
        case .same: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private func background(_ line: PaperDiff.Line) -> Color {
        switch line.kind {
        case .same: .clear
        case .added: Color.green.opacity(0.18)
        case .removed: Color.red.opacity(0.16)
        }
    }
}
