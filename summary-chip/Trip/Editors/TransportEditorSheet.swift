import SummaryKit
import SwiftUI

/// Creates or edits a transport: its options (e.g. an early and a late train) and each option's
/// legs, with train or flight details depending on the mode.
struct TransportEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var transport: TripTransport

    init(model: TripEditorModel, document: TripDocument, transport: TripTransport?, date: String? = nil) {
        self.model = model
        self.document = document
        self.isNew = transport == nil
        _transport = State(initialValue: transport ?? TripTransport(
            id: TripDocument.makeID("transport"),
            date: date ?? document.startDate,
            label: "",
            options: [TripTransportOption(id: TripDocument.makeID("option"), label: String(localized: "Option 1"))]
        ))
    }

    private var zone: TimeZone { document.resolvedTimeZone }

    private var isValid: Bool {
        transport.label.nilIfBlank != nil && !transport.options.isEmpty && transport.options.allSatisfy { option in
            option.label.nilIfBlank != nil && option.segments.allSatisfy(\.isValid)
        }
    }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New Transport") : String(localized: "Edit Transport"),
            canSave: isValid,
            deleteTitle: isNew ? nil : String(localized: "Delete Transport"),
            deleteMessage: String(localized: "The transport and its options are removed from the trip."),
            save: save,
            delete: delete
        ) {
            Section {
                TextField("Label", text: $transport.label, prompt: Text("Tokyo → Sendai"))
                    .accessibilityIdentifier("transport-label-field")
                TripDateField(title: String(localized: "Date"), value: $transport.date, timeZone: zone)
                Picker("Status", selection: $transport.status) {
                    ForEach(TripBookingStatus.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                ForEach($transport.options) { $option in
                    NavigationLink {
                        TransportOptionEditor(option: $option, document: document, api: model.api, transportDate: transport.date)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label.isEmpty ? String(localized: "Untitled option") : option.label)
                            Text(option.summaryLine(timeZone: zone))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    guard transport.options.count > offsets.count else { return }
                    transport.options.remove(atOffsets: offsets)
                    if !transport.options.contains(where: { $0.id == transport.selectedOptionId }) { transport.selectedOptionId = nil }
                }
                Button {
                    withAnimation {
                        transport.options.append(TripTransportOption(
                            id: TripDocument.makeID("option"),
                            label: String(localized: "Option \(transport.options.count + 1)")
                        ))
                    }
                } label: {
                    Label("Add Option", systemImage: "plus.circle")
                }
                .disabled(transport.options.count >= 10)
                if transport.options.count > 1 {
                    Picker("Chosen option", selection: $transport.selectedOptionId) {
                        Text("First option").tag(String?.none)
                        ForEach(transport.options) { Text($0.label).tag(String?.some($0.id)) }
                    }
                }
            } header: {
                Text("Options")
            } footer: {
                Text("Keep alternatives (an earlier or later train) as options and pick the one you're taking.")
            }
        }
    }

    private func save() async throws {
        var transport = transport
        transport.label = transport.label.nilIfBlank ?? transport.label
        transport.options = transport.options.map { $0.normalized() }
        let isNew = isNew
        try await model.update { document in
            document.upsert(transport)
            // A new transport shows on the day of its date.
            if isNew, let index = document.days.firstIndex(where: { $0.date == transport.date }),
               !document.days[index].transportIds.contains(transport.id) {
                document.days[index].transportIds.append(transport.id)
            }
        }
    }

    private func delete() async throws {
        let id = transport.id
        try await model.update { $0.remove(.transports, id: id) }
    }
}

private struct TransportOptionEditor: View {
    @Binding var option: TripTransportOption
    let document: TripDocument
    let api: SummaryAPIClient
    let transportDate: String

