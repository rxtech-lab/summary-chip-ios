import MapKit
import SummaryKit
import SwiftUI

/// Play mode: the trip as a guided tour. The camera glides from stop to stop, each day's route
/// draws itself while the narrator speaks, sights pop up with their photo, and the caption panel
/// shows the guide's stories as subtitles. Given a day, plays
/// only that day's part of the tour.
struct TripTourView: View {
    let document: TripDocument
    let dayID: String?
    @State private var player: TripTourPlayer
    @State private var camera = TripMapCamera()
    @State private var panelHeight: CGFloat = 0
    @State private var topBarHeight: CGFloat = 0
    @State private var safeArea = EdgeInsets()
    /// The space for the top bar and caption, inside the safe area.
    @State private var layerSize: CGSize = .zero
    /// The panel shrunk to a caption line, leaving the map in view.
    @State private var isMinimized = true
    @State private var confirmsRegenerate = false
    @State private var visualTimeline = TripTourVisualTimeline()
    @State private var viewingPhoto: TripPhotoViewerItem?
    @State private var resumesAfterPhotos = false
    @State private var landmarks = TripTourLandmarks()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(api: SummaryAPIClient, tripID: String, document: TripDocument, dayID: String? = nil) {
        self.document = document
        self.dayID = dayID
        _player = State(initialValue: TripTourPlayer(api: api, tripID: tripID, dayID: dayID))
    }

    private var tourDay: (day: TripDay, number: Int)? {
        guard let dayID, let index = document.orderedDays.firstIndex(where: { $0.id == dayID }) else { return nil }
        return (document.orderedDays[index], index + 1)
    }

    /// "Day 2 · Kyoto" for a day's tour, else the trip's title.
    private var title: String {
        guard let tourDay else { return document.title }
        return String(localized: "Day \(tourDay.number) · \(tourDay.day.title)")
    }

    /// A landscape screen: the caption and controls sit in the left half, beside the map.
    private var isWide: Bool { layerSize.width > layerSize.height }

    private var failure: String? {
        if case .failed(let message) = player.phase { message } else { nil }
    }

    private var focus: TripTourFocus? { visualTimeline.focus(at: player.sceneProgress) }
    private var spotlight: TripTourSpotlight? { TripTourSpotlight(scene: player.scene, focus: focus, document: document, landmarks: landmarks) }

