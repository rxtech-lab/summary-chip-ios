#if os(iOS) || os(macOS)
import QuickLook
import SwiftUI

/// Read-only body of a summary, in the feed's tile language: OG image hero, a large title,
/// the owner's sharing status, then the summary, key points, tags and source as soft cards.
/// Used by the app's detail screen and the App Clip.
public struct SummaryDetailContent: View {
    let summary: Summary
    let onEditSharing: (() -> Void)?
    let onChangeLanguage: (() -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(\.summaryAssetLoader) private var loader
    @State private var previewFile: URL?
    @State private var isOpeningSource = false
    @State private var sourceError: String?

    /// - Parameters:
    ///   - onEditSharing: When set, the owner's sharing card becomes a button that
    ///     calls it (the app opens its Edit Sharing sheet).
    ///   - onChangeLanguage: When set, the "Translated from…" note becomes a button that calls it
    ///     (the app opens its Language sheet).
    public init(summary: Summary, onEditSharing: (() -> Void)? = nil, onChangeLanguage: (() -> Void)? = nil) {
        self.summary = summary
        self.onEditSharing = onEditSharing
        self.onChangeLanguage = onChangeLanguage
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SummaryOGImage(summary: summary)
                .clipShape(DetailTile.shape)
                .overlay { DetailTile.shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.1), radius: 16, y: 6)

            header
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

            if summary.isOwner { sharingCard }

            if !summary.summary.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    DetailSectionLabel("Summary")
                    Text(summary.summary)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .modifier(DetailTile())
            }

            if !summary.highlights.isEmpty { highlightsCard }

            if !summary.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(summary.tags, id: \.self) { tag in
                        ChipLabel("#\(tag)")
                    }
                }
                .padding(.horizontal, 6)
            }

            if summary.originalURL != nil { sourceCard }
        }
        .quickLookPreview($previewFile)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChipLabel(summary.category, tint: summary.theme.accentColor)
                ChipLabel(summary.source.title, image: summary.source.image)
                    .accessibilityLabel(Text("Source: \(summary.source.title)", bundle: .module))
                Text(summary.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(summary.title)
                .font(.largeTitle.weight(.bold))
                .kerning(-0.8)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            Label { Text(summary.sourceLabel) } icon: { summary.source.image }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if summary.translationPending {
                Label {
                    Text("Translating into your language…", bundle: .module)
                } icon: {
                    ProgressView().controlSize(.mini)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("summary-translation-pending")
            } else if summary.isTranslated {
                translationNote
            }
        }
    }

    @ViewBuilder
    private var translationNote: some View {
        let original = SummaryLanguage.displayName(for: summary.originalLanguage)
        let label = Label {
            Text("Translated from \(original) to \(SummaryLanguage.displayName(for: summary.language))", bundle: .module)
        } icon: {
            Image(systemName: "translate")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
        if let onChangeLanguage {
            Button(action: onChangeLanguage) {
                HStack(spacing: 4) {
                    label
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Change language", bundle: .module))
            .accessibilityIdentifier("summary-translated-note")
        } else {
            label.accessibilityIdentifier("summary-translated-note")
        }
    }

    @ViewBuilder
    private var sharingCard: some View {
        let content = HStack(spacing: 0) {
            SharingStat(title: "Link") { VisibilityBadge(summary.visibility) }
            Divider().frame(height: 36)
            SharingStat(title: "Link expiry") { ExpiryLabel(summary.expiresAt).lineLimit(1) }
            Divider().frame(height: 36)
            SharingStat(title: "Views") {
                Label(summary.viewCount.formatted(), systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("\(summary.viewCount) views", bundle: .module))
            }
            if onEditSharing != nil {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                    .accessibilityHidden(true)
            }
        }
        .modifier(DetailTile(padding: 14))

        if let onEditSharing {
            Button(action: onEditSharing) { content.contentShape(DetailTile.shape) }
                .buttonStyle(DetailPressStyle())
                .accessibilityHint(Text("Edit sharing", bundle: .module))
                .accessibilityIdentifier("edit-sharing-card")
        } else {
            content
        }
    }

    private var highlightsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSectionLabel("Key points")
            ForEach(Array(summary.highlights.enumerated()), id: \.offset) { index, highlight in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(summary.theme.accentColor)
                        .frame(width: 24, height: 24)
                        .background(summary.theme.accentColor.opacity(0.14), in: Circle())
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        .accessibilityHidden(true)
                    Text(highlight)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .modifier(DetailTile())
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await openOriginal() }
            } label: {
                HStack(spacing: 14) {
                    summary.source.image
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(summary.theme.foreground)
                        .frame(width: 44, height: 44)
                        .background { ThemeArtwork(theme: summary.theme) }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Read the original", bundle: .module)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(summary.sourceTitle ?? summary.sourceLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if isOpeningSource {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.up.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .modifier(DetailTile(padding: 14))
                .contentShape(DetailTile.shape)
            }
            .buttonStyle(DetailPressStyle())
            .disabled(isOpeningSource)
            if let sourceError {
                Text(sourceError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func openOriginal() async {
        // Owner PDFs go through the authorised loader (private summaries 404 without a token).
        if summary.sourceType == .pdf, summary.isOwner, summary.sourceFileUrl != nil, summary.sourceUrl == nil {
            isOpeningSource = true
            defer { isOpeningSource = false }
            do {
                previewFile = try await loader.downloadSourceFile(for: summary)
                sourceError = nil
            } catch {
                sourceError = error.localizedDescription
            }
            return
        }
        if let url = summary.originalURL { openURL(url) }
    }
}

/// The feed tile's surface: soft card on the grouped background with a hairline and shadow.
struct DetailTile: ViewModifier {
    static let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.summaryCardBackground, in: Self.shape)
            .overlay { Self.shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

private struct DetailSectionLabel: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text, bundle: .module)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SharingStat<Value: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let value: Value

    var body: some View {
        VStack(spacing: 6) {
            Text(title, bundle: .module)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            value
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct DetailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
#endif
