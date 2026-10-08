import SummaryKit
import SwiftUI

/// A popover anchored to the place being discussed. Its photos follow narration progress.
struct TripTourPlaceCard: View {
    let id: String
    let name: String
    let symbol: String
    let photos: [TripPhoto]
    var anchored = true
    let focus: TripTourFocus
    let onOpenPhoto: ([TripPhoto], Int) -> Void
    @State private var page: Int? = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var automaticPage: Int? { focus.photo(atCount: photos.count) }
    private var selectedPage: Int { min(max(0, page ?? 0), max(0, photos.count - 1)) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if !photos.isEmpty {
                    carousel
                    if photos.count > 1 { paging }
                }
                Label(name, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if photos.indices.contains(selectedPage) {
                    let photo = photos[selectedPage]
                    let caption = [photo.caption?.nilIfBlank, photo.credit?.nilIfBlank].compactMap(\.self).joined(separator: " · ")
                    if !caption.isEmpty {
                        Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .padding(10)
            .frame(width: 256, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
            if anchored { anchor }
        }
        .onAppear { page = automaticPage }
        .onChange(of: automaticPage) { _, value in select(value) }
        .sensoryFeedback(.selection, trigger: page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip-tour-place-\(id)")
    }

    private var anchor: some View {
        VStack(spacing: 0) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 14))
                .rotationEffect(.degrees(180))
                .foregroundStyle(.regularMaterial)
                .offset(y: -3)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
                .overlay { Circle().strokeBorder(.white, lineWidth: 3) }
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(photos.indices, id: \.self) { index in
                    Button { onOpenPhoto(photos, index) } label: {
                        Color.clear
                            .frame(width: 236, height: 140)
                            .overlay {
                                SummaryRemoteImage(url: photos[index].imageURL) {
                                    ZStack {
                                        Rectangle().fill(.quaternary)
                                        Image(systemName: "photo").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .clipped()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(photos[index].caption ?? String(localized: "Photo"))
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .frame(width: 236, height: 140)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("trip-tour-photo-carousel")
    }

    private var paging: some View {
        HStack {
            Button { select(selectedPage - 1) } label: { Label("Previous Photo", systemImage: "chevron.left") }
                .disabled(selectedPage == 0)
            Spacer()
            Text("\(selectedPage + 1) / \(photos.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { select(selectedPage + 1) } label: { Label("Next Photo", systemImage: "chevron.right") }
                .disabled(selectedPage == photos.count - 1)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private func select(_ index: Int?) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.6)) { page = index }
    }
}