    var body: some View {
        ZStack {
            TripTourMap(document: document, tour: player.tour, index: player.index, progress: player.sceneProgress, focus: focus, spotlight: spotlight, camera: camera, onOpenPhoto: openPhoto)
                .ignoresSafeArea()
                .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { safeArea = $0 }
            VStack(spacing: 0) {
                topBar
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topBarHeight = $0 }
                Spacer(minLength: 0)
                if let scene = player.scene {
                    TripTourCaption(document: document, scene: scene, index: player.index, player: player, isWide: isWide, isMinimized: $isMinimized)
                        .frame(maxWidth: isWide ? .infinity : 680)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                        .transition(.move(edge: isWide ? .leading : .bottom).combined(with: .opacity))
                }
            }
            .frame(width: isWide ? layerSize.width / 2 : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { layerSize = $0 }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .overlay {
            if player.phase == .loading {
                ActionStatusOverlay(String(localized: "Writing your tour…"))
            } else if player.phase == .finished, player.sceneCount == 0 {
                // Nothing to play: a day the tour doesn't cover yet.
                ContentUnavailableView {
                    Label("Nothing to Play", systemImage: "play.slash")
                } description: {
                    Text("The tour doesn't cover this day yet. Regenerate it to include the trip as it is now.")
                } actions: {
                    Button("Regenerate Tour") { confirmsRegenerate = true }
                        .buttonStyle(.glassProminent)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 28))
                .padding(24)
            }
        }
        .animation(.spring(duration: 0.5), value: player.tour != nil)
        .animation(.spring(duration: 0.4), value: isMinimized)
        .task { await player.start() }
        .task(id: player.scene?.landmarks) { await landmarks.resolve(player.scene?.landmarks ?? [], in: document) }
        .onDisappear { player.stop() }
        .onChange(of: player.index) { _, _ in flyToScene() }
        .onChange(of: player.tour?.createdAt) { _, _ in flyToScene() }
        .onChange(of: focus?.destinationId) { _, _ in flyToFocus() }
        .onChange(of: spotlight?.coordinate) { _, _ in flyToFocus() }
        .onChange(of: panelHeight) { _, _ in updateObscured() }
        .onChange(of: topBarHeight) { _, _ in updateObscured() }
        .onChange(of: layerSize) { _, _ in updateObscured() }
        // The free part of the map moved; re-frame the scene in it.
        .onChange(of: isWide) { _, _ in flyToScene() }
        .sheet(item: $viewingPhoto) { TripPhotoViewer(photos: $0.photos, start: $0.start) }
        .onChange(of: viewingPhoto?.id) { _, value in
            if value == nil, resumesAfterPhotos {
                resumesAfterPhotos = false
                player.play()
            }
        }
        .onAppear {
            updateObscured()
            if let tourDay {
                camera.fly(to: document.focusCoordinates(for: tourDay.day), minimumMeters: 25_000, duration: 0.01)
            } else {
                camera.showWholeTrip(document)
            }
        }
        .alert("Couldn't Play Tour", isPresented: Binding(get: { failure != nil }, set: { _ in })) {
            Button("Try Again") { Task { await player.start() } }
            Button("Close", role: .cancel) { dismiss() }
        } message: {
            Text(failure ?? "")
        }
        .confirmationDialog("Regenerate this tour?", isPresented: $confirmsRegenerate, titleVisibility: .visible) {
            Button("Regenerate") { Task { await player.start(regenerate: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The narration is written again from the trip as it is now. This uses points.")
        }
        .sensoryFeedback(.selection, trigger: player.sceneChanges)
        .sensoryFeedback(.impact(weight: .light), trigger: isMinimized)
        .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
        .sensoryFeedback(.selection, trigger: focus?.destinationId)
        .sensoryFeedback(.impact(weight: .light), trigger: viewingPhoto?.id)
        .sensoryFeedback(trigger: player.phase) { _, phase in
            switch phase {
            case .finished: .success
            case .failed: .error
            default: nil
            }
        }
        #if os(macOS)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 640, idealHeight: 780)
        .onKeyPress(.space) {
            player.togglePlayback()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            player.next()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            player.previous()
            return .handled
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trip-tour")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Label("Close Tour", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("trip-tour-close")
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if player.sceneCount > 0 {
                    ProgressView(value: player.overallProgress)
                        .progressViewStyle(.linear)
                        .tint(TripStyle.color(for: .out))
                        .animation(.linear(duration: 0.2), value: player.overallProgress)
                        .accessibilityLabel(Text("Stop \(player.index + 1) of \(player.sceneCount)"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            Spacer(minLength: 0)
            Button {
                confirmsRegenerate = true
            } label: {
                Label("Regenerate Tour", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(player.tour == nil || player.phase == .loading)
            .accessibilityIdentifier("trip-tour-regenerate")
        }
        .padding(.top, 4)
    }

    /// The map's free area: right of the left column when wide, else between the top bar and the caption panel.
    private func updateObscured() {
        camera.obscured = isWide
            ? EdgeInsets(top: safeArea.top, leading: safeArea.leading + 12 + layerSize.width / 2 + 8, bottom: safeArea.bottom, trailing: safeArea.trailing)
            : EdgeInsets(top: safeArea.top + topBarHeight + 8 + (focus == nil ? 0 : 160), leading: 0, bottom: safeArea.bottom + panelHeight + 16, trailing: 0)
    }

    private func openPhoto(_ photos: [TripPhoto], _ index: Int) {
        resumesAfterPhotos = player.isPlaying
        player.pause()
        viewingPhoto = TripPhotoViewerItem(photos: photos, start: index)
    }

    private func flyToFocus() {
        updateObscured()
        guard let coordinate = spotlight?.coordinate else { return }
        camera.fly(to: [coordinate], minimumMeters: 3_500, duration: reduceMotion ? 0.01 : 1.8)
    }

    /// Glides to what the scene is about: the whole trip, a day's route, a ride, or one place.
    private func flyToScene() {
        guard let scene = player.scene else { return }
        visualTimeline = TripTourVisualTimeline(scene: scene, document: document)
        updateObscured()
        if spotlight?.coordinate != nil {
            flyToFocus()
            return
        }
        let duration = reduceMotion ? 0.01 : 2.6
        switch scene.kind {
        case .intro, .outro, .unknown:
            let coordinates = document.places.map(\.coordinate) + document.days.flatMap { document.routeCoordinates(for: $0) }
            camera.fly(to: coordinates, minimumMeters: 50_000, duration: reduceMotion ? 0.01 : 3.2)
        case .day:
            guard let day = document.day(id: scene.dayId) else { return }
            camera.fly(to: document.focusCoordinates(for: day), minimumMeters: 25_000, duration: duration)
        case .travel:
            let segments = document.transport(id: scene.transportId)?.selectedOption?.segments ?? []
            let ends = segments.flatMap { [$0.fromPlaceId, $0.toPlaceId] }.compactMap { document.place(id: $0)?.coordinate }
            let fallback = document.day(id: scene.dayId).map { document.focusCoordinates(for: $0) } ?? []
            camera.fly(to: ends.isEmpty ? fallback : ends, minimumMeters: 15_000, duration: duration)
        case .place, .stay:
            let place = document.place(id: scene.placeId) ?? document.hotel(id: scene.hotelId).flatMap { document.place(id: $0.placeId) }
            guard let place else { return }
            camera.fly(to: [place.coordinate], minimumMeters: 3_500, duration: duration)
        }
    }
}

// MARK: - Map

/// The tour's map: days already toured in their colours, the current day's route drawing itself
/// with the traveler at its tip, later days faint, and the scene's place with its photo card.
private struct TripTourMap: View {
    let document: TripDocument
    let tour: TripTour?
    let index: Int
    let progress: Double
    let focus: TripTourFocus?
    let spotlight: TripTourSpotlight?
    @Bindable var camera: TripMapCamera
    let onOpenPhoto: ([TripPhoto], Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var routePaths: TripRoutePaths { .shared }
    private var orderedDays: [TripDay] { document.orderedDays }
    private var scene: TripTourScene? { tour.flatMap { $0.scenes.indices.contains(index) ? $0.scenes[index] : nil } }

    private var activeDayIndex: Int? {
        guard let dayID = scene?.dayId else { return nil }
        return orderedDays.firstIndex { $0.id == dayID }
    }

    /// How much of the day's route is drawn: it draws over the day's opening and its rides, then stays drawn.
    private var drawProgress: Double {
        guard let tour, let scene, let dayID = scene.dayId else { return 0 }
        let drawing = tour.scenes.indices.filter { tour.scenes[$0].dayId == dayID && [.day, .travel].contains(tour.scenes[$0].kind) }
        guard let position = drawing.firstIndex(of: index) else { return 1 }
        return (Double(position) + progress) / Double(max(1, drawing.count))
    }

    private func routePoints(for day: TripDay) -> [TripCoordinate] {
        document.routeRuns(for: day).reduce(into: []) { points, run in
            let path = routePaths.points(for: run)
            points += points.isEmpty ? path : Array(path.dropFirst())
        }
    }

    private func opacity(forDay dayIndex: Int) -> Double {
        switch scene?.kind {
        case .intro, nil: 0.35
        case .outro: 0.85
        default: dayIndex < (activeDayIndex ?? 0) ? 0.75 : 0.1
        }
    }

    private var activePlaceIDs: Set<String> {
        guard let day = document.day(id: scene?.dayId) else { return [] }
        return Set(document.placeIDs(for: day))
    }

    var body: some View {
        let active = activeDayIndex
        let spotlight = spotlight
        let activeIDs = activePlaceIDs
        Map(position: $camera.position, interactionModes: []) {
            ForEach(Array(orderedDays.enumerated()), id: \.element.id) { dayIndex, day in
                let points = routePoints(for: day)
                if points.count >= 2, dayIndex != active || scene?.kind == .outro {
                    MapPolyline(coordinates: points.map(\.clCoordinate))
                        .stroke(TripStyle.color(for: day.route?.kind).opacity(opacity(forDay: dayIndex)), style: TripStyle.stroke(for: day.route?.kind))
                        .mapOverlayLevel(level: .aboveRoads)
                }
            }
            if let active, scene?.kind != .outro {
                let day = orderedDays[active]
                let points = routePoints(for: day)
                if points.count >= 2, let sample = TripRouteGeometry(points: points).sample(progress: reduceMotion ? 1 : drawProgress) {
                    MapPolyline(coordinates: points.map(\.clCoordinate))
                        .stroke(TripStyle.color(for: day.route?.kind).opacity(0.18), style: TripStyle.stroke(for: day.route?.kind, width: 6))
                        .mapOverlayLevel(level: .aboveRoads)
                    if sample.path.count >= 2 {
                        // The growing line is re-added every frame; its own level keeps it above the
                        // translucent lines it overlaps, so their blended color doesn't flicker.
                        MapPolyline(coordinates: sample.path.map(\.clCoordinate))
                            .stroke(TripStyle.color(for: day.route?.kind), style: TripStyle.stroke(for: day.route?.kind, width: 7))
                            .mapOverlayLevel(level: .aboveLabels)
                    }
                    if drawProgress < 1 {
                        Annotation("", coordinate: sample.point.clCoordinate, anchor: .center) {
                            TravelerDot()
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            ForEach(document.places) { place in
                if place.id != spotlight?.id {
                    Annotation(place.name, coordinate: place.coordinate.clCoordinate, anchor: .center) {
                        PlaceDot(major: place.major, active: activeIDs.contains(place.id), visited: false)
                    }
                    .annotationTitles(place.major || activeIDs.contains(place.id) ? .visible : .hidden)
                }
            }
            if let spotlight, let focus, let coordinate = spotlight.coordinate {
                Annotation(spotlight.name, coordinate: coordinate.clCoordinate, anchor: .bottom) {
                    photoCard(spotlight, focus: focus)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .overlay(alignment: .topTrailing) {
            if let spotlight, let focus, spotlight.coordinate == nil, !spotlight.photos.isEmpty {
                photoCard(spotlight, focus: focus, anchored: false)
                    .padding(.top, max(12, camera.obscured.top - 160 + 12))
                    .padding(.trailing, 12)
            }
        }
        .animation(.spring(duration: 0.6, bounce: 0.25), value: spotlight?.id)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { camera.viewSize = $0 }
        .task(id: document.days.map(\.id)) {
            await routePaths.resolve(orderedDays.flatMap { document.routeRuns(for: $0) })
        }
    }

    private func photoCard(_ spotlight: TripTourSpotlight, focus: TripTourFocus, anchored: Bool = true) -> some View {
        TripTourPlaceCard(id: spotlight.id, name: spotlight.name, symbol: spotlight.symbol, photos: spotlight.photos, anchored: anchored, focus: focus, onOpenPhoto: onOpenPhoto)
            .id("\(spotlight.id):\(focus.imageGroupId ?? "")")
    }
}

// MARK: - Caption

/// The panel under the map: what kind of stop this is, its caption, the guide's stories as
/// subtitles that fill in as they're spoken, and the playback controls.
/// Minimized, it keeps only the line being spoken as a caption over the map.
private struct TripTourCaption: View {
    let document: TripDocument
    let scene: TripTourScene
    let index: Int
    let player: TripTourPlayer
    /// Beside the map, with the height to show more of the narration.
    let isWide: Bool
    @Binding var isMinimized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isMinimized ? 8 : 12) {
            HStack(spacing: 8) {
                Label(eyebrow, systemImage: eyebrowImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TripStyle.color(for: .out))
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                if player.isBuffering {
                    ProgressView().controlSize(.small)
                }
                Text("\(index + 1) / \(player.sceneCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    isMinimized.toggle()
                } label: {
                    Label(isMinimized ? "Show Details" : "Hide Details", systemImage: isMinimized ? "chevron.up" : "chevron.down")
                        .contentTransition(.symbolEffect(.replace))
                }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityIdentifier("trip-tour-minimize")
            }
            if isMinimized {
                caption
            } else {
                details
            }
            controls
        }
        .padding(isMinimized ? 14 : 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .animation(.easeInOut(duration: 0.5), value: index)
        .animation(.easeInOut(duration: 0.3), value: isMinimized ? currentSentence.position : 0)
    }

    /// Minimized: the line being spoken, like a film subtitle.
    private var caption: some View {
        let line = currentSentence
        return Text(line.text)
            .font(.callout.weight(.medium))
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .id("caption-\(index)-\(line.position)")
            .transition(.opacity)
    }

    /// The sentence of the narration at the spoken position.
    private var currentSentence: (text: String, position: Int) {
        let text = scene.narration
        var sentences: [(range: Range<String.Index>, text: String)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, range, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { sentences.append((range, sentence)) }
        }
        guard !sentences.isEmpty else { return (text, 0) }
        let spoken = text.index(text.startIndex, offsetBy: min(text.count, Int(Double(text.count) * player.sceneProgress)))
        let position = sentences.firstIndex { $0.range.upperBound > spoken } ?? sentences.count - 1
        return (sentences[position].text, position)
    }

    /// Expanded: the caption title and the full story as subtitles.
    @ViewBuilder private var details: some View {
        Text(scene.title)
            .font(.title2.weight(.bold))
            .fixedSize(horizontal: false, vertical: true)
            .id("title-\(index)")
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        ScrollView {
            subtitles
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: isWide ? 320 : 132)
        .scrollIndicators(.hidden)
    }

    /// The part already spoken is bright; the rest follows dimmed.
    private var subtitles: Text {
        let text = scene.narration
        var cut = text.index(text.startIndex, offsetBy: Int(Double(text.count) * player.sceneProgress), limitedBy: text.endIndex) ?? text.endIndex
        while cut < text.endIndex, !text[cut].isWhitespace { cut = text.index(after: cut) }
        let spoken = String(text[..<cut]), rest = String(text[cut...])
        return Text("\(Text(spoken).foregroundStyle(.primary))\(Text(rest).foregroundStyle(.secondary.opacity(0.7)))")
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Spacer(minLength: 0)
            Button(action: player.previous) {
                Label("Previous Stop", systemImage: "backward.fill")
            }
            .disabled(index == 0 && player.sceneProgress < 0.15)
            .accessibilityIdentifier("trip-tour-previous")
            Button(action: player.togglePlayback) {
                Label(player.isPlaying ? "Pause" : (player.phase == .finished ? "Play Again" : "Play"),
                      systemImage: player.isPlaying ? "pause.fill" : (player.phase == .finished ? "arrow.counterclockwise" : "play.fill"))
                    .font(.title2)
                    .frame(width: 34, height: 34)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityIdentifier("trip-tour-play")
            Button(action: player.next) {
                Label("Next Stop", systemImage: "forward.fill")
            }
            .disabled(index >= player.sceneCount - 1)
            .accessibilityIdentifier("trip-tour-next")
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .buttonStyle(.borderless)
    }

    private var eyebrow: String {
        switch scene.kind {
        case .intro: return String(localized: "Your trip")
        case .outro: return String(localized: "Journey's end")
        case .travel: return String(localized: "Getting there")
        case .place: return String(localized: "Sight")
        case .stay: return String(localized: "Explore the neighborhood")
        case .day, .unknown:
            guard let day = document.day(id: scene.dayId),
                  let number = document.orderedDays.firstIndex(where: { $0.id == day.id }) else { return String(localized: "Day") }
            return String(localized: "Day \(number + 1) · \(TripTourFacts.dayText(day.date, in: document))")
        }
    }

    private var eyebrowImage: String {
        switch scene.kind {
        case .intro: "map"
        case .outro: "flag.checkered"
        case .travel: document.transport(id: scene.transportId)?.selectedOption?.segments.first?.mode.systemImage ?? "tram.fill"
        case .place: "mappin.and.ellipse"
        case .stay: "bed.double.fill"
        case .day, .unknown: "calendar"
        }
    }
}

extension View {
    /// Play mode over the trip: full screen on iPhone and iPad, a large sheet on the Mac.
    func tripTourPresentation(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
