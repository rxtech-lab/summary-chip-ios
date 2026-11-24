import SummaryKit
import SwiftUI

/// Unconfirmed podcast plans, scrolling with the feed: open one to keep reviewing it, or delete it.
struct PlannedPodcastsStrip: View {
    @ScaledMetric(relativeTo: .body) private var rowHeight = 110
    let plans: [PodcastPlanSummary]
    let onOpen: (PodcastPlanSummary) -> Void
    let onDelete: (PodcastPlanSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Planned Podcasts", systemImage: "list.bullet.clipboard").font(.subheadline.weight(.semibold))
                Text("\(plans.count)").font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
            }
            .padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(plans) { plan in card(plan) }
                }
                .padding(.horizontal, 16)
            }
            // A horizontal scroll view otherwise claims the whole vertical safe-area inset, hiding the feed.
            .frame(height: rowHeight)
            .scrollIndicators(.hidden)
        }
        .padding(.vertical, 10)
        .background(Color.summaryGroupedBackground)
        .accessibilityIdentifier("planned-podcasts")
    }

    private func card(_ plan: PodcastPlanSummary) -> some View {
        HStack(spacing: 10) {
            Button { onOpen(plan) } label: {
                HStack(spacing: 10) {
                    PlanFrameImage(url: plan.thumbnailUrl, storyboard: false, drawing: false)
                        .frame(width: 96, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PLANNED").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.tint)
                        Text(plan.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        Group {
                            if plan.updatedAt.timeIntervalSince1970 > 0 {
                                Text("\(plan.lineCount) lines · \(plan.updatedAt, format: .relative(presentation: .named))")
                            } else {
                                Text("\(plan.lineCount) lines")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the plan to keep reviewing it")
            .accessibilityIdentifier("planned-podcast-\(plan.id)")
            Menu {
                Button { onOpen(plan) } label: { Label("Review Plan", systemImage: "list.bullet.clipboard") }
                Button(role: .destructive) { onDelete(plan) } label: { Label("Delete Plan", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Plan Actions")
            .accessibilityIdentifier("planned-podcast-actions")
        }
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.4)))
        .contextMenu {
            Button { onOpen(plan) } label: { Label("Review Plan", systemImage: "list.bullet.clipboard") }
            Button(role: .destructive) { onDelete(plan) } label: { Label("Delete Plan", systemImage: "trash") }
        }
    }
}
