import SwiftUI
import SummaryKit

struct AudiobooksStrip: View {
    let jobs: [AudiobookJob]
    let plans: [AudiobookPlanSummary]
    let onOpenJob: (AudiobookJob) -> Void
    let onOpenPlan: (AudiobookPlanSummary) -> Void
    let onDeletePlan: (AudiobookPlanSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Audiobooks", systemImage: "book.closed").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(jobs) { job in
                        Button { onOpenJob(job) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.title).font(.headline).lineLimit(2)
                                Text(job.isFailed ? "Generation failed" : job.stageTitle).font(.caption)
                                if job.isRunning { ProgressView(value: job.fraction) }
                            }.frame(width: 240, alignment: .leading).padding()
                        }.buttonStyle(.bordered)
                    }
                    ForEach(plans) { plan in
                        HStack {
                            Button { onOpenPlan(plan) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(plan.title).font(.headline).lineLimit(2)
                                    Text("\(plan.chapterCount) chapters").font(.caption)
                                }.frame(width: 220, alignment: .leading)
                            }.buttonStyle(.plain)
                            Menu {
                                Button("Review Plan") { onOpenPlan(plan) }
                                Button("Delete Plan", role: .destructive) { onDeletePlan(plan) }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("Plan Actions")
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }.scrollIndicators(.hidden)
        }.padding().accessibilityIdentifier("audiobooks-strip")
    }
}
