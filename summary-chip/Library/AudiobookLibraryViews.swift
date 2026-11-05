import SwiftUI
import SummaryKit

struct AudiobooksStrip: View {
    let jobs: [AudiobookJob]
    let plans: [AudiobookPlanSummary]
    let onOpenJob: (AudiobookJob) -> Void
    let onOpenPlan: (AudiobookPlanSummary) -> Void
    let onDeletePlan: (AudiobookPlanSummary) -> Void

    @State private var taps = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Audiobooks", systemImage: "book.closed").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(jobs) { job in
                        Button { taps += 1; onOpenJob(job) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                Text(job.isFailed ? "Generation failed" : job.stageTitle).font(.caption).foregroundStyle(.secondary)
                                if job.isRunning { ProgressView(value: job.fraction) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .modifier(AudiobookStripCardStyle())
                    }
                    ForEach(plans) { plan in
                        HStack {
                            Button { taps += 1; onOpenPlan(plan) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(plan.title).font(.headline).lineLimit(2)
                                    Text("\(plan.chapterCount) chapters").font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu {
                                Button("Review Plan") { onOpenPlan(plan) }
                                Button("Delete Plan", role: .destructive) { onDeletePlan(plan) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Plan Actions")
                        }
                        .modifier(AudiobookStripCardStyle())
                    }
                }
            }.scrollIndicators(.hidden)
        }
        .padding()
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityIdentifier("audiobooks-strip")
    }
}


// Keep recordings and saved plans aligned, regardless of their native button styles.
private struct AudiobookStripCardStyle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var cardHeight = 112

    func body(content: Content) -> some View {
        content
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(width: 296, height: cardHeight, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
