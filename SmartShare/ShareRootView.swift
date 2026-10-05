import SummaryKit
import SwiftUI

/// Signed-out → notice; otherwise choose Summarize (source preview → options → generating → result)
/// or Add to Trip (trip picker → the agent updates the trip in the background).
struct ShareRootView: View {
    let inputItems: [Any]
    let finish: () -> Void
    let cancel: () -> Void
    let openURL: (URL) -> Void

    private enum Phase {
        case loading
        case signedOut
        case failed(String)
        case ready(SummaryInput)
    }

    @State private var phase: Phase = .loading
    @State private var configuration = SummaryConfiguration.live()
    @State private var broker: SharedTokenBroker?
    @State private var api: SummaryAPIClient?
    @State private var loader: SummaryAssetLoader = .anonymous
    @State private var sourceFile: URL?
    @State private var sourceFilename: String?
    @State private var destination: ShareDestination?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                NavigationStack {
                    Color.clear.overlay { ActionStatusOverlay(String(localized: "Reading what you shared…"), isWorking: true) }
                        .toolbar { cancelItem }
                }
            case .signedOut:
                NavigationStack {
                    SignedOutNotice()
                        .navigationTitle("Chippy")
                        .summaryInlineNavigationTitle()
                        .toolbar { cancelItem }
                }
            case .failed(let message):
                NavigationStack {
                    Color.clear.statusAlert("Couldn't Read Shared Item", message: message, onDismiss: cancel)
                        .toolbar { cancelItem }
                }
            case .ready(let input):
                if let api {
                    switch destination {
                    case nil:
                        ShareDestinationView(input: input, cancel: cancel) { destination = $0 }
                    case .summarize:
                        summarize(api: api, input: input)
                    case .trip:
                        ShareToTripFlow(api: api, input: input, sourceFile: sourceFile, cancel: cancel, finish: finish, openURL: openURL)
                    }
                }
            }
        }
        .environment(\.summaryAssetLoader, loader)
        .task { await prepare() }
    }

    private func summarize(api: SummaryAPIClient, input: SummaryInput) -> some View {
        SummaryCreationFlow(api: api, input: input, sourceFile: sourceFile, sourceFilename: sourceFilename, title: "Chippy", onCancel: cancel) { summary in
            ShareResultView(api: api, summary: summary, openInApp: { openURL(SummaryLink.openInAppURL(summaryID: summary.id)) }, done: finish, discarded: cancel)
        }
    }

    private var cancelItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel, action: cancel)
        }
    }

    private func prepare() async {
        let broker = SharedTokenBroker.live(configuration: configuration)
        guard await broker.hasSession() else {
            phase = .signedOut
            return
        }
        self.broker = broker
        api = SummaryAPIClient(baseURL: configuration.apiBaseURL, tokenProvider: broker)
        loader = SummaryAssetLoader(tokenProvider: broker, cacheLimitBytes: 8 * 1024 * 1024)
        do {
            let raw = try await SharePayloadLoader.loadRaw(inputItems: inputItems)
            guard let input = ShareClassifier.classify(raw) else { throw SharePayloadError.noSupportedItems }
            sourceFile = raw.pdfFile ?? raw.localFile
            sourceFilename = raw.pdfFilename ?? raw.localFilename
            phase = .ready(input)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct ShareResultView: View {
    let api: SummaryAPIClient
    let summary: Summary
    let openInApp: () -> Void
    let done: () -> Void
    let discarded: () -> Void
    @State private var showsDiscard = false

    var body: some View {
        List {
            Section {
                SummaryCardView(summary: summary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
            }
            ShareActionsSection(summary: summary)
            Section {
                Button(action: openInApp) {
                    Label("Open in Chippy", systemImage: "arrow.up.forward.app")
                }
            }
            Section {
                Button(role: .destructive) {
                    showsDiscard = true
                } label: {
                    Label("Not right? Discard…", systemImage: "trash")
                }
                .accessibilityIdentifier("discard-new-summary")
            }
        }
        .sheet(isPresented: $showsDiscard) {
            // Already shared from the page; reopening it in Safari wouldn't help, so only discard.
            DiscardSummarySheet(api: api, summary: summary, offersSafari: false, onDiscarded: discarded)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).fontWeight(.semibold)
            }
        }
    }
}

private enum ShareDestination {
    case summarize
    case trip
}

/// What to do with the shared item: summarise it, or let the agent add it to a trip.
private struct ShareDestinationView: View {
    let input: SummaryInput
    let cancel: () -> Void
    let choose: (ShareDestination) -> Void
    @State private var chosen = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(input.displayTitle, systemImage: input.systemImage)
                        .lineLimit(2)
                } header: {
                    Text("Shared")
                }
                Section {
                    option(
                        title: String(localized: "Summarize"),
                        detail: String(localized: "Make a summary card to read and share."),
                        systemImage: "text.quote",
                        destination: .summarize
                    )
                    .accessibilityIdentifier("share-destination-summarize")
                    option(
                        title: String(localized: "Add to Trip"),
                        detail: String(localized: "The agent reads it and updates a trip diary: bookings, trains, hotels."),
                        systemImage: "map",
                        destination: .trip
                    )
                    .accessibilityIdentifier("share-destination-trip")
                }
            }
            .navigationTitle("Chippy")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                }
            }
        }
        .summarySheetSize()
        .sensoryFeedback(.selection, trigger: chosen)
    }

    private func option(title: String, detail: String, systemImage: String, destination: ShareDestination) -> some View {
        Button {
            chosen += 1
            withAnimation { choose(destination) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pick a trip (under way and upcoming first), optionally say what to do, and hand the item to
/// the trip agent. It works in the background and sends a notification when the trip is updated.
private struct ShareToTripFlow: View {
    let api: SummaryAPIClient
    let input: SummaryInput
    let sourceFile: URL?
    let cancel: () -> Void
    let finish: () -> Void
    let openURL: (URL) -> Void

    @State private var trips: [TripListItem]?
    @State private var loadError: String?
    @State private var selectedID: String?
    @State private var instructions = ""
    @State private var isSending = false
    @State private var sentTrip: TripListItem?
    @State private var errorMessage: String?
    @State private var needsTopUp = false
    @State private var failed = 0

    private var selected: TripListItem? { trips?.first { $0.id == selectedID } }

    var body: some View {
        NavigationStack {
            Group {
                if let sentTrip {
                    sentView(sentTrip)
                } else if let trips {
                    picker(trips)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't Load Trips", systemImage: "map")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.bordered)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Add to Trip")
            .summaryInlineNavigationTitle()
            .toolbar { toolbar }
        }
        .summarySheetSize()
        .overlay {
            if isSending { ActionStatusOverlay(String(localized: "Sending to the agent…")) }
        }
        .interactiveDismissDisabled(isSending)
        .task { await load() }
        .onDisappear {
            if let sourceFile { LocalDocument.discardCopy(sourceFile) }
        }
        .statusAlert("Couldn't Send", message: errorMessage) { errorMessage = nil }
        .alert("Not Enough Points", isPresented: $needsTopUp) {
            Button("Open Chippy") {
                if let url = URL(string: "summarychip://top-up") { openURL(url) }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Updating a trip from what you share uses points. Top up in Chippy to continue.")
        }
        .sensoryFeedback(.success, trigger: sentTrip?.id)
        .sensoryFeedback(.error, trigger: failed)
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if sentTrip != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: finish).fontWeight(.semibold)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel, action: cancel)
                    .disabled(isSending)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { Task { await send() } }
                    .fontWeight(.semibold)
                    .disabled(selected == nil || isSending)
                    .accessibilityIdentifier("share-trip-send")
            }
        }
    }

    private func picker(_ trips: [TripListItem]) -> some View {
        Form {
            if trips.isEmpty {
                Section {
                    Text("You have no trips yet. Create one in Chippy first, then share to it.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(trips) { trip in
                        Button { selectedID = trip.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trip.title).foregroundStyle(.primary)
                                    Text("\(trip.startDate) – \(trip.endDate)")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if trip.id == selectedID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(trip.id == selectedID ? .isSelected : [])
                    }
                } header: {
                    Text("Trip")
                }
                Section {
                    TextField("Instructions (optional)", text: $instructions, prompt: Text("e.g. This is our hotel in Sendai"), axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("The agent reads \(input.displayTitle) and adds what's useful: trains, flights, hotels, costs. Uses points.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func sentView(_ trip: TripListItem) -> some View {
        ContentUnavailableView {
            Label("Sent", systemImage: "checkmark.circle.fill")
        } description: {
            Text("The agent will update \(trip.title). You'll get a notification when it's done.")
        } actions: {
            Button {
                openURL(SummaryLink.openTripURL(tripID: trip.id))
            } label: {
                Label("Open in Chippy", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("share-trip-open")
        }
    }

    private func load() async {
        loadError = nil
        do {
            let today = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let sorted = TripListItem.sortedForPicking(try await api.listTrips(), today: today)
            trips = sorted
            if selectedID == nil { selectedID = sorted.first?.id }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func send() async {
        guard let trip = selected else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await api.ingestIntoTrip(id: trip.id, input: input, instructions: instructions)
            withAnimation { sentTrip = trip }
        } catch let error as SummaryAPIError where error.needsTopUp {
            failed += 1
            needsTopUp = true
        } catch {
            failed += 1
            errorMessage = error.localizedDescription
        }
    }
}
