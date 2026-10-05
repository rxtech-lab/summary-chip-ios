import SummaryKit
import SwiftUI

extension EnvironmentValues {
    /// The open trip's tracked flights, for the transport cards.
    @Entry var tripFlights: [TripFlight] = []
}

extension Array where Element == TripFlight {
    /// The tracked flights of a transport's option, in leg order.
    func tracked(transportID: String, optionID: String?) -> [TripFlight] {
        filter { $0.transportId == transportID && $0.optionId == optionID }.sorted { $0.segmentIndex < $1.segmentIndex }
    }

    func tracked(transportID: String, optionID: String?, segmentIndex: Int) -> TripFlight? {
        first { $0.transportId == transportID && $0.optionId == optionID && $0.segmentIndex == segmentIndex }
    }
}

extension FlightStatus {
    var tint: Color {
        switch self {
        case .cancelled, .diverted: .red
        case .landed: .green
        case .delayed: .orange
        case .boarding, .gateClosed, .checkIn: .indigo
        case .departed, .enRoute, .approaching: .blue
        case .scheduled, .unknown: .secondary
        }
    }
}

/// "Boarding · +25 min" in the status colour; late flights turn orange.
struct FlightStatusBadge: View {
    let flight: Flight

    private var delay: String? {
        guard !flight.status.isFinal, let minutes = flight.delayMinutes, abs(minutes) >= 5 else { return nil }
        return FlightText.delay(minutes: minutes)
    }

    private var tint: Color {
        if flight.status == .scheduled, (flight.delayMinutes ?? 0) >= 15 { return .orange }
        return flight.status.tint
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: flight.status.systemImage)
            Text(flight.status.title)
            if let delay { Text("· \(delay)") }
        }
        .font(.caption.weight(.bold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A flight's airline and number, both airports with terminal and gate, scheduled and expected
/// local times, status and aircraft. Used by the flight lookup and the trip's transport details.
struct FlightInfoCard: View {
    let flight: Flight
    var showsUpdated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.flightNumber).font(.title3.weight(.bold))
                    if let airline = flight.airline?.name {
                        Text(airline).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                FlightStatusBadge(flight: flight)
            }
            HStack(alignment: .top, spacing: 8) {
                FlightEndpointView(endpoint: flight.departure, alignment: .leading, dayOffset: 0)
                Image(systemName: "airplane")
                    .font(.title3)
                    .foregroundStyle(flight.status.tint)
                    .padding(.top, 6)
                FlightEndpointView(endpoint: flight.arrival, alignment: .trailing, dayOffset: arrivalDayOffset)
            }
            if flight.aircraft != nil || showsUpdated {
                HStack {
                    if let aircraft = flight.aircraft {
                        Label(aircraft, systemImage: "airplane.circle")
                    }
                    Spacer(minLength: 8)
                    if showsUpdated, let updatedAt = flight.updatedAt {
                        FlightUpdatedText(date: updatedAt)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "+1" when the flight lands on a later local date than it leaves.
    private var arrivalDayOffset: Int {
        guard let from = flight.departure.bestLocal ?? flight.departure.scheduledLocal,
              let to = flight.arrival.bestLocal ?? flight.arrival.scheduledLocal else { return 0 }
        return TripDate.daysBetween(String(from.prefix(10)), String(to.prefix(10))) ?? 0
    }
}

private struct FlightEndpointView: View {
    let endpoint: FlightEndpoint
    let alignment: HorizontalAlignment
    let dayOffset: Int

    private var textAlignment: TextAlignment { alignment == .leading ? .leading : .trailing }
    private var scheduled: String? { TripDate.clock(endpoint.scheduledLocal) }
    private var expected: String? { TripDate.clock(endpoint.actualLocal ?? endpoint.estimatedLocal) }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(endpoint.code).font(.title.weight(.bold)).lineLimit(1)
            Text(endpoint.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(textAlignment)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let expected, expected != scheduled {
                    Text(expected).font(.headline).foregroundStyle(.orange)
                    if let scheduled {
                        Text(scheduled).font(.caption).strikethrough().foregroundStyle(.secondary)
                    }
                } else if let time = scheduled ?? expected {
                    Text(time).font(.headline)
                }
                if dayOffset > 0 {
                    Text("+\(dayOffset)").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if let gate = FlightText.terminalAndGate(terminal: endpoint.terminal, gate: endpoint.gate) {
                Text(gate).font(.caption.weight(.medium)).lineLimit(1)
            }
            if let belt = endpoint.baggageBelt {
                Label(FlightText.baggageBelt(belt), systemImage: "suitcase.rolling").font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

/// "Updated 5 min ago", kept current.
struct FlightUpdatedText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text("Updated \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                .accessibilityLabel(Text("Updated \(date.formatted(.relative(presentation: .named)))"))
        }
    }
}

/// A tracked flight leg on a transport card: status, delay, gate and expected times, or that the
/// backend is still checking or couldn't find it.
struct TrackedFlightStatusView: View {
    let item: TripFlight

    var body: some View {
        Group {
            switch item.state {
            case .pending:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Checking flight…")
                }
                .foregroundStyle(.secondary)
            case .notFound:
                Label("Flight not found", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .found:
                if let flight = item.flight { found(flight) }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("trip-flight-status-\(item.flightId)")
    }

    private func found(_ flight: Flight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FlightStatusBadge(flight: flight)
                Text(flight.flightNumber).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if let updatedAt = flight.updatedAt {
                    FlightUpdatedText(date: updatedAt).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if let line = detailLine(flight) {
                Text(line).monospacedDigit().foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    /// "Departs 09:30 · T1 · Gate B12 · Arrives 14:45", or the baggage belt once landed.
    private func detailLine(_ flight: Flight) -> String? {
        var parts: [String] = []
        if flight.status == .landed {
            if let arrival = TripDate.clock(flight.arrival.bestLocal) { parts.append(String(localized: "Landed \(arrival)")) }
            if let gate = FlightText.terminalAndGate(terminal: flight.arrival.terminal, gate: flight.arrival.gate) { parts.append(gate) }
            if let belt = flight.arrival.baggageBelt { parts.append(FlightText.baggageBelt(belt)) }
        } else {
            if let departure = TripDate.clock(flight.departure.bestLocal) { parts.append(String(localized: "Departs \(departure)")) }
            if let gate = FlightText.terminalAndGate(terminal: flight.departure.terminal, gate: flight.departure.gate) { parts.append(gate) }
            if let arrival = TripDate.clock(flight.arrival.bestLocal) { parts.append(String(localized: "Arrives \(arrival)")) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The result of a flight lookup; "Use these details" fills the leg in.
struct FlightLookupSheet: View {
    let flight: Flight
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                FlightInfoCard(flight: flight)
                    .padding(16)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onUse()
                    dismiss()
                } label: {
                    Label("Use These Details", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
                .accessibilityIdentifier("flight-lookup-use")
            }
            .navigationTitle(flight.flightNumber)
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}
