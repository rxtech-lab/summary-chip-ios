import SummaryKit
import SwiftUI

/// Picks which option of a plan the diary follows ("Route 1 / Route 2 / Route 3") from a dropdown.
/// The diary, map, stays and costs switch at once; the pick is saved for the user, so it's there
/// next time.
struct TripPlanPicker: View {
    let plan: TripPlan
    let selectedID: String?
    /// Inside a day card: no card of its own.
    var embedded = false
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

            Menu {
                TripPlanOptionsPicker(plan: plan, selectedID: selectedID, onSelect: onSelect)
            } label: {
                HStack(spacing: 8) {
                    Text(selected?.label ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(plan.title))
            .accessibilityValue(Text(selected?.label ?? ""))
            .accessibilityIdentifier("trip-plan-menu-\(plan.id)")

            if let summary = selected?.summary, !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(embedded ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !embedded {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.summaryCardBackground)
            }
        }
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selected?.id)
        .sensoryFeedback(.selection, trigger: selected?.id)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip-plan-\(plan.id)")
    }
}

/// A plan's options with a checkmark on the one followed, for a menu (the diary's dropdown, the
/// day sheet's toolbar).
struct TripPlanOptionsPicker: View {
    let plan: TripPlan
    let selectedID: String?
    let onSelect: (TripPlanOption) -> Void

    var body: some View {
        let current = plan.options.first { $0.id == selectedID }?.id ?? plan.options.first?.id
        Picker(plan.title, selection: Binding(
            get: { current ?? "" },
            set: { id in
                guard id != current, let option = plan.options.first(where: { $0.id == id }) else { return }
                onSelect(option)
            }
        )) {
            // A second text shows as the item's subtitle in the menu.
            ForEach(plan.options) { option in
                VStack {
                    Text(option.label)
                    if let summary = option.summary, !summary.isEmpty { Text(summary) }
                }
                .tag(option.id)
            }
        }
        .pickerStyle(.inline)
    }
}
