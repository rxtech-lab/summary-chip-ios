import SummaryKit
import SwiftUI
import SceneKit

struct LiveVoiceControls: View {
    var responseHeight: CGFloat = 160
    var contentHeight: CGFloat = 600
    let voice: LiveVoiceModel
    let currentTool: ChatToolActivity?
    let openTool: (ChatToolActivity) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var globe = VoiceGlobeScene()
    @State private var responseContentHeight: CGFloat = 56
    @State private var responseScroll = ScrollPosition(y: 0)
    @State private var responseOffset: CGFloat = 0
    @State private var userScrolledResponse = false

    private var hasToolUI: Bool {
        currentTool?.renderedUI != nil || currentTool?.miniAppDraft != nil
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                if hasToolUI {
                    toolPanel
                        .frame(height: max(44, stageHeight - responseHeight - 18))
                        .transition(.opacity)
                }
                responseBubble
                    .frame(maxHeight: .infinity, alignment: hasToolUI ? .top : .bottom)
            }
            .frame(height: stageHeight)

            TransparentVoiceGlobeView(scene: globe.scene, camera: globe.camera)
                .frame(width: 144, height: 144)
                .allowsHitTesting(false)
                .shadow(color: .cyan.opacity(0.22), radius: 6 + voice.level * 8)
                .scaleEffect(reduceMotion ? 1 : 1 + voice.level * 0.12)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: voice.level)
                // Peak speech rings reach 109 points from the center, including
                // their stroke. Give the Canvas a 224-point drawing area.
                .padding(40)
                .background {
                    AgentVoiceWaves(level: voice.level, isSpeaking: voice.isSpeaking, reduceMotion: reduceMotion)
                }
                .accessibilityHidden(true)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottomTrailing) {
                    if let currentTool {
                        Button {
                            if currentTool.renderedUI == nil { openTool(currentTool) }
                        } label: {
                            HStack(spacing: 8) {
                                if currentTool.isRunning {
                                    VoiceActivitySpinner(reduceMotion: reduceMotion)
                                } else {
                                    Image(systemName: currentTool.errorText == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(currentTool.errorText == nil ? Color.green : Color.orange)
                                        .frame(width: 18, height: 18)
                                }
                                Text(currentTool.label)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(minHeight: 20)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.cyan.opacity(0.3), lineWidth: 1))
                            .shadow(color: .cyan.opacity(0.2), radius: 10)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("voice-current-tool")
                        .accessibilityValue(currentTool.isRunning ? "Running" : (currentTool.errorText == nil ? "Completed" : "Failed"))
                        .offset(y: -6)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentTool?.id)
                .sensoryFeedback(trigger: currentTool?.finished) { _, finished in
                    guard finished == true else { return nil }
                    return currentTool?.errorText == nil ? .success : .error
                }
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    if voice.isConnecting { VoiceActivitySpinner(reduceMotion: reduceMotion) }
                    Text(voice.isConnecting ? "Connecting…" : "Connected")
                        .font(.headline)
                }
                Text(voice.isConnecting ? "Preparing your voice session" :
                     (voice.microphoneWarning ?? (voice.providerHeardSpeech ? connectedStatus : (voice.hasMicrophoneInput && voice.sentAudioSeconds > 0 ? "Sending microphone audio…" : "Speak to check your microphone…"))))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
            .frame(height: 70)
            .accessibilityElement(children: .combine)
            HStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(voice.startedAt ?? context.date))
                    Text(String(format: "%02d:%02d", max(0, seconds) / 60, max(0, seconds) % 60))
                        .monospacedDigit().font(.callout)
                        .accessibilityLabel("Voice session duration")
                }
                .frame(width: 62)
                VoiceInputWaveform(level: voice.inputLevel, isConnecting: voice.isConnecting)
                Button(role: .destructive) { voice.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                .accessibilityLabel("Stop voice chat")
                .accessibilityIdentifier("chat-voice-stop")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: hasToolUI)
        .onAppear { updateRotation() }
        .onChange(of: voice.isConnecting) { _, _ in updateRotation() }
        .onChange(of: reduceMotion) { _, _ in updateRotation() }
        .sensoryFeedback(.success, trigger: voice.isConnecting) { old, new in old && !new && voice.isActive }
        .padding(24)
        .frame(maxWidth: .infinity)

    }
    // The stage uses the available height; tool results never add height to the sheet.
    private var stageHeight: CGFloat { max(responseHeight, contentHeight - 456) }

    private var toolPanel: some View {
    Group {
        if let tool = currentTool, let ui = tool.renderedUI {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label(ui.title, systemImage: "rectangle.3.group")
                        .font(.subheadline.weight(.semibold))
                    TripViewRenderer(spec: ui.spec, currency: ui.currency)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("voice-generated-ui")
        } else if let tool = currentTool, let draft = tool.miniAppDraft {
            Button { openTool(tool) } label: {
                Label("Preview \(draft.title)", systemImage: "app.badge")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
        } else {
            Color.clear
        }
    }
        .frame(maxWidth: .infinity)
        .clipped()
    }

    private var responseBubble: some View {
        Group {
            ScrollView {
                VStack(spacing: 16) {
                    Text(voice.latestResponse.isEmpty ? "Listening…" : voice.latestResponse)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("voice-latest-response")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    responseContentHeight = height
                }
            }
            .defaultScrollAnchor(.top)
            .scrollPosition($responseScroll)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { userScrolledResponse = true }
            }
            .onChange(of: voice.latestResponse) { old, new in
                guard old.isEmpty || !new.hasPrefix(old) else { return }
                responseOffset = 0
                userScrolledResponse = false
                responseScroll.scrollTo(y: 0)
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard voice.isSpeaking, !userScrolledResponse else { continue }
                    // Follow audible playback, never the arrival rate of transcript deltas.
                    let viewport = min(responseHeight, max(44, responseContentHeight))
                    let limit = max(0, responseContentHeight - viewport)
                    responseOffset = min(limit, responseOffset + 2)
                    withAnimation(reduceMotion ? nil : .linear(duration: 0.1)) {
                        responseScroll.scrollTo(y: responseOffset)
                    }
                }
            }
            .frame(height: min(responseHeight, max(44, responseContentHeight)))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .platformGlassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        // The glass hugs short content while the reserved space keeps the globe stable.
        .frame(height: responseHeight, alignment: .bottom)
    }

    private var connectedStatus: String {
        #if os(macOS)
        "Speak after Chippy finishes; microphone pauses during replies."
        #else
        "Speech received by Chippy"
        #endif
    }

    private func updateRotation() {
        globe.setConnecting(voice.isConnecting, reduceMotion: reduceMotion)
    }
}

