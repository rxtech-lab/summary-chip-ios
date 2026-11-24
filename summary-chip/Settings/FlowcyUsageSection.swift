import SummaryKit
import SwiftUI

struct FlowcyUsageSection: View {
    let api: SummaryAPIClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var attempt = 0
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(FlowcyModelUsage)
        case failed(String)
    }

    var body: some View {
        Section {
            switch state {
            case .loading:
                ProgressView("Loading usage…")
            case .loaded(let usage):
                let windows = FlowcyModelUsage.Window.allCases
                if usage.meters.contains(where: { FlowcyModelUsage.Window(rawValue: $0.key) != nil }) {
                    ForEach(windows, id: \.self) { window in
                        if let meter = usage.meters.first(where: { $0.key == window.rawValue }) {
                            FlowcyMeterRow(window: window, meter: meter)
                        }
                    }
                } else {
                    Text("No usage meters are available for this account.").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(verbatim: message).foregroundStyle(.secondary)
                Button("Try Again") { attempt += 1 }
                    .accessibilityIdentifier("flowcy-usage-retry")
            }
        } header: {
            Text("Flowcy Model Usage")
                .task(id: scenePhase == .active ? attempt : nil) {
                    guard scenePhase == .active else { return }
                    do {
                        if case .failed = state { state = .loading }
                        let usage = try await api.flowcyModelUsage()
                        try Task.checkCancellation()
                        state = .loaded(usage)
                    } catch {
                        if !Task.isCancelled { state = .failed(error.localizedDescription) }
                    }
                }
        } footer: {
            Text("Usage across your Flowcy account. A dash means the percentage is unavailable.")
        }
        .sensoryFeedback(.selection, trigger: attempt)
    }
}

private struct FlowcyMeterRow: View {
    let window: FlowcyModelUsage.Window
    let meter: FlowcyModelUsage.Meter

    private var title: LocalizedStringKey {
        switch window {
        case .fiveHours: "5 hours"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
    }

    var body: some View {
        let fraction = meter.fractionUsed
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).fontWeight(.medium)
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                } else {
                    Text(verbatim: "—").foregroundStyle(.secondary)
                        .accessibilityLabel("Percentage unavailable")
                }
            }
            .font(.subheadline)
            if let fraction {
                ProgressView(value: min(fraction, 1))
                    .progressViewStyle(.linear)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flowcy-usage-\(window.rawValue)")
    }
}
