import SwiftUI

#if os(visionOS)
struct PlatformGlass {
    static let regular = Self()
    static let identity = Self()
    func tint(_ color: Color) -> Self { self }
    func interactive(_ enabled: Bool = true) -> Self { self }
}
#else
typealias PlatformGlass = Glass
#endif

extension View {
    @ViewBuilder
    func platformGlassEffect<S: Shape>(_ glass: PlatformGlass = .regular, in shape: S) -> some View {
        #if os(visionOS)
        background(.regularMaterial, in: shape)
        #else
        glassEffect(glass, in: shape)
        #endif
    }
}

struct PlatformGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content
    var body: some View {
        #if os(visionOS)
        content()
        #else
        GlassEffectContainer(spacing: spacing, content: content)
        #endif
    }
}

struct PlatformGlassButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        #if os(visionOS)
        if prominent { Button(configuration).buttonStyle(.borderedProminent) }
        else { Button(configuration).buttonStyle(.bordered) }
        #else
        if prominent { Button(configuration).buttonStyle(.glassProminent) }
        else { Button(configuration).buttonStyle(.glass) }
        #endif
    }
}
extension PrimitiveButtonStyle where Self == PlatformGlassButtonStyle {
    static var platformGlass: Self { Self() }
    static var platformGlassProminent: Self { Self(prominent: true) }
}