    private var zone: TimeZone { document.resolvedTimeZone }

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $option.label)
                TripLocalTimeField(title: String(localized: "Departure"), value: $option.departure, timeZone: zone, defaultDate: document.startDate)
                TripLocalTimeField(title: String(localized: "Arrival"), value: $option.arrival, timeZone: zone, defaultDate: document.startDate)
                TextField("Duration", text: $option.duration.text, prompt: Text("1h 31m"))
                TripMoneyField(title: String(localized: "Fare"), value: $option.fare, defaultCurrency: document.currency)
            } footer: {
                Text("Leave times empty to use the first and last legs' times.")
            }

            Section("Legs") {
                ForEach($option.segments.indices, id: \.self) { index in
                    NavigationLink {
                        SegmentEditor(
                            segment: $option.segments[index],
                            document: document,
                            api: api,
                            fallbackDate: option.flightDate(segmentIndex: index, fallback: transportDate)
                        )
                    } label: {
                        SegmentRowLabel(segment: option.segments[index])
                    }
                }
                .onDelete { option.segments.remove(atOffsets: $0) }
                .onMove { option.segments.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    let from = option.segments.last
                    withAnimation {
                        option.segments.append(TripSegment(
                            mode: from?.mode ?? .train,
                            fromPlaceId: from?.toPlaceId,
                            fromName: from?.toName ?? "",
                            toName: "",
                            train: (from?.mode ?? .train) == .train ? TripTrainDetails() : nil
                        ))
                    }
                } label: {
                    Label("Add Leg", systemImage: "plus.circle")
                }
                .disabled(option.segments.count >= 20)
            }

            Section {
                TextField("Warning", text: $option.warning.text, prompt: Text("Tight 8-minute transfer"), axis: .vertical)
                    .lineLimit(1...3)
                ForEach($option.notes.indices, id: \.self) { index in
                    TextField("Note", text: $option.notes[index], axis: .vertical)
                }
                .onDelete { option.notes.remove(atOffsets: $0) }
                Button {
                    option.notes.append("")
                } label: {
                    Label("Add Note", systemImage: "plus.circle")
                }
                .disabled(option.notes.count >= 20)
            } header: {
                Text("Notes")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(option.label.isEmpty ? String(localized: "Option") : option.label)
        .summaryInlineNavigationTitle()
    }
}

