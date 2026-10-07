import SummaryKit
import SwiftUI

/// Picks which option of a plan the diary follows ("Route 1 / Route 2 / Route 3"). The diary, map,
/// stays and costs switch at once; the pick is saved for the user, so it's there next time.
struct TripPlanPicker: View {
    let plan: TripPlan
    let selectedID: String?
    let onSelect: (TripPlanOption) -> Void

    private var selected: TripPlanOption? {
        plan.options.first { $0.id == selectedID } ?? plan.options.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(plan.title, systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text("\(plan.options.count) options")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // One row when the labels fit, else one option per line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(plan.options) { option in
                        chip(option)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.options) { option in
                        chip(option)
                    }
                }
            }

            if let summary = selected?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.2), value: selected?.id)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip-plan-\(plan.id)")
    }

    private func chip(_ option: TripPlanOption) -> some View {
        let isSelected = option.id == selected?.id
        return Button {
            guard !isSelected else { return }
            onSelect(option)
        } label: {
            HStack(spacing: 6) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(option.label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("trip-plan-option-\(option.id)")
    }
}
