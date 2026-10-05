import MapKit
import SummaryKit
import SwiftUI

extension EnvironmentValues {
    /// The trip's places, for custom views' `Place` cards.
    @Entry var tripPlaces: [TripPlace] = []
    /// Opens a place's details; nil where the trip can't present sheets.
    @Entry var tripShowPlace: ((String) -> Void)?
}

/// Turn-by-turn directions to a place in the Maps app (or Google Maps).
enum TripDirections {
    @MainActor
    static func openInMaps(_ place: TripPlace) {
        let location = CLLocation(latitude: place.coordinate.lat, longitude: place.coordinate.lng)
        let item = MKMapItem(location: location, address: nil)
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    static func googleMapsURL(_ place: TripPlace) -> URL? {
        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        components?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: "\(place.coordinate.lat),\(place.coordinate.lng)"),
        ]
        return components?.url
    }
}

/// The Directions button: Maps right away, Google Maps from its menu.
struct TripDirectionsButton: View {
    let place: TripPlace
    var prominent = true
    @Environment(\.openURL) private var openURL
    @State private var opened = 0

    var body: some View {
        Menu {
            Button { open() } label: { Label("Apple Maps", systemImage: "map") }
            if let url = TripDirections.googleMapsURL(place) {
                Button {
                    opened += 1
                    openURL(url)
                } label: { Label("Google Maps", systemImage: "globe") }
            }
        } label: {
            Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: prominent ? nil : 28)
        } primaryAction: {
            open()
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(prominent ? .large : .regular)
        .sensoryFeedback(.impact(weight: .light), trigger: opened)
        .accessibilityIdentifier("place-directions")
    }

    private func open() {
        opened += 1
        TripDirections.openInMaps(place)
    }
}

/// A place as a guidebook entry: photos, what it is, hours, prices and contacts, its GPS location
/// (tap for directions) and a map. The owner edits it from here.
struct TripPlaceDetailSheet: View {
    let document: TripDocument
    let place: TripPlace
    let onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tripEditable) private var editable
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !place.photos.isEmpty {
                        TripPhotoCarousel(photos: place.photos)
                    }
                    header
                    TripDirectionsButton(place: place)
                    if let description = place.description?.nilIfBlank {
                        Text(description)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    facts
                    if !place.pricing.isEmpty {
                        pricing
                    }
                    if let note = place.note?.nilIfBlank {
                        Text("\(Text("Note").bold()) · \(note)")
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.yellow.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    map
                }
                .padding(20)
            }
            .navigationTitle(place.name)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if editable {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Edit", action: onEdit)
                            .accessibilityIdentifier("place-detail-edit")
                    }
                }
            }
        }
        .summarySheetSize()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(place.kind.title, systemImage: place.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(place.name)
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            if let address = place.address?.nilIfBlank {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var websiteURL: URL? {
        guard let url = place.website.flatMap(URL.init(string:)), url.scheme?.hasPrefix("http") == true else { return nil }
        return url
    }

    /// Hours, visit length, website, phone and the GPS location, one row each.
    private var facts: some View {
        VStack(spacing: 0) {
            if let hours = place.hours?.nilIfBlank {
                factLabel("Hours", systemImage: "clock", value: hours, tinted: false)
                Divider()
            }
            if let duration = place.visitDuration?.nilIfBlank {
                factLabel("Visit", systemImage: "hourglass", value: duration, tinted: false)
                Divider()
            }
            if let website = websiteURL {
                Link(destination: website) {
                    factLabel("Website", systemImage: "safari", value: website.host() ?? website.absoluteString, tinted: true)
                }
                .buttonStyle(.plain)
                Divider()
            }
            if let phone = place.phone?.nilIfBlank {
                Button {
                    if let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") { openURL(url) }
                } label: {
                    factLabel("Phone", systemImage: "phone", value: phone, tinted: true)
                }
                .buttonStyle(.plain)
                Divider()
            }
            // The GPS location: tap for directions in Maps, hold to copy.
            Button { TripDirections.openInMaps(place) } label: {
                factLabel("Location", systemImage: "location", value: coordinateText, tinted: true)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { copyCoordinate() } label: { Label("Copy Coordinates", systemImage: "doc.on.doc") }
                Button { TripDirections.openInMaps(place) } label: { Label("Open in Maps", systemImage: "map") }
            }
            .accessibilityIdentifier("place-coordinate")
        }
        .padding(.horizontal, 14)
        .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var coordinateText: String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(5))
        return "\(place.coordinate.lat.formatted(format)), \(place.coordinate.lng.formatted(format))"
    }

    private func factLabel(_ title: LocalizedStringKey, systemImage: String, value: String, tinted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .font(.subheadline)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var pricing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prices").font(.headline)
            VStack(spacing: 0) {
                ForEach(place.pricing.indices, id: \.self) { index in
                    let item = place.pricing[index]
                    if index > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                            if let note = item.note?.nilIfBlank {
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        Text(item.price?.formatted ?? String(localized: "Free"))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 14)
            .background(Color.summaryCardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var map: some View {
        // Fixed in place; a tap asks Maps for directions, like the Location row.
        Map(initialPosition: .region(MKCoordinateRegion(center: place.coordinate.clCoordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)), interactionModes: []) {
            Marker(place.name, systemImage: place.kind.systemImage, coordinate: place.coordinate.clCoordinate)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { TripDirections.openInMaps(place) }
        .accessibilityHidden(true)
    }

    private func copyCoordinate() {
        let text = "\(place.coordinate.lat), \(place.coordinate.lng)"
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// Photos the reader pages through, each with its caption and credit.
struct TripPhotoCarousel: View {
    let photos: [TripPhoto]
    var aspectRatio: CGFloat = 4.0 / 3.0

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 10) {
                ForEach(photos.indices, id: \.self) { index in
                    TripPhotoView(photo: photos[index], aspectRatio: aspectRatio)
                        .containerRelativeFrame(.horizontal) { width, _ in photos.count > 1 ? width * 0.88 : width }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

/// One photo, cropped to `aspectRatio`, with its caption and credit under it.
struct TripPhotoView: View {
    let photo: TripPhoto
    var aspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    SummaryRemoteImage(url: photo.imageURL) {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(photo.caption ?? String(localized: "Photo"))
            let caption = [photo.caption?.nilIfBlank, photo.credit?.nilIfBlank].compactMap(\.self).joined(separator: " · ")
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}