private struct SegmentRowLabel: View {
    let segment: TripSegment

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: segment.mode.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(segment.fromName.isEmpty ? "…" : segment.fromName) → \(segment.toName.isEmpty ? "…" : segment.toName)")
                if let times = TripTimes.range(segment.departure, segment.arrival) {
                    Text(times).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

private struct SegmentEditor: View {
    @Binding var segment: TripSegment
    let document: TripDocument
    let api: SummaryAPIClient
    /// The day a flight is looked up on when the leg has no departure: the option's, else the transport's.
    let fallbackDate: String
    @State private var isLookingUp = false
    @State private var foundFlight: Flight?
    @State private var notFoundMessage: String?
    @State private var lookupError: String?
    @State private var lookupSucceeded = 0
    @State private var lookupFailed = 0

    private var zone: TimeZone { document.resolvedTimeZone }

    /// The leg's local departure date, `YYYY-MM-DD`.
    private var lookupDate: String { String((segment.departure ?? fallbackDate).prefix(10)) }

    private var train: Binding<TripTrainDetails> {
        Binding(get: { segment.train ?? TripTrainDetails() }, set: { segment.train = $0 })
    }

    private var flight: Binding<TripFlightDetails> {
        Binding(get: { segment.flight ?? TripFlightDetails(flightNumber: "") }, set: { segment.flight = $0 })
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $segment.mode) {
                    ForEach(TripSegmentMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
            }
            Section("From") {
                TextField("From", text: $segment.fromName)
                if !document.places.isEmpty {
                    TripPlacePicker(title: String(localized: "Place"), selection: $segment.fromPlaceId, places: document.places)
                }
                TripLocalTimeField(title: String(localized: "Departure"), value: $segment.departure, timeZone: zone, defaultDate: document.startDate)
            }
            Section("To") {
                TextField("To", text: $segment.toName)
                if !document.places.isEmpty {
                    TripPlacePicker(title: String(localized: "Place"), selection: $segment.toPlaceId, places: document.places)
                }
                TripLocalTimeField(title: String(localized: "Arrival"), value: $segment.arrival, timeZone: zone, defaultDate: segment.departure.map { String($0.prefix(10)) } ?? document.startDate)
            }

            switch segment.mode {
            case .train:
                Section("Train") {
                    Picker("Category", selection: train.category) {
                        ForEach(TripTrainCategory.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Operator", text: train.`operator`.text, prompt: Text("JR East"))
                    TextField("Line", text: train.line.text, prompt: Text("Tohoku Shinkansen"))
                    TextField("Train name", text: train.name.text, prompt: Text("Hayabusa"))
                    TextField("Number", text: train.number.text, prompt: Text("5"))
                    Picker("Seat class", selection: train.seatClass) {
                        Text("Not set").tag(TripSeatClass?.none)
                        ForEach([TripSeatClass.reserved, .nonReserved, .green, .granClass]) { Text($0.title).tag(TripSeatClass?.some($0)) }
                    }
                    TextField("Car", text: train.carNumber.text)
                    TextField("Seat", text: train.seat.text)
                }
            case .flight:
                Section("Flight") {
                    TextField("Flight number", text: flight.flightNumber, prompt: Text("NH 12"))
                        .accessibilityIdentifier("flight-number-field")
                    TextField("Airline", text: flight.airline.text)
                    TextField("From airport (IATA)", text: flight.fromIATA.text, prompt: Text("HND"))
                        .summaryInputCapitalization()
                    TextField("To airport (IATA)", text: flight.toIATA.text, prompt: Text("HKD"))
                        .summaryInputCapitalization()
                    TextField("Terminal", text: flight.terminal.text)
                    TextField("Gate", text: flight.gate.text)
                    Picker("Cabin", selection: flight.seatClass) {
                        Text("Not set").tag(TripSeatClass?.none)
                        ForEach([TripSeatClass.economy, .premiumEconomy, .business, .first]) { Text($0.title).tag(TripSeatClass?.some($0)) }
                    }
                    TextField("Seat", text: flight.seat.text)
                    TextField("Booking reference", text: flight.bookingRef.text)
                }
                Section {
                    Button(action: lookUpFlight) {
                        Label("Look Up Flight", systemImage: "magnifyingglass")
                    }
                    .disabled(segment.flight?.flightNumber.nilIfBlank == nil || isLookingUp)
                    .accessibilityIdentifier("flight-lookup-button")
                } footer: {
                    Text("Fills in the airline, airports, terminal, gate and times for this flight on \(Self.displayDate(lookupDate)).")
                }
            default:
                EmptyView()
            }

            Section {
                TripMoneyField(title: String(localized: "Price"), value: $segment.price, defaultCurrency: document.currency)
                TextField("Source link", text: $segment.sourceUrl.text, prompt: Text("https://…"))
                    .summaryInputCapitalization()
                    .autocorrectionDisabled()
            }
        }
        .formStyle(.grouped)
        .navigationTitle(segment.mode.title)
        .summaryInlineNavigationTitle()
        .overlay {
            if isLookingUp { ActionStatusOverlay(String(localized: "Looking up flight…")) }
        }
        .sheet(item: $foundFlight) { flight in
            FlightLookupSheet(flight: flight) { apply(flight) }
        }
        .statusAlert("Flight Not Found", message: notFoundMessage) { notFoundMessage = nil }
        .statusAlert("Couldn't Look Up Flight", message: lookupError) { lookupError = nil }
        .sensoryFeedback(.success, trigger: lookupSucceeded)
        .sensoryFeedback(.error, trigger: lookupFailed)
    }

    private func lookUpFlight() {
        guard let number = segment.flight?.flightNumber.nilIfBlank, !isLookingUp else { return }
        let date = lookupDate
        isLookingUp = true
        Task {
            defer { isLookingUp = false }
            do {
                foundFlight = try await api.lookupFlight(flightNumber: number, date: date)
                lookupSucceeded += 1
            } catch is CancellationError {
            } catch let error as SummaryAPIError where error.isFlightNotFound {
                notFoundMessage = String(localized: "No flight \(number) was found on \(Self.displayDate(date)). Check the flight number and the departure date.")
                lookupFailed += 1
            } catch {
                lookupError = error.localizedDescription
                lookupFailed += 1
            }
        }
    }

    /// Fills the leg from the looked-up flight, keeping what the flight doesn't know.
    private func apply(_ flight: Flight) {
        var details = segment.flight ?? TripFlightDetails(flightNumber: flight.flightNumber)
        details.airline = flight.airline?.name ?? details.airline
        details.fromIATA = flight.departure.iata ?? details.fromIATA
        details.toIATA = flight.arrival.iata ?? details.toIATA
        details.terminal = flight.departure.terminal ?? details.terminal
        details.gate = flight.departure.gate ?? details.gate
        segment.flight = details
        segment.fromName = flight.departure.name
        segment.toName = flight.arrival.name
        if let departure = flight.departure.scheduledLocal ?? flight.departure.bestLocal { segment.departure = String(departure.prefix(16)) }
        if let arrival = flight.arrival.scheduledLocal ?? flight.arrival.bestLocal { segment.arrival = String(arrival.prefix(16)) }
    }

    /// "12 Oct 2026" for a `YYYY-MM-DD` date.
    private static func displayDate(_ value: String) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .gmt
        guard let date = TripDate.date(from: value, timeZone: utc) else { return value }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: utc))
    }
}

