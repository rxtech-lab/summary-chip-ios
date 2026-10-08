// TODO: Split this file; it predates the SwiftLint size limits.
// swiftlint:disable file_length type_body_length

import MapKit
import SummaryKit
import SwiftUI
import UniformTypeIdentifiers

/// A trip diary whose scroll drives the map: the camera frames the day being read and a traveler
/// moves along its route. iPad and Mac show map and diary side by side; iPhone shows the map
/// full screen with the diary in a persistent bottom sheet, like Maps.
struct TripDetailView: View {
    let environment: AppEnvironment
    let title: String
    let onOpenTrip: (() -> Void)?
    @State private var model: TripEditorModel
    @State private var camera = TripMapCamera()
    @State private var location = LocationProvider()
    @State private var activeDayID: String?
    @State private var progress: Double = 0
    @State private var diaryScroll = ScrollPosition(idType: String.self)
    /// The day the diary was last scrolled to, so it can catch up after another pane moved the day.
    @State private var diaryDayID: String?
    @State private var activeSheet: TripSheet?
    @State private var pane: TripPane = .diary
    @State private var showsDiary = false
    @State private var detent: PresentationDetent = .medium
    @State private var sheetHeight: CGFloat = 0
    @State private var safeArea = EdgeInsets()
    @State private var didOpen = false
    @State private var locationMessage: String?
    @State private var confirmsCover = false
    @State private var coverError: String?
    @State private var calendarSynced = false
    @State private var confirmsCalendarRemoval = false
    @State private var calendarError: String?
    /// The trip's library item, which carries its share link and sharing settings.
    @State private var shareItem: Summary?
    @State private var isLoadingShare = false
    @State private var shareError: String?
    @State private var isTogglingLike = false
    @State private var likeStatus: LikeStatus?
    /// The transport or hotel waiting for the user to confirm its deletion.
    @State private var pendingDeletion: TripRecord?
    @State private var isDeletingRecord = false
    @State private var deleteError: String?
    @State private var deleteFailed = 0
    /// The printed report while the Save dialog is up.
    @State private var exportedPDF: TripPDFDocument?
    @State private var isExportingPDF = false
    @State private var exportError: String?
    @State private var exportFinished = 0
    @State private var exportFailed = 0
    @State private var planError: String?
    @State private var planFailed = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private static let collapsedDetent = PresentationDetent.fraction(0.12)

    init(environment: AppEnvironment, tripID: String, title: String = "", onOpenTrip: (() -> Void)? = nil) {
        self.environment = environment
        self.title = title
        self.onOpenTrip = onOpenTrip
        _model = State(initialValue: TripEditorModel(api: environment.api, id: tripID))
    }

    private var isCompact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var isOwner: Bool { model.trip?.isOwner ?? false }
    /// Only the owner edits, and only the trip as written: a translation is read-only.
    private var canEdit: Bool { isOwner && model.trip?.isTranslated == false }

    /// The language the diary is shown in; the owner can change it from the header's note.
    private var reading: TripReadingLanguage? {
        guard let trip = model.trip else { return nil }
        return TripReadingLanguage(
            language: trip.language,
            originalLanguage: trip.originalLanguage,
            translatingTo: trip.translating ? trip.displayLanguage : nil,
            changeLanguage: trip.isOwner ? { present(.language) } : nil
        )
    }

    private var navigationTitle: String? {
        #if os(macOS)
        // Omit the native title area when the preview supplies its own top bar.
        if onOpenTrip != nil { return nil }
        #endif
        return model.document?.title ?? title
    }

