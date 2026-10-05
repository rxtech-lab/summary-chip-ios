import ActivityKit
import SummaryKit
import SwiftUI
import WidgetKit

/// A tracked flight on the lock screen and in the Dynamic Island. The backend starts, updates and
/// ends it with pushes; tapping it opens the trip.
struct FlightLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FlightActivityAttributes.self) { context in
            FlightLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(nil)
                .widgetURL(SummaryLink.openTripURL(tripID: context.attributes.tripId))
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    FlightEndpointColumn(code: attributes.fromIATA, time: state.departureBestDate, scheduled: state.departureScheduledDate, alignment: .leading)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FlightEndpointColumn(code: attributes.toIATA, time: state.arrivalBestDate, scheduled: state.arrivalScheduledDate, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(attributes.flightNumber).font(.headline)
                        FlightStatusBadge(state: state)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        FlightProgressBar(state: state)
                        FlightGateLine(state: state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: state.flightStatus.systemImage)
                        .foregroundStyle(state.tint)
                    Text(attributes.flightNumber.filter { !$0.isWhitespace })
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            } compactTrailing: {
                FlightCompactTrailing(state: state)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(state.tint)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: state.flightStatus.systemImage)
                    .foregroundStyle(state.tint)
            }
            .widgetURL(SummaryLink.openTripURL(tripID: attributes.tripId))
            .keylineTint(state.tint)
        }
    }
}

private struct FlightLockScreenView: View {
    let attributes: FlightActivityAttributes
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text([attributes.airlineName, attributes.flightNumber].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "airplane")
                }
                .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                FlightStatusBadge(state: state)
            }
            HStack(alignment: .center, spacing: 12) {
                FlightEndpointColumn(code: attributes.fromIATA, city: attributes.fromCity, time: state.departureBestDate, scheduled: state.departureScheduledDate, alignment: .leading)
                FlightProgressBar(state: state)
                FlightEndpointColumn(code: attributes.toIATA, city: attributes.toCity, time: state.arrivalBestDate, scheduled: state.arrivalScheduledDate, alignment: .trailing)
            }
            FlightGateLine(state: state)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }
}

/// "HKG", the city and the best time; the scheduled time struck through when it moved.
private struct FlightEndpointColumn: View {
    let code: String
    var city: String?
    let time: Date
    let scheduled: Date
    let alignment: HorizontalAlignment

    private var moved: Bool { abs(time.timeIntervalSince(scheduled)) >= 60 }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(code).font(.title2.weight(.bold)).lineLimit(1)
            if let city {
                Text(city).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(time, style: .time)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            if moved {
                Text(scheduled, style: .time)
                    .font(.caption2)
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct FlightStatusBadge: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 4) {
            Text(state.flightStatus.title)
            if !state.flightStatus.isFinal, let delay = FlightText.delay(minutes: state.delayMinutes), abs(state.delayMinutes) >= 5 {
                Text(delay)
            }
        }
        .font(.caption.weight(.bold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(state.tint)
        .background(state.tint.opacity(0.18), in: Capsule())
    }
}

/// Fills from departure to arrival while in the air; ActivityKit animates the timer interval itself.
private struct FlightProgressBar: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        Group {
            let status = state.flightStatus
            if status == .landed {
                ProgressView(value: 1)
            } else if status.isAirborne, state.departureBest < state.arrivalBest {
                ProgressView(timerInterval: state.departureBestDate...state.arrivalBestDate, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
            } else {
                ProgressView(value: 0)
            }
        }
        .progressViewStyle(.linear)
        .tint(state.tint)
        .frame(maxWidth: .infinity)
    }
}

/// Departure terminal and gate; after landing the arrival terminal, gate and baggage belt.
private struct FlightGateLine: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        let landed = state.flightStatus == .landed
        let parts: [String] = landed
            ? [FlightText.terminalAndGate(terminal: state.arrivalTerminal, gate: state.arrivalGate), state.baggageBelt.map(FlightText.baggageBelt)].compactMap { $0 }
            : [FlightText.terminalAndGate(terminal: state.departureTerminal, gate: state.departureGate)].compactMap { $0 }
        if !parts.isEmpty {
            HStack {
                if landed, state.baggageBelt != nil { Image(systemName: "suitcase.rolling") }
                Text(parts.joined(separator: " · ")).lineLimit(1)
            }
        }
    }
}

/// Before departure the departure time (or gate once boarding), in the air the time to arrival,
/// after landing the baggage belt.
private struct FlightCompactTrailing: View {
    let state: FlightActivityAttributes.ContentState

    var body: some View {
        let status = state.flightStatus
        if status == .landed {
            if let belt = state.baggageBelt { Text(FlightText.baggageBelt(belt)).lineLimit(1) } else { Image(systemName: "checkmark") }
        } else if status == .cancelled || status == .diverted {
            Image(systemName: status.systemImage)
        } else if status.isAirborne {
            Text(timerInterval: Date.now...max(Date.now, state.arrivalBestDate), countsDown: true, showsHours: true)
                .multilineTextAlignment(.trailing)
        } else if [.boarding, .gateClosed].contains(status), let gate = state.departureGate {
            Text(gate).lineLimit(1)
        } else {
            Text(state.departureBestDate, style: .time)
        }
    }
}

private extension FlightActivityAttributes.ContentState {
    var tint: Color {
        switch flightStatus {
        case .cancelled, .diverted: .red
        case .landed: .green
        case .delayed: .orange
        default: delayMinutes >= 15 ? .orange : .blue
        }
    }
}
