import SummaryKit
import SwiftUI

/// Creates or edits one diary day: date and title, the route drawn on the map, the moments
/// timeline, where the night is spent and which transport the day uses.
struct DayEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var day: TripDay

    init(model: TripEditorModel, document: TripDocument, day: TripDay?) {
        self.model = model
        self.document = document
        self.isNew = day == nil
        let date = day?.date ?? Self.nextDate(in: document)
        _day = State(initialValue: day ?? TripDay(
            id: TripDocument.makeID("day"),
            date: date,
            title: String(localized: "Day \((document.days.count) + 1)")
        ))
    }

    /// The first trip date without a day yet, else the trip's start.
    private static func nextDate(in document: TripDocument) -> String {
        let used = Set(document.days.map(\.date))
        return TripDate.dates(from: document.startDate, through: document.endDate).first { !used.contains($0) } ?? document.startDate
    }

    private var zone: TimeZone { document.resolvedTimeZone }

    private var routeKind: Binding<TripRouteKind?> {
        Binding(
            get: { day.route?.kind },
            set: { kind in
                if let kind {
                    if day.route == nil { day.route = TripDayRoute(kind: kind) } else { day.route?.kind = kind }
                } else {
                    day.route = nil
                }
            }
        )
    }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New Day") : String(localized: "Edit Day"),
            canSave: day.title.nilIfBlank != nil && day.moments.allSatisfy { $0.text.nilIfBlank != nil },
            deleteTitle: isNew ? nil : String(localized: "Delete Day"),
            deleteMessage: String(localized: "The day and its moments are removed from the diary."),
            save: save,
            delete: delete
        ) {
            Section {
                TripDateField(title: String(localized: "Date"), value: $day.date, timeZone: zone)
                TextField("Title", text: $day.title)
                TextField("Route summary", text: $day.short.text)
                TextField("Description", text: $day.blurb.text, axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Highlight", isOn: $day.highlight)
            }

            Section {
                Picker("Route", selection: routeKind) {
                    Text("No route").tag(TripRouteKind?.none)
                    ForEach(TripRouteKind.allCases) { Text($0.title).tag(TripRouteKind?.some($0)) }
                }
                if day.route != nil {
                    ForEach(Array((day.route?.placeIds ?? []).enumerated()), id: \.offset) { index, placeID in
                        Label(document.place(id: placeID)?.name ?? placeID, systemImage: "\(index + 1).circle")
                    }
                    .onDelete { day.route?.placeIds.remove(atOffsets: $0) }
                    .onMove { day.route?.placeIds.move(fromOffsets: $0, toOffset: $1) }
                    Menu {
                        ForEach(document.places) { place in
                            Button(place.name) { day.route?.placeIds.append(place.id) }
                        }
                    } label: {
                        Label("Add Stop", systemImage: "plus.circle")
                    }
                    .disabled(document.places.isEmpty)
                }
            } header: {
                Text("Route")
            } footer: {
                if day.route != nil && document.places.isEmpty {
                    Text("Add places to the trip first; the route connects them in order.")
                } else if day.route?.path?.isEmpty == false {
                    Text("This day has a drawn path; stops here mark the places it visits.")
                }
            }

            Section("Moments") {
                ForEach($day.moments.indices, id: \.self) { index in
                    MomentRow(moment: $day.moments[index], places: document.places)
                }
                .onDelete { day.moments.remove(atOffsets: $0) }
                .onMove { day.moments.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    let slot = day.moments.last.map { TripMomentSlot.allCases[min(TripMomentSlot.allCases.count - 1, (TripMomentSlot.allCases.firstIndex(of: $0.slot) ?? 0) + 1)] } ?? .morning
                    withAnimation { day.moments.append(TripMoment(slot: slot, text: "")) }
                } label: {
                    Label("Add Moment", systemImage: "plus.circle")
                }
                .disabled(day.moments.count >= 24)
            }

            Section {
                Picker("Staying at", selection: $day.stayId) {
                    Text("None").tag(String?.none)
                    ForEach(document.hotels) { Text($0.name).tag(String?.some($0.id)) }
                }
                ForEach(document.transports) { transport in
                    Toggle(isOn: transportBinding(transport.id)) {
                        Text(transport.label)
                        Text(document.dayLabel(transport.date))
                    }
                }
            } header: {
                Text("Stay & Transport")
            }

            Section("Tip") {
                TextField("A tip for the day", text: $day.tip.text, axis: .vertical)
                    .lineLimit(1...4)
            }
        }
    }

    private func transportBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { day.transportIds.contains(id) },
            set: { on in
                if on { if !day.transportIds.contains(id) { day.transportIds.append(id) } } else { day.transportIds.removeAll { $0 == id } }
            }
        )
    }

    private func save() async throws {
        var day = day
        day.title = day.title.nilIfBlank ?? day.title
        day.short = day.short?.nilIfBlank
        day.blurb = day.blurb?.nilIfBlank
        day.tip = day.tip?.nilIfBlank
        day.moments = day.moments.map { moment in
            var moment = moment
            moment.text = moment.text.nilIfBlank ?? moment.text
            return moment
        }
        try await model.update { $0.upsert(day) }
    }

    private func delete() async throws {
        let id = day.id
        try await model.update { $0.remove(.days, id: id) }
    }
}

private struct MomentRow: View {
    @Binding var moment: TripMoment
    let places: [TripPlace]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Time of day", selection: $moment.slot) {
                ForEach(TripMomentSlot.allCases) { Text($0.title).tag($0) }
            }
            TripClockField(title: String(localized: "Time"), value: $moment.time)
            TextField("What happens", text: $moment.text, axis: .vertical)
                .lineLimit(1...4)
            if !places.isEmpty {
                TripPlacePicker(title: String(localized: "Place"), selection: $moment.placeId, places: places)
            }
        }
        .padding(.vertical, 4)
    }
}