extension TripSegment {
    /// Names are required, and a flight needs its number.
    var isValid: Bool {
        fromName.nilIfBlank != nil && toName.nilIfBlank != nil
            && (mode != .flight || flight?.flightNumber.nilIfBlank != nil)
    }

    /// Drops details that don't match the mode and blank optional text before saving.
    func normalized() -> TripSegment {
        var segment = self
        segment.fromName = fromName.nilIfBlank ?? fromName
        segment.toName = toName.nilIfBlank ?? toName
        segment.train = mode == .train ? train.map(\.normalized) : nil
        segment.flight = mode == .flight ? flight.map(\.normalized) : nil
        segment.sourceUrl = sourceUrl?.nilIfBlank.flatMap { URL(string: $0)?.scheme?.hasPrefix("http") == true ? $0 : nil }
        return segment
    }
}

extension TripTrainDetails {
    var normalized: TripTrainDetails {
        var train = self
        train.`operator` = self.`operator`?.nilIfBlank
        train.line = line?.nilIfBlank
        train.name = name?.nilIfBlank
        train.number = number?.nilIfBlank
        train.carNumber = carNumber?.nilIfBlank
        train.seat = seat?.nilIfBlank
        return train
    }
}

extension TripFlightDetails {
    var normalized: TripFlightDetails {
        var flight = self
        flight.flightNumber = flightNumber.nilIfBlank ?? flightNumber
        flight.airline = airline?.nilIfBlank
        flight.fromIATA = Self.iata(fromIATA)
        flight.toIATA = Self.iata(toIATA)
        flight.terminal = terminal?.nilIfBlank
        flight.gate = gate?.nilIfBlank
        flight.seat = seat?.nilIfBlank
        flight.bookingRef = bookingRef?.nilIfBlank
        return flight
    }

    private static func iata(_ value: String?) -> String? {
        guard let code = value?.nilIfBlank?.uppercased(), code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }
}

extension TripTransportOption {
    func normalized() -> TripTransportOption {
        var option = self
        option.label = label.nilIfBlank ?? label
        option.duration = duration?.nilIfBlank
        option.warning = warning?.nilIfBlank
        option.notes = notes.compactMap(\.nilIfBlank)
        option.segments = segments.map { $0.normalized() }
        return option
    }

    /// "06:32 → 08:03 · 1h 31m".
    func summaryLine(timeZone: TimeZone) -> String {
        [TripTimes.range(effectiveDeparture, effectiveArrival), duration?.nilIfBlank].compactMap { $0 }.joined(separator: " · ")
    }
}

enum TripTimes {
    /// "05:53 → 14:04" from two local times; one side may be missing.
    static func range(_ departure: String?, _ arrival: String?) -> String? {
        let from = TripDate.clock(departure), to = TripDate.clock(arrival)
        guard from != nil || to != nil else { return nil }
        return "\(from ?? "–") → \(to ?? "–")"
    }
}
