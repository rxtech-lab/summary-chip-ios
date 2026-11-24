import SummaryKit
import SwiftUI

struct PlanChatBubble: View {
    let role: PlanMessageRole
    let text: String
    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 60) }
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .foregroundStyle(role == .user ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(role == .user ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary)))
            if role == .assistant { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: role == .user ? .trailing : .leading)
    }
}

/// An earlier plan in the chat, kept as it was when the user asked for a change. Read-only: only the newest plan
/// is edited or confirmed. Its parts expand in place.
struct PlanSnapshotCard: View {
    struct Item: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }
    let revision: Int
    let title: String?
    let summary: String?
    let meta: String
    let itemsTitle: LocalizedStringKey
    let items: [Item]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("EARLIER PLAN", systemImage: "lock.fill").font(.caption2.weight(.bold)).tracking(0.8)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                    .foregroundStyle(.secondary)
                if revision > 0 { Text("Revision \(revision)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(.secondary) }
            }
            if let title {
                Text(title).font(.headline)
                if let summary, !summary.isEmpty {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(expanded ? nil : 3)
                }
                if !items.isEmpty {
                    DisclosureGroup(isExpanded: $expanded.animation()) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(items) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.callout.weight(.semibold))
                                    if !item.detail.isEmpty { Text(item.detail).font(.callout).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(itemsTitle).font(.callout)
                    }
                }
            } else {
                Text("This earlier plan is no longer kept.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.background.secondary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.separator.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .sensoryFeedback(.selection, trigger: expanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Earlier plan, read-only"))
        .accessibilityIdentifier("plan-snapshot-\(revision)")
    }
}

struct PlanWorkingBubble: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.background.secondary))
        .accessibilityIdentifier("podcast-plan-working")
    }
}
