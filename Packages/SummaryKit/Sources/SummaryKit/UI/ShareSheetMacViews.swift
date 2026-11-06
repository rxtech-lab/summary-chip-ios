#if os(macOS)
import SwiftUI

/// The summary being shared, at the top of the macOS share sheet. Someone who doesn't own it sees
/// the link they'd share here, since they have no link controls below.
struct ShareSheetHeader: View {
    let summary: Summary
    let showsLink: Bool

    var body: some View {
        HStack(spacing: 14) {
            SummaryOGImage(summary: summary)
                .frame(width: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.title)
                    .font(.headline)
                    .lineLimit(2)
                if showsLink {
                    Text(summary.shareUrl.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    Text(summary.sourceLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// Who can open a link, when it expires and its address, with an optional action at the trailing edge.
struct ShareLinkStatusRow<Trailing: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let expiresAt: Date?
    let showsExpiry: Bool
    let url: URL
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            ShareLinkIcon(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).lineLimit(1)
                    if showsExpiry { ExpiryLabel(expiresAt) }
                }
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}
#endif
