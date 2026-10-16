import SummaryKit
import SwiftUI

/// A Clip to open on its own: full screen on iPhone and iPad, in a separate window on macOS.
struct MiniAppLaunch: Identifiable, Hashable, Codable {
    let id: String
    let title: String
}

/// Opens a Clip outside the page's navigation stack. Installed per scene by `miniAppPresenter()`.
struct OpenMiniAppAction {
    let open: (MiniAppLaunch) -> Void
    func callAsFunction(_ summary: Summary) { open(MiniAppLaunch(id: summary.id, title: summary.title)) }
    func callAsFunction(id: String, title: String) { open(MiniAppLaunch(id: id, title: title)) }
}

extension EnvironmentValues {
    @Entry var openMiniApp: OpenMiniAppAction?
}

extension Binding where Value == [Summary] {
    /// A navigation path that hands Clips to `open` instead of pushing them.
    func presentingMiniApps(with open: OpenMiniAppAction?) -> Binding<[Summary]> {
        guard let open else { return self }
        return Binding {
            wrappedValue
        } set: { path in
            let clips = path.filter { $0.kind == .miniApp && !wrappedValue.contains($0) }
            wrappedValue = path.filter { $0.kind != .miniApp }
            clips.last.map { open($0) }
        }
    }
}

private struct MiniAppPresenter: ViewModifier {
    let environment: AppEnvironment
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var launch: MiniAppLaunch?
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.environment(\.openMiniApp, OpenMiniAppAction { openWindow(id: MiniAppWindow.id, value: $0) })
        #else
        content
            .environment(\.openMiniApp, OpenMiniAppAction { launch = $0 })
            .fullScreenCover(item: $launch) { launch in
                MiniAppScreen(environment: environment, launch: launch)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: launch) { _, new in new != nil }
        #endif
    }
}

extension View {
    /// Lets pages in this scene open Clips full screen (iOS) or in their own window (macOS).
    func miniAppPresenter(environment: AppEnvironment) -> some View {
        modifier(MiniAppPresenter(environment: environment))
    }
}

/// A Clip running on its own, with a Close button on iPhone and iPad.
struct MiniAppScreen: View {
    let environment: AppEnvironment
    let launch: MiniAppLaunch
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MiniAppDetailView(environment: environment, appID: launch.id, title: launch.title)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .accessibilityIdentifier("mini-app-close")
                    }
                }
                #endif
        }
        .environment(\.summaryAssetLoader, environment.assetLoader)
    }
}

#if os(macOS)
/// The window a Clip opens in on macOS; one per Clip.
struct MiniAppWindow: Scene {
    static let id = "mini-app"
    let environment: AppEnvironment

    var body: some Scene {
        WindowGroup("Clip", id: Self.id, for: MiniAppLaunch.self) { $launch in
            if let launch {
                MiniAppScreen(environment: environment, launch: launch)
                    .navigationTitle(launch.title)
                    .frame(minWidth: 380, minHeight: 520)
                    .tint(.indigo)
            }
        }
        .defaultSize(width: 520, height: 780)
        .windowToolbarStyle(.unified)
    }
}
#endif

/// Shown while a Clip loads: its name over an animated tile and a progress bar.
struct MiniAppLoadingView: View {
    let title: String
    let progress: Double
    let status: String
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            MiniAppLoadingTile()
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            VStack(spacing: 6) {
                Text(title.isEmpty ? String(localized: "Clip") : title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: status)
            }
            .offset(y: appeared ? 0 : 12)
            .opacity(appeared ? 1 : 0)
            MiniAppProgressBar(progress: progress)
                .frame(width: 200)
                .opacity(appeared ? 1 : 0)
                .accessibilityLabel("Loading progress")
                .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.summaryGroupedBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-app-loading")
        .onAppear { withAnimation(.spring(duration: 0.6, bounce: 0.35)) { appeared = true } }
    }
}

/// The Clip's app tile: a gradient that drifts around a breathing symbol, with an orbiting glow.
private struct MiniAppLoadingTile: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(time.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360)
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(AngularGradient(colors: [.teal, .cyan, .blue, .mint, .teal], center: .center, angle: angle))
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.linearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
                Image(systemName: "app.badge")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.breathe.pulse, options: .repeating)
            }
            .frame(width: 96, height: 96)
            .background {
                // Two soft rings ripple out from the tile, half a cycle apart.
                ForEach(0..<2, id: \.self) { index in
                    let phase = (time / 1.8 + Double(index) / 2).truncatingRemainder(dividingBy: 1)
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(.teal.opacity(0.45 * (1 - phase)), lineWidth: 2)
                        .scaleEffect(1 + 0.6 * phase)
                }
            }
            .scaleEffect(1 + 0.03 * sin(time * 2.4))
            .shadow(color: .teal.opacity(0.35), radius: 18, y: 8)
        }
        .accessibilityHidden(true)
    }
}

/// A capsule progress bar whose fill animates and carries a moving shimmer.
private struct MiniAppProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * min(1, max(0.04, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.linearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay {
                        TimelineView(.animation) { context in
                            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                            LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 60)
                                .offset(x: (width + 60) * phase - 60)
                        }
                        .clipShape(Capsule())
                    }
                    .animation(.smooth(duration: 0.45), value: progress)
            }
        }
        .frame(height: 6)
    }
}