    var body: some View {
        Group {
            if let document = model.displayDocument {
                content(document)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("Trip unavailable", systemImage: "map")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.load() } }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView("Opening trip…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(TripNavigationTitle(title: navigationTitle))
        .summaryInlineNavigationTitle()
        .summaryHideTabBar()
        .toolbar {
            toolbar
            #if os(iOS)
            if onOpenTrip != nil {
                ToolbarItem(placement: .topBarLeading) { openTripButton }
            }
            #endif
        }
        #if os(macOS)
        .safeAreaInset(edge: .top, spacing: 0) {
            if onOpenTrip != nil {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        Text(model.document?.title ?? title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 16)
                        openTripButton
                            .fixedSize()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.bar)
                    Divider()
                }
            }
        }
        #endif
        .environment(\.tripEditable, canEdit)
        .environment(\.tripReading, reading)
        .environment(\.tripFlights, model.flights)
        .environment(\.tripWeather, model.weather)
        .environment(\.tripPlaces, model.document?.places ?? [])
        .environment(\.tripShowPlace, showPlace)
        .overlay(alignment: .top) {
            if let notice = model.notice {
                Label(notice.message, systemImage: notice.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("trip-notice")
            }
        }
        .animation(.spring(duration: 0.35), value: model.notice)
        .likeStatusOverlay($likeStatus, edge: .top)
        .task {
            await model.load()
            await openOnRelevantDay()
        }
        .onAppear {
            showsDiary = true
            location.startLiveUpdates()
        }
        .onDisappear {
            showsDiary = false
            location.stopLiveUpdates()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refresh() } }
        }
        // Trip updates and flight alerts for this trip while it's open.
        .onReceive(NotificationCenter.default.publisher(for: .summaryTripPushReceived)) { note in
            guard note.object as? String == model.id else { return }
            Task { await model.refresh() }
        }
        .onChange(of: activeDayID) { _, id in
            guard let document = model.displayDocument else { return }
            camera.show(dayID: id, in: document)
        }
        .statusAlert("Couldn't Switch Plan", message: planError) { planError = nil }
        .sensoryFeedback(.error, trigger: planFailed)
        .statusAlert("Location Unavailable", message: locationMessage) { locationMessage = nil }
        .statusAlert("Couldn't Generate Cover", message: coverError) { coverError = nil }
        .confirmationDialog("Generate a new cover?", isPresented: $confirmsCover, titleVisibility: .visible) {
            Button("Generate Cover") { generateCover() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new illustration replaces the trip's current cover.")
        }
        .statusAlert("Calendar Not Updated", message: calendarError) { calendarError = nil }
        .statusAlert("Couldn't Share Trip", message: shareError) { shareError = nil }
        .confirmationDialog("Remove this trip from your calendar?", isPresented: $confirmsCalendarRemoval, titleVisibility: .visible) {
            Button("Remove from Calendar", role: .destructive) { removeFromCalendar() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The events Chippy added for this trip are deleted from your calendar.")
        }
        .onAppear { calendarSynced = TripCalendarSync.shared.isSynced(tripID: model.id) }
        // Keep the calendar in step with the trip once it has been added.
        .onChange(of: model.trip?.revision) { old, new in
            guard old != nil, old != new, calendarSynced else { return }
            Task { try? await model.syncCalendar(quietly: true) }
        }
        .sensoryFeedback(.selection, trigger: activeDayID)
        .sensoryFeedback(.selection, trigger: pane)
        .sensoryFeedback(.selection, trigger: activeSheet)
        .sensoryFeedback(.success, trigger: model.savedCount)
        .sensoryFeedback(trigger: model.notice) { _, notice in
            [.coverUpdated, .agentDone, .calendarSynced, .calendarRemoved, .languageChanged].contains(notice) ? .success : nil
        }
    }

    // MARK: Layout

    private var openTripButton: some View {
        Button {
            onOpenTrip?()
        } label: {
            Label("Open Trip", systemImage: "arrow.up.right.square")
        }
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("chat-open-trip-detail")
    }

    @ViewBuilder
    private func content(_ document: TripDocument) -> some View {
        #if os(iOS)
        if isCompact {
            compactLayout(document)
        } else {
            regularLayout(document)
        }
        #else
        regularLayout(document)
        #endif
    }

    /// Map (about 45%) beside the diary.
    private func regularLayout(_ document: TripDocument) -> some View {
        HStack(spacing: 0) {
            map(document)
                .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }
            Divider()
            diary(document) { height in min(180, height * 0.28) }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if pane == .diary {
                        TripDiaryBar(document: document, activeDayID: activeDayID, onSelect: jump)
                            .background(.bar)
                    }
                }
        }
        .overlay {
            if isExportingPDF { ActionStatusOverlay(String(localized: "Preparing PDF…")) }
        }
        .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
    }

    #if os(iOS)
    /// Full-screen map; the diary lives in a sheet that stays up while the trip is shown.
    private func compactLayout(_ document: TripDocument) -> some View {
        map(document)
            .ignoresSafeArea()
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
                safeArea = insets
                updateObscured()
            }
            .sheet(isPresented: $showsDiary) {
                diary(document) { _ in 28 }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if pane == .diary {
                            TripDiaryBar(document: document, activeDayID: activeDayID, onSelect: jump)
                                .clipShape(.rect(cornerRadius: 26))
                                .glassEffect(.regular, in: .rect(cornerRadius: 26))
                                .padding(.horizontal, 10)
                                .padding(.top, 6)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        sheetHeight = height
                        updateObscured()
                    }
                    // Cover the diary bar too; the collapsed sheet has no room for the export status.
                    .overlay {
                        if isExportingPDF { ActionStatusOverlay(String(localized: "Preparing PDF…")) }
                    }
                    .presentationDetents(
                        isExportingPDF ? [.medium, .large] : [Self.collapsedDetent, .medium, .large],
                        selection: $detent
                    )
                    .presentationBackgroundInteraction(isExportingPDF ? .disabled : .enabled(upThrough: .medium))
                    .presentationContentInteraction(.scrolls)
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled()
                    .environment(\.tripEditable, canEdit)
                    .environment(\.tripReading, reading)
                    .environment(\.tripFlights, model.flights)
                    .environment(\.tripWeather, model.weather)
                    .environment(\.tripPlaces, model.document?.places ?? [])
                    .environment(\.tripShowPlace, showPlace)
                    // Editors present from the diary sheet, over it.
                    .sheet(item: $activeSheet) { sheet in sheetContent(sheet) }
            }
            // Hotels and expenses need room; lift the collapsed sheet when switching to them.
            .onChange(of: pane) { _, pane in
                if pane != .diary, detent == Self.collapsedDetent { detent = .medium }
            }
            .onChange(of: detent) { _, detent in
                camera.frozen = detent == .large
                if detent != .large { camera.show(dayID: activeDayID, in: document, force: true) }
            }
            // Re-fit once the sheet settles at a new height.
            .task(id: Int(sheetHeight / 24)) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let document = model.displayDocument else { return }
                camera.show(dayID: activeDayID, in: document, force: true)
            }
    }
    #endif

    private func map(_ document: TripDocument) -> some View {
        TripMapView(
            document: document,
            activeDayID: activeDayID,
            progress: progress,
            camera: camera,
            location: location,
            onSelectPlace: { place in
                if let day = document.orderedDays.first(where: { document.placeIDs(for: $0).contains(place.id) }) { jump(to: day.id) }
                camera.center(on: place.coordinate.clCoordinate)
            },
            onOpenPlace: { showPlace($0.id) },
            usesInlinePlaceCallout: isCompact
        )
        .overlay(alignment: .topTrailing) {
            TripMapControls(
                following: camera.following,
                overview: camera.overview,
                onFollow: {
                    if camera.following { camera.following = false } else { camera.resumeFollowing(dayID: activeDayID, in: document) }
                },
                onWholeTrip: { camera.showWholeTrip(document) },
                onLocate: locate
            )
            .padding(.top, isCompact ? safeArea.top + 8 : 12)
            .padding(.trailing, 12)
        }
    }

    /// The diary, or the hotels or expenses pane over it. The diary stays laid out underneath so
    /// switching back keeps its scroll position and the day the map follows.
    private func diary(_ document: TripDocument, readingLine: @escaping (CGFloat) -> CGFloat) -> some View {
        ZStack {
            TripDiaryView(
                document: document,
                planSelections: model.planSelections,
                onSelectPlanOption: selectPlanOption,
                activeDayID: activeDayID,
                scrollPosition: $diaryScroll,
                readingLine: readingLine,
                onRead: { dayID, progress in
                    diaryDayID = dayID
                    // Hidden, the diary only moves to catch up; the pane on top owns the day.
                    guard pane == .diary else { return }
                    read(dayID, progress)
                },
                present: present
            )
            .opacity(pane == .diary ? 1 : 0)
            .allowsHitTesting(pane == .diary)
            .accessibilityHidden(pane != .diary)
            switch pane {
            case .diary: EmptyView()
            case .bookings: TripBookingsPane(document: document, present: present)
            case .expenses: TripExpensesPane(document: document, present: present)
            }
        }
        // Back in the diary, open on the day being read.
        .onChange(of: pane) { _, pane in
            guard pane == .diary, let activeDayID, activeDayID != diaryDayID else { return }
            diaryScroll.scrollTo(id: activeDayID, anchor: .top)
        }
        // Context-menu deletes of transport and hotels; here so they show over the iPhone diary sheet.
        .environment(\.tripRecordActions, recordActions)
        .overlay {
            if isDeletingRecord { ActionStatusOverlay(String(localized: "Deleting…")) }
        }
        .statusAlert("Couldn't Delete", message: deleteError) { deleteError = nil }
        .confirmationDialog(
            pendingDeletion?.deleteTitle ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { record in
            Button(record.deleteTitle, role: .destructive) { delete(record) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(record.deleteMessage)
        }
        .sensoryFeedback(.error, trigger: deleteFailed)
        // Present the save dialog and errors from the diary sheet on iPhone.
        .statusAlert("Couldn't Export PDF", message: exportError) { exportError = nil }
        .fileExporter(
            isPresented: Binding(get: { exportedPDF != nil }, set: { if !$0 { exportedPDF = nil } }),
            document: exportedPDF,
            contentType: .pdf,
            defaultFilename: exportedPDF?.filename
        ) { result in
            switch result {
            case .success: exportFinished += 1
            case .failure(let error):
                exportFailed += 1
                exportError = error.localizedDescription
            }
        }
        .sensoryFeedback(.success, trigger: exportFinished)
        .sensoryFeedback(.error, trigger: exportFailed)
        .sensoryFeedback(.selection, trigger: isExportingPDF) { _, exporting in exporting }
    }

    /// The diary's scroll moved to another day, or further through one; the map follows.
    private func read(_ dayID: String, _ progress: Double) {
        if activeDayID != dayID { activeDayID = dayID }
        self.progress = progress
    }

    /// The parts of the map under the navigation bar and the diary sheet.
    private func updateObscured() {
        guard isCompact else {
            camera.obscured = EdgeInsets()
            return
        }
        camera.obscured = EdgeInsets(top: safeArea.top, leading: 0, bottom: max(sheetHeight, safeArea.bottom), trailing: 0)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.document != nil {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $pane) {
                    ForEach(TripPane.allCases) { pane in
                        // Icons only on iPhone, where the bar is narrow.
                        Group {
                            if isCompact {
                                Image(systemName: pane.systemImage).accessibilityLabel(pane.title)
                            } else {
                                Text(pane.title)
                            }
                        }
                        .tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Section")
                .accessibilityIdentifier("trip-pane-picker")
            }
        }
        // iPhone's bar is too narrow for the segmented picker and four buttons; fold them into More.
        if canEdit, model.document != nil, !isCompact {
            ToolbarItem(placement: .summaryTrailing) {
                Menu {
                    addMenuItems
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("trip-add-menu")
            }
            ToolbarItem(placement: .summaryTrailing) {
                Button { present(.agent) } label: {
                    Label("Ask Trip Agent", systemImage: "sparkles")
                }
                .help("Ask Trip Agent")
                .accessibilityIdentifier("trip-agent")
            }
        }
        if model.document != nil {
            if !isCompact {
                ToolbarItem(placement: .summaryTrailing) {
                    likeButton
                }
                ToolbarItem(placement: .summaryTrailing) {
                    Button { openSharing(.share) } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share")
                    .disabled(isLoadingShare)
                    .accessibilityIdentifier("trip-share")
                }
            }
            ToolbarItem(placement: .summaryTrailing) {
                Menu {
                    if isCompact {
                        if canEdit {
                            Menu {
                                addMenuItems
                            } label: {
                                Label("Add", systemImage: "plus")
                            }
                            .accessibilityIdentifier("trip-add-menu")
                            Button { present(.agent) } label: { Label("Ask Trip Agent", systemImage: "sparkles") }
                                .accessibilityIdentifier("trip-agent")
                        }
                        likeButton
                        Button { openSharing(.share) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                            .disabled(isLoadingShare)
                            .accessibilityIdentifier("trip-share")
                        Divider()
                    }
                    if canEdit {
                        Button { present(.meta) } label: { Label("Trip Details", systemImage: "info.circle") }
                            .accessibilityIdentifier("trip-details")
                    }
                    if isOwner {
                        Button { present(.language) } label: { Label("Language…", systemImage: "translate") }
                            .accessibilityIdentifier("trip-language")
                        Button { confirmsCover = true } label: { Label("Generate Cover", systemImage: "wand.and.stars") }
                            .disabled(model.notice == .generatingCover)
                            .accessibilityIdentifier("trip-generate-cover")
                        Button { openSharing(.editSharing) } label: { Label("Edit Sharing…", systemImage: "globe") }
                            .disabled(isLoadingShare)
                            .accessibilityIdentifier("trip-edit-sharing")
                        Divider()
                    }
                    Button { exportPDF() } label: {
                        Label("Export PDF…", systemImage: "doc.richtext")
                    }
                    .disabled(isExportingPDF)
                    .accessibilityIdentifier("trip-export-pdf")
                    Button { syncCalendar() } label: {
                        Label(calendarSynced ? "Update Calendar" : "Add to Calendar", systemImage: "calendar.badge.plus")
                    }
                    .disabled(model.notice == .syncingCalendar)
                    .accessibilityIdentifier("trip-calendar-sync")
                    if calendarSynced {
                        Button(role: .destructive) { confirmsCalendarRemoval = true } label: {
                            Label("Remove from Calendar", systemImage: "calendar.badge.minus")
                        }
                        .accessibilityIdentifier("trip-calendar-remove")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More")
                .accessibilityIdentifier("trip-more-menu")
            }
        }
    }

    private var likeButton: some View {
        Button {
            toggleLike()
        } label: {
            Label(model.likedAt == nil ? "Add to Likes" : "Remove from Likes",
                  systemImage: model.likedAt == nil ? "star" : "star.fill")
        }
        .help(model.likedAt == nil ? "Add to Likes" : "Remove from Likes")
        .disabled(isTogglingLike)
        .accessibilityIdentifier("trip-like")
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button { present(.day(nil)) } label: { Label("Day", systemImage: "calendar.badge.plus") }
        Button { present(.place(nil)) } label: { Label("Place", systemImage: "mappin.and.ellipse") }
        Button { present(.transport(nil)) } label: { Label("Transport", systemImage: "tram") }
        Button { present(.hotel(nil)) } label: { Label("Hotel", systemImage: "bed.double") }
        Button { present(.expense(nil)) } label: { Label("Expense", systemImage: "creditcard") }
        Button { present(.view(nil)) } label: { Label("View", systemImage: "rectangle.3.group") }
    }

    private func generateCover() {
        Task {
            do {
                environment.library.upsert(try await model.generateCover())
            } catch is CancellationError {
            } catch {
                coverError = error.localizedDescription
            }
        }
    }

    private func syncCalendar() {
        Task {
            do {
                try await model.syncCalendar()
                calendarSynced = true
            } catch {
                calendarError = error.localizedDescription
            }
        }
    }

    private func removeFromCalendar() {
        Task {
            do {
                try await model.removeFromCalendar()
                calendarSynced = false
            } catch {
                calendarError = error.localizedDescription
            }
        }
    }

    // MARK: Likes

    /// The star flips at once; it flips back if the server refuses.
    private func toggleLike() {
        let original = model.likedAt
        let liked = original == nil
        isTogglingLike = true
        model.likedAt = liked ? .now : nil
        Task {
            defer { isTogglingLike = false }
            do {
                model.likedAt = try await environment.setTripLiked(id: model.id, liked)
                likeStatus = LikeStatus(outcome: liked ? .liked : .unliked)
            } catch {
                model.likedAt = original
                likeStatus = LikeStatus(outcome: .failed(error.localizedDescription))
            }
        }
    }

    // MARK: Export

    /// Has the server print the trip as an A4 report, then asks where to save it (Files on iPhone and iPad).
    private func exportPDF() {
        guard !isExportingPDF else { return }
        let title = model.document?.title ?? title
        if isCompact, detent == Self.collapsedDetent { detent = .medium }
        isExportingPDF = true
        Task {
            defer { isExportingPDF = false }
            do {
                let data = try await environment.api.tripPDF(id: model.id)
                exportedPDF = TripPDFDocument(data: data, title: title)
            } catch is CancellationError {
            } catch {
                exportFailed += 1
                exportError = error.localizedDescription
            }
        }
    }

    // MARK: Sharing

    /// Trips share through their library item: same link, same sharing settings as a summary.
    private func openSharing(_ sheet: TripSheet) {
        Task {
            isLoadingShare = true
            defer { isLoadingShare = false }
            do {
                shareItem = try await environment.api.summary(id: model.id)
                present(sheet)
            } catch is CancellationError {
            } catch {
                shareError = error.localizedDescription
            }
        }
    }

    private func sharingSaved(_ updated: Summary) {
        shareItem = updated
        environment.library.upsert(updated)
        Task { await model.load() }
    }

    /// The trip's library card is translated with it; the diary reloads in the new language.
    private func languageSaved(_ updated: Summary) {
        if shareItem != nil { shareItem = updated }
        environment.library.upsert(updated)
        Task { await model.languageChanged() }
    }

    // MARK: Sheets

    private func present(_ sheet: TripSheet) {
        // Read-only sheets open for anyone; settings only for the owner; editors only for the trip as written.
        switch sheet {
        case .dayDetail, .transportDetail, .placeDetail, .places, .notes, .sources, .currency, .share: break
        case .editSharing, .language: if !isOwner { return }
        default: if !canEdit { return }
        }
        // On iPhone the diary sheet presents editors; make sure it's up.
        if isCompact && !showsDiary { showsDiary = true }
        activeSheet = sheet
    }

    /// A place's details, from the map, places list, diary or a custom view's place card.
    private func showPlace(_ id: String) {
        present(.placeDetail(id))
    }

    /// The trip agent's chat, like the other agents'; its edits reload the trip underneath.
    private func tripAgent(document: TripDocument, isExpense: Bool) -> some View {
        ChatView(
            environment: environment,
            trip: TripChat(id: model.id, title: document.title, isExpense: isExpense),
            onTripUpdated: { [model] in Task { await model.agentDidEdit() } }
        )
    }

    /// Sheets look records up in the trip as the user follows it; edits still go to the whole trip.
    @ViewBuilder
    private func sheetContent(_ sheet: TripSheet) -> some View {
        if let document = model.displayDocument {
            Group {
                switch sheet {
                case .meta:
                    TripMetaEditorSheet(model: model, document: document) { deleted() }
                case .day(let id):
                    DayEditorSheet(model: model, document: document, day: document.day(id: id))
                case .dayDetail(let id):
                    // After switching routes the sheet shows the picked option's day for the same date.
                    if let day = document.day(id: id) ?? model.document?.day(id: id).flatMap({ old in document.orderedDays.first { $0.date == old.date } }) {
                        TripDayDetailSheet(
                            document: document,
                            day: day,
                            onEdit: { activeSheet = .day(day.id) },
                            onOpenTransport: { activeSheet = .transportDetail($0.id) },
                            onEditView: { if canEdit { activeSheet = .view($0.id) } },
                            planSelections: model.planSelections,
                            onSelectPlanOption: selectPlanOption
                        )
                    }
                case .place(let id):
                    PlaceEditorSheet(model: model, document: document, place: document.place(id: id))
                case .transport(let id):
                    TransportEditorSheet(model: model, document: document, transport: document.transport(id: id), date: document.day(id: activeDayID)?.date)
                case .transportDetail(let id):
                    if let transport = document.transport(id: id) {
                        TransportDetailSheet(document: document, transport: transport) { activeSheet = .transport(id) }
                    }
                case .hotel(let id):
                    HotelEditorSheet(model: model, document: document, hotel: document.hotel(id: id))
                case .expense(let id):
                    ExpenseEditorSheet(model: model, document: document, expense: document.expense(id: id))
                case .view(let id):
                    TripViewEditorSheet(model: model, document: document, view: document.view(id: id), dayID: pane == .diary ? activeDayID : nil)
                case .placeDetail(let id):
                    if let place = document.place(id: id) {
                        TripPlaceDetailSheet(document: document, place: place) { activeSheet = .place(id) }
                    }
                case .places:
                    TripPlacesSheet(places: document.places, onOpen: { activeSheet = .placeDetail($0.id) }, onAdd: { activeSheet = .place(nil) })
                case .notes:
                    TripNotesSheet(notes: document.notes)
                case .sources:
                    TripSourcesSheet(sources: document.sources)
                case .agent:
                    tripAgent(document: document, isExpense: false)
                case .expenseAgent:
                    tripAgent(document: document, isExpense: true)
                case .currency:
                    CurrencyConversionSheet(defaultCurrency: document.currency)
                case .share:
                    if let shareItem {
                        ShareModeSheet(summary: shareItem, api: environment.api) { updated in sharingSaved(updated) }
                    }
                case .editSharing:
                    if let shareItem {
                        EditSharingSheet(api: environment.api, summary: shareItem) { updated in sharingSaved(updated) }
                    }
                case .language:
                    if let trip = model.trip {
                        DisplayLanguageSheet(api: environment.api, trip: trip) { updated in languageSaved(updated) }
                    }
                }
            }
            .environment(\.tripEditable, canEdit)
            .environment(\.tripReading, reading)
            .environment(\.tripFlights, model.flights)
            .environment(\.tripWeather, model.weather)
            .environment(\.tripPlaces, model.document?.places ?? [])
            .environment(\.tripShowPlace, showPlace)
        }
    }

    // MARK: Deleting

    private var recordActions: TripRecordActions {
        TripRecordActions(edit: { present($0.editSheet) }, delete: { pendingDeletion = $0 })
    }

    /// Deletes a transport or hotel from its card's context menu.
    private func delete(_ record: TripRecord) {
        guard canEdit, !isDeletingRecord else { return }
        isDeletingRecord = true
        Task {
            defer { isDeletingRecord = false }
            do {
                try await model.update { $0.remove(record.collection, id: record.id) }
            } catch is CancellationError {
            } catch {
                deleteFailed += 1
                deleteError = error.localizedDescription
            }
        }
    }

    private func deleted() {
        environment.library.remove(id: model.id)
        showsDiary = false
        activeSheet = nil
        dismiss()
    }

    // MARK: Navigation

    /// Scrolls the diary to a day; the scroll then moves the map.
    private func jump(to dayID: String) {
        guard let document = model.displayDocument else { return }
        diaryDayID = dayID
        pane = .diary
        activeDayID = dayID
        progress = 0
        if !camera.following { camera.resumeFollowing(dayID: dayID, in: document) }
        withAnimation(.easeInOut(duration: 0.4)) { diaryScroll.scrollTo(id: dayID, anchor: .top) }
    }

    /// Opens on today's day while travelling; otherwise, with location already allowed, on the day
    /// visiting the trip place nearest to the user (within 50 km). Else on day 1.
    private func openOnRelevantDay() async {
        guard !didOpen, let document = model.displayDocument else { return }
        didOpen = true
        let first = document.orderedDays.first?.id
        activeDayID = first
        camera.show(dayID: first, in: document, force: true, animated: false)
        // Let the diary lay out (and on iPhone, its sheet present) before scrolling it.
        try? await Task.sleep(for: .milliseconds(450))
        if let today = document.day(for: Date()), document.contains(Date()) {
            jump(to: today.id)
            return
        }
        location.refreshAuthorization()
        guard location.isAuthorized,
              let here = await location.currentLocation(timeout: .seconds(5)),
              let day = document.nearestDay(to: here.coordinate) else { return }
        jump(to: day.id)
    }

    // MARK: Plans

    /// Follows another option of a plan. The diary stays on the same date: when the day being read
    /// belonged to the option left, the new option's day for that date takes its place.
    private func selectPlanOption(_ plan: TripPlan, _ option: TripPlanOption) {
        let date = model.displayDocument?.day(id: activeDayID)?.date
        let save = model.selectPlanOption(planID: plan.id, optionID: option.id)
        Task {
            do {
                try await save.value
            } catch is CancellationError {
            } catch {
                planFailed += 1
                planError = error.localizedDescription
            }
        }
        // The pick already shows; keep the reading day in step.
        guard let document = model.displayDocument else { return }
        if let activeDayID, document.day(id: activeDayID) != nil {
            camera.show(dayID: activeDayID, in: document, force: true)
            return
        }
        let replacement = document.orderedDays.first { $0.date == date } ?? document.orderedDays.first
        if let replacement { jump(to: replacement.id) }
    }

    private func locate() {
        location.requestAccess()
        Task {
            if let here = await location.currentLocation(timeout: .seconds(12)) {
                camera.center(on: here.coordinate)
            } else if location.isDenied {
                locationMessage = String(localized: "Location access is off. Allow it for Chippy in Settings.")
            } else {
                locationMessage = String(localized: "Couldn't find your location. Try again.")
            }
        }
    }
}


/// An empty navigation title still reserves a title row in a macOS sheet.
private struct TripNavigationTitle: ViewModifier {
    let title: String?

    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title)
        } else {
            content
        }
    }
}

/// A trip's printed report, for the Save dialog.
struct TripPDFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data
    /// "Kyoto weekend", from the trip's title.
    let filename: String

    init(data: Data, title: String) {
        self.data = data
        let name = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        self.filename = name.isEmpty ? String(localized: "Trip") : name
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
        self.filename = configuration.file.filename ?? String(localized: "Trip")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
