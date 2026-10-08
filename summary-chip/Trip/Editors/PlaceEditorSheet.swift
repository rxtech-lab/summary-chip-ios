import MapKit
import SummaryKit
import SwiftUI

/// Creates or edits a place: found with Maps search or the current location, or typed in, with its
/// guidebook details (description, hours, prices, website, phone) and photos.
struct PlaceEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var place: TripPlace
    @State private var hasCoordinate: Bool
    @State private var search = PlaceSearch()
    @State private var location = LocationProvider()
    @State private var isLocating = false
    @State private var lookupError: String?
    @State private var picked = 0
    @State private var editingPrice: TripListDraft<TripPriceItem>?
    @State private var editingPhoto: TripListDraft<TripPhoto>?

    init(model: TripEditorModel, document: TripDocument, place: TripPlace?) {
        self.model = model
        self.document = document
        self.isNew = place == nil
        let fallback = document.places.last?.coordinate ?? TripCoordinate(lat: 0, lng: 0)
        _place = State(initialValue: place ?? TripPlace(id: TripDocument.makeID("place"), name: "", coordinate: fallback))
        _hasCoordinate = State(initialValue: place != nil)
    }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New Place") : String(localized: "Edit Place"),
            canSave: place.name.nilIfBlank != nil && hasCoordinate,
            deleteTitle: isNew ? nil : String(localized: "Delete Place"),
            deleteMessage: String(localized: "The place is removed from routes, moments and hotels that use it."),
            save: save,
            delete: delete
        ) {
            searchSection

            if hasCoordinate {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: place.coordinate.clCoordinate, latitudinalMeters: 4_000, longitudinalMeters: 4_000))) {
                        Marker(place.name.isEmpty ? String(localized: "New Place") : place.name, coordinate: place.coordinate.clCoordinate)
                    }
                    .id(place.coordinate)
                    .frame(height: 160)
                    .allowsHitTesting(false)
                    .listRowInsets(EdgeInsets())
                    LabeledContent("Latitude") {
                        TextField("Latitude", value: $place.coordinate.lat, format: .number.precision(.fractionLength(0...6)))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("Longitude", value: $place.coordinate.lng, format: .number.precision(.fractionLength(0...6)))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section {
                TextField("Name", text: $place.name)
                Picker("Kind", selection: $place.kind) {
                    ForEach(TripPlaceKind.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                Toggle("Always label on map", isOn: $place.major)
                TextField("Address", text: $place.address.text, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Note", text: $place.note.text, axis: .vertical)
                    .lineLimit(1...5)
            }

            Section("About") {
                TextField("Description", text: $place.description.text, axis: .vertical)
                    .lineLimit(2...8)
                TextField("Opening hours", text: $place.hours.text)
                TextField("Visit duration", text: $place.visitDuration.text, prompt: Text("1–2 h"))
                TextField("Website", text: $place.website.text)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Phone", text: $place.phone.text)
                    .textContentType(.telephoneNumber)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
            }

            pricingSection

            photosSection
        }
        .sheet(item: $editingPrice) { draft in
            TripPriceItemSheet(item: draft.value, isNew: draft.index == nil, defaultCurrency: document.currency) { item in
                if let index = draft.index { place.pricing[index] = item } else { place.pricing.append(item) }
            }
        }
        .sheet(item: $editingPhoto) { draft in
            TripPhotoEditorSheet(photo: draft.value, isNew: draft.index == nil) { photo in
                if let index = draft.index { place.photos[index] = photo } else { place.photos.append(photo) }
            }
        }
        .sensoryFeedback(.selection, trigger: picked)
        .onDisappear { location.stopLiveUpdates() }
    }

    private var searchSection: some View {
        Section {
            TextField("Search Maps", text: $search.query)
                .summaryInputCapitalization()
                .autocorrectionDisabled()
                .accessibilityIdentifier("place-search-field")
            ForEach(search.results.prefix(6), id: \.self) { completion in
                Button {
                    Task { await pick(completion) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(completion.title).foregroundStyle(.primary)
                        if !completion.subtitle.isEmpty {
                            Text(completion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button {
                Task { await useCurrentLocation() }
            } label: {
                HStack {
                    Label("Use Current Location", systemImage: "location.fill")
                    if isLocating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLocating)
            .accessibilityIdentifier("place-current-location")
        } footer: {
            if let lookupError {
                Text(lookupError).foregroundStyle(.red)
            }
        }
    }

    private var pricingSection: some View {
        Section {
            ForEach(place.pricing.indices, id: \.self) { index in
                let item = place.pricing[index]
                Button { editingPrice = TripListDraft(index: index, value: item) } label: {
                    LabeledContent(item.label, value: item.price?.formatted ?? String(localized: "Free"))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { place.pricing.remove(atOffsets: $0) }
            .onMove { place.pricing.move(fromOffsets: $0, toOffset: $1) }
            Button {
                editingPrice = TripListDraft(index: nil, value: TripPriceItem(label: "", price: TripMoney(amount: 0, currency: document.currency)))
            } label: { Label("Add Price", systemImage: "plus") }
            .accessibilityIdentifier("place-add-price")
        } header: {
            Text("Prices")
        } footer: {
            Text("Admission tiers, set menus or rates. Leave the amount empty for free.")
        }
    }

    private var photosSection: some View {
        Section {
            ForEach(place.photos.indices, id: \.self) { index in
                let photo = place.photos[index]
                Button { editingPhoto = TripListDraft(index: index, value: photo) } label: {
                    HStack(spacing: 10) {
                        SummaryRemoteImage(url: photo.imageURL) { Rectangle().fill(.quaternary) }
                            .frame(width: 52, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(photo.caption?.nilIfBlank ?? photo.url)
                            .lineLimit(1)
                            .foregroundStyle(photo.caption?.nilIfBlank == nil ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .onDelete { place.photos.remove(atOffsets: $0) }
            .onMove { place.photos.move(fromOffsets: $0, toOffset: $1) }
            if place.photos.count < 12 {
                Button { editingPhoto = TripListDraft(index: nil, value: TripPhoto(url: "")) } label: {
                    Label("Add Photo", systemImage: "photo.badge.plus")
                }
                .accessibilityIdentifier("place-add-photo")
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Link to images on the web (https). The trip agent adds photos from pages you share.")
        }
    }

    private func pick(_ completion: MKLocalSearchCompletion) async {
        lookupError = nil
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
            guard let item = response.mapItems.first else { return }
            apply(item, fallbackName: completion.title)
            search.query = ""
        } catch {
            lookupError = error.localizedDescription
        }
    }

    private func useCurrentLocation() async {
        lookupError = nil
        isLocating = true
        defer { isLocating = false }
        location.requestAccess()
        guard let current = await location.currentLocation(timeout: .seconds(12)) else {
            lookupError = location.isDenied
                ? String(localized: "Location access is off. Allow it for Chippy in Settings.")
                : String(localized: "Couldn't find your location. Try again.")
            return
        }
        place.coordinate = TripCoordinate(current.coordinate)
        hasCoordinate = true
        picked += 1
        if let request = MKReverseGeocodingRequest(location: current), let item = try? await request.mapItems.first {
            if place.name.nilIfBlank == nil { place.name = item.name ?? "" }
            if place.address?.nilIfBlank == nil { place.address = item.address?.shortAddress ?? item.address?.fullAddress }
        }
    }

    private func apply(_ item: MKMapItem, fallbackName: String) {
        place.coordinate = TripCoordinate(item.location.coordinate)
        hasCoordinate = true
        place.name = item.name ?? fallbackName
        place.address = item.address?.shortAddress ?? item.address?.fullAddress
        if isNew, let kind = Self.kind(for: item.pointOfInterestCategory) { place.kind = kind }
        picked += 1
    }

    private static func kind(for category: MKPointOfInterestCategory?) -> TripPlaceKind? {
        switch category {
        case .airport: .airport
        case .hotel: .hotel
        case .publicTransport: .station
        case .marina: .port
        case .none: nil
        default: .poi
        }
    }

    private func save() async throws {
        var place = place
        place.name = place.name.nilIfBlank ?? place.name
        place.address = place.address?.nilIfBlank
        place.note = place.note?.nilIfBlank
        place.description = place.description?.nilIfBlank
        place.hours = place.hours?.nilIfBlank
        place.visitDuration = place.visitDuration?.nilIfBlank
        place.phone = place.phone?.nilIfBlank
        place.website = place.website?.nilIfBlank.map { $0.contains("://") ? $0 : "https://\($0)" }
        place.coordinate.lat = min(90, max(-90, place.coordinate.lat))
        place.coordinate.lng = min(180, max(-180, place.coordinate.lng))
        try await model.update { $0.upsert(place) }
    }

    private func delete() async throws {
        let id = place.id
        try await model.update { $0.remove(.places, id: id) }
    }
}

/// A list item being edited in its own sheet: its index, or nil for a new one.
struct TripListDraft<Value>: Identifiable {
    let id = UUID()
    let index: Int?
    var value: Value
}

/// Adds or edits one line of a place's prices.
struct TripPriceItemSheet: View {
    @State var item: TripPriceItem
    let isNew: Bool
    let defaultCurrency: String
    let onDone: (TripPriceItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Label", text: $item.label, prompt: Text("Adult"))
                TripMoneyField(title: String(localized: "Price"), value: $item.price, defaultCurrency: defaultCurrency)
                TextField("Note", text: $item.note.text, prompt: Text("Optional"))
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? String(localized: "Add Price") : String(localized: "Edit Price"))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var item = item
                        item.label = item.label.nilIfBlank ?? item.label
                        item.note = item.note?.nilIfBlank
                        onDone(item)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(item.label.nilIfBlank == nil)
                }
            }
        }
        .summarySheetSize()
    }
}

/// Adds or edits a photo of a place by its image link, with a preview.
struct TripPhotoEditorSheet: View {
    @State var photo: TripPhoto
    let isNew: Bool
    let onDone: (TripPhoto) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Image URL", text: $photo.url, prompt: Text(verbatim: "https://"))
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("photo-url-field")
                    if photo.imageURL != nil {
                        TripPhotoView(photo: TripPhoto(url: photo.url), aspectRatio: 16.0 / 9.0)
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                } footer: {
                    if !photo.url.isEmpty, photo.imageURL == nil {
                        Text("Use an https link to an image.").foregroundStyle(.red)
                    }
                }
                Section {
                    TextField("Caption", text: $photo.caption.text)
                    TextField("Credit", text: $photo.credit.text, prompt: Text("Photo: …"))
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? String(localized: "Add Photo") : String(localized: "Edit Photo"))
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        var photo = photo
                        photo.url = photo.url.trimmingCharacters(in: .whitespacesAndNewlines)
                        photo.caption = photo.caption?.nilIfBlank
                        photo.credit = photo.credit?.nilIfBlank
                        onDone(photo)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(photo.imageURL == nil)
                }
            }
        }
        .summarySheetSize()
    }
}

/// Maps search suggestions for the place editor's search field.
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                results = []
                completer.cancel()
            } else {
                completer.queryFragment = query
            }
        }
    }
    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        results = []
    }
}
