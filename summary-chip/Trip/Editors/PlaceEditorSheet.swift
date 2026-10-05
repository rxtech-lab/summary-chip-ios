import MapKit
import SummaryKit
import SwiftUI

/// Creates or edits a place: found with Maps search or the current location, or typed in.
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
        }
        .sensoryFeedback(.selection, trigger: picked)
        .onDisappear { location.stopLiveUpdates() }
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
        place.coordinate.lat = min(90, max(-90, place.coordinate.lat))
        place.coordinate.lng = min(180, max(-180, place.coordinate.lng))
        try await model.update { $0.upsert(place) }
    }

    private func delete() async throws {
        let id = place.id
        try await model.update { $0.remove(.places, id: id) }
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