/// A high-contrast indicator with an explicit size so narrow bubbles cannot hide it.
private struct VoiceActivitySpinner: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            // Draw the phase directly: surrounding bubble animations must not
            // interpolate each frame's rotation and continually restart it.
            Canvas { graphics, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = max(0, min(size.width, size.height) / 2 - 1.5)
                let bounds = CGRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)
                graphics.stroke(Path(ellipseIn: bounds), with: .color(.cyan.opacity(0.2)), lineWidth: 2.5)
                let phase = reduceMotion ? -90 : context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
                var arc = Path()
                arc.addArc(center: center, radius: radius, startAngle: .degrees(phase),
                           endAngle: .degrees(phase + 260), clockwise: false)
                graphics.stroke(arc, with: .color(.cyan),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(width: 18, height: 18)
        }
        // Keep the parent's floating transform shared by the icon and label.
        // Canvas draws rotation directly and needs no animation override.
        .frame(width: 18, height: 18)
        .accessibilityLabel("Loading")
    }
}

/// A translucent holographic lattice with independently animated surface bands.
@MainActor
private final class VoiceGlobeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let orb = SCNNode()
    private var surfaceBands: [SCNNode] = []
    private let scanner = SCNNode()
    private var motionEnabled: Bool?


    init() {
        scene.background.contents = PlatformGlobeColor.clear
        if let url = Bundle.main.url(forResource: "ChippySciFiGlobe", withExtension: "usdz"),
           let asset = try? SCNScene(url: url) {
            let root = asset.rootNode.clone()
            let (minimum, maximum) = root.boundingBox
            let extent = max(maximum.x - minimum.x, max(maximum.y - minimum.y, maximum.z - minimum.z))
            if extent > 0 {
                let scale = 2 / extent
                root.scale = SCNVector3(scale, scale, scale)
                root.position = SCNVector3(-(minimum.x + maximum.x) * scale / 2,
                                          -(minimum.y + maximum.y) * scale / 2,
                                          -(minimum.z + maximum.z) * scale / 2)
            }
            orb.addChildNode(root)
        } else {
            buildHologram()
        }
        let tilt = SCNNode()
        tilt.eulerAngles.z = 0.15
        tilt.addChildNode(orb)
        scene.rootNode.addChildNode(tilt)
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 38
        camera.position = SCNVector3(0, 0, 3.6)
        scene.rootNode.addChildNode(camera)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 600
        key.position = SCNVector3(-3, 4, 4)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 220
        scene.rootNode.addChildNode(fill)
    }

    func setConnecting(_ connecting: Bool, reduceMotion: Bool) {
        setSurfaceMotion(enabled: !reduceMotion)

        let angle = orb.presentation.eulerAngles.y
        orb.removeAllActions()
        orb.eulerAngles.y = angle
        if reduceMotion {
            orb.eulerAngles.y = 0
        } else if connecting {
            orb.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 5)), forKey: "spin")
        } else {
            // Finish the current revolution forward, easing into the front view.
            let turn = Double.pi * 2
            let remainder = (Double(angle).truncatingRemainder(dividingBy: turn) + turn)
                .truncatingRemainder(dividingBy: turn)
            let action = SCNAction.rotateBy(x: 0, y: CGFloat(remainder < 0.001 ? 0 : turn - remainder), z: 0, duration: 0.8)
            action.timingMode = .easeOut
            orb.runAction(action, forKey: "settle")
        }
    }

    private func hologramMaterial(alpha: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = PlatformGlobeColor(red: 0.06, green: 0.72, blue: 0.9, alpha: alpha)
        material.isDoubleSided = true
        material.blendMode = .add
        material.writesToDepthBuffer = false
        return material
    }

    private func ring(radius: CGFloat, thickness: CGFloat, alpha: CGFloat) -> SCNNode {
        let geometry = SCNTorus(ringRadius: radius, pipeRadius: thickness)
        geometry.ringSegmentCount = 96
        geometry.pipeSegmentCount = 6
        geometry.firstMaterial = hologramMaterial(alpha: alpha)
        return SCNNode(geometry: geometry)
    }

    private func buildHologram() {
        // Horizontal light bands describe a hollow sphere; no opaque shell.
        for index in 0..<19 {
            let latitude = -Double.pi * 0.44 + Double(index) * Double.pi * 0.88 / 18
            let band = ring(radius: 0.91 * cos(latitude), thickness: 0.0035, alpha: 0.45)
            band.position.y = SCNFloat(0.91 * sin(latitude))
            orb.addChildNode(band)
            surfaceBands.append(band)
        }
        for index in 0..<8 {
            let meridian = ring(radius: 0.91, thickness: 0.002, alpha: 0.18)
            meridian.eulerAngles = SCNVector3(Double.pi / 2, Double(index) * Double.pi / 8, 0)
            orb.addChildNode(meridian)
        }
        // A sparse inner constellation adds depth through the transparent surface.
        for index in 0..<42 {
            let y = 1 - 2 * (Double(index) + 0.5) / 42
            let angle = Double(index) * 2.399963
            let radius = sqrt(1 - y * y) * 0.73
            let dot = SCNSphere(radius: 0.009)
            dot.segmentCount = 6
            dot.firstMaterial = hologramMaterial(alpha: 0.5)
            let node = SCNNode(geometry: dot)
            node.position = SCNVector3(radius * cos(angle), y * 0.73, radius * sin(angle))
            orb.addChildNode(node)
        }
        scanner.geometry = ring(radius: 0.94, thickness: 0.009, alpha: 0.65).geometry
        scanner.opacity = 0
        orb.addChildNode(scanner)
    }

    private func setSurfaceMotion(enabled: Bool) {
        guard motionEnabled != enabled else { return }
        motionEnabled = enabled
        for (index, band) in surfaceBands.enumerated() {
            band.removeAllActions()
            band.scale = SCNVector3(1, 1, 1)
            band.opacity = 0.75
            guard enabled else { continue }
            // Staggered radial expansion makes a wave travel over the sphere itself.
            let expand = SCNAction.group([
                .scale(to: 1.035, duration: 1.1), .fadeOpacity(to: 1, duration: 1.1)
            ])
            let contract = SCNAction.group([
                .scale(to: 0.975, duration: 1.4), .fadeOpacity(to: 0.45, duration: 1.4)
            ])
            expand.timingMode = .easeInEaseOut
            contract.timingMode = .easeInEaseOut
            band.runAction(.sequence([
                .wait(duration: Double(index) * 0.09),
                .repeatForever(.sequence([expand, contract]))
            ]), forKey: "surfacePulse")
        }
        scanner.removeAllActions()
        scanner.position = SCNVector3(0, -0.82, 0)
        scanner.scale = SCNVector3(0.45, 0.45, 0.45)
        scanner.opacity = 0
        guard enabled else { return }
        let rise = SCNAction.group([
            .move(to: SCNVector3(0, 0, 0), duration: 1.5),
            .scale(to: 1, duration: 1.5),
            .fadeOpacity(to: 0.75, duration: 0.5)
        ])
        let finish = SCNAction.group([
            .move(to: SCNVector3(0, 0.82, 0), duration: 1.5),
            .scale(to: 0.45, duration: 1.5),
            .sequence([.wait(duration: 1), .fadeOut(duration: 0.5)])
        ])
        let reset = SCNAction.group([
            .move(to: SCNVector3(0, -0.82, 0), duration: 0),
            .scale(to: 0.45, duration: 0)
        ])
        scanner.runAction(.repeatForever(.sequence([rise, finish, reset, .wait(duration: 0.8)])),
                        forKey: "scan")
    }

}

