import SummaryKit
import SwiftUI

/// A place preview shared by diary days and custom views; its photo and guide open the details sheet.
struct TripPlacePreviewCard: View {
    let place: TripPlace
    @Environment(\.tripShowPlace) private var showPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { showPlace?(place.id) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    if let photo = place.photos.first {
                        TripPhotoView(photo: photo, aspectRatio: 16.0 / 9.0, opensViewer: false)
                            .padding(.bottom, 6)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: place.kind.systemImage).foregroundStyle(.secondary)
                        Text(place.name).font(.headline)
                        Spacer(minLength: 0)
                        if showPlace != nil {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if let description = place.description?.nilIfBlank ?? place.note?.nilIfBlank {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let facts = [place.hours, place.pricing.first.map { item in
                        "\(item.label) \(item.price?.formatted ?? String(localized: "Free"))"
                    }].compactMap(\.self)
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(showPlace == nil)
            TripDirectionsButton(place: place, prominent: false)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityIdentifier("trip-view-place-\(place.id)")
    }
}
