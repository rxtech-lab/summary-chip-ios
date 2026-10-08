import SummaryKit
import SwiftUI

/// What a highlighted reference's check found, shown over the PDF when the reference is hovered or tapped.
struct PaperReferencePopover: View {
    let reference: PaperReference

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(reference.issue?.title ?? String(localized: "Reference error"), systemImage: reference.issue?.systemImage ?? "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(.red)
            if let title = reference.title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            if let message = reference.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(reference.key) · \(reference.location)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding()
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paper-reference-popover")
    }
}

/// Every bibliography entry with its fact-check, problems first; choosing one opens its entry.
struct PaperReferencesSheet: View {
    let model: PaperEditorModel
    let onOpen: (PaperReference) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var references: [PaperReference] { model.references }
    private var errors: [PaperReference] { references.filter(\.isError) }
    private var others: [PaperReference] { references.filter { !$0.isError } }

    var body: some View {
        NavigationStack {
            List {
                if !errors.isEmpty {
                    Section {
                        ForEach(errors) { row($0) }
                    } header: {
                        Text("Needs Attention")
                    } footer: {
                        Text("These references didn't hold up. Correct them, replace them with a reliable source, or remove them. Saving the paper checks changed entries again.")
                    }
                }
                if !others.isEmpty {
                    Section(errors.isEmpty ? "References" : "Other References") {
                        ForEach(others) { row($0) }
                    }
                }
            }
            .overlay {
                if references.isEmpty {
                    ContentUnavailableView("No References", systemImage: "books.vertical", description: Text("Add entries to a .bib file or a thebibliography, and they're checked as you save."))
                }
            }
            .navigationTitle("References")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .summarySheetSize()
        .accessibilityIdentifier("paper-references")
    }

    private func row(_ reference: PaperReference) -> some View {
        Button {
            onOpen(reference)
            dismiss()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                PaperReferenceStatusIcon(reference: reference)
                VStack(alignment: .leading, spacing: 3) {
                    Text(reference.title ?? reference.key)
                        .lineLimit(2)
                    if reference.isError, let issue = reference.issue {
                        Text(issue.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    if reference.isError, let message = reference.message {
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(reference.key) · \(reference.location)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let link = reference.link {
                Button { openURL(link) } label: { Label("Open Link", systemImage: "safari") }
            }
        }
        .accessibilityIdentifier("paper-reference-\(reference.key)")
    }
}

private struct PaperReferenceStatusIcon: View {
    let reference: PaperReference

    var body: some View {
        switch reference.status {
        case .verified:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                .accessibilityLabel("Verified")
        case .error:
            Image(systemName: reference.issue?.systemImage ?? "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel("Reference error")
        case .checking:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Checking")
        case .unchecked:
            Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                .accessibilityLabel("Not checked yet")
        }
    }
}

/// The preview's reference status: errors to review, or the checks running.
struct PaperReferenceStatusButton: View {
    let model: PaperEditorModel
    let action: () -> Void

    var body: some View {
        let errors = model.referenceErrors.count
        if errors > 0 || model.isCheckingReferences {
            Button(action: action) {
                Group {
                    if errors > 0 {
                        Label(errors == 1 ? String(localized: "1 reference error") : String(localized: "\(errors) reference errors"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Label { Text("Checking references…") } icon: { ProgressView().controlSize(.small) }
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityIdentifier("paper-references-button")
        }
    }
}