#if os(macOS)
private typealias PlatformGlobeColor = NSColor
#else
private typealias PlatformGlobeColor = UIColor
#endif

/// SceneView's host can remain opaque even when the scene itself is clear.
/// Configure the native renderer explicitly on both platforms.
private struct TransparentVoiceGlobeView {
    let scene: SCNScene
    let camera: SCNNode

    func makeGlobeView() -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        #if os(iOS) || os(visionOS)
        view.isOpaque = false
        #endif
        view.scene = scene
        view.pointOfView = camera
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling4X
        view.isPlaying = true
        return view
    }
}

#if os(macOS)
extension TransparentVoiceGlobeView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView { makeGlobeView() }
    func updateNSView(_ view: SCNView, context: Context) {}
}
#else
extension TransparentVoiceGlobeView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView { makeGlobeView() }
    func updateUIView(_ view: SCNView, context: Context) {}
}
#endif

/// Uses the agent playback level, independently of the microphone meter below.
struct AgentVoiceWaves: View {
    let level: Double
    let isSpeaking: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !isSpeaking)) { context in
            Canvas { graphics, size in
                guard isSpeaking else { return }
                let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let amplitude = min(1, max(0, level))
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                for ring in 0..<3 {
                    var path = Path()
                    for step in 0...180 {
                        let angle = Double(step) / 180 * .pi * 2
                        let wave = reduceMotion ? 0 : sin(angle * 10 + time * 5 - Double(ring))
                        let radius = 77 + Double(ring) * 7 + amplitude * 8 + wave * (0.6 + amplitude * 9)
                        let point = CGPoint(x: center.x + cos(angle) * radius,
                                            y: center.y + sin(angle) * radius)
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    graphics.stroke(path, with: .color(.cyan.opacity(
                        (0.35 + amplitude * 0.55) * (1 - Double(ring) * 0.23)
                    )), lineWidth: ring == 0 ? 2 : 1.3)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shared microphone visualization for Mac and spatial voice controls.
struct VoiceInputWaveform: View {
    let level: Double
    var isConnecting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<25) { index in
                Capsule().fill(.cyan.gradient)
                    .frame(width: 3, height: 3 + min(1, max(0, level)) * (12 + 20 * abs(sin(Double(index) * 0.8))))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityLabel(isConnecting ? "Connecting" : "Microphone input level")
    }
}
