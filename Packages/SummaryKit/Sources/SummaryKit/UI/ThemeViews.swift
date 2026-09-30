#if os(iOS)
import SwiftUI

public extension Color {
    /// `#rgb`, `#rrggbb` or `#aarrggbb`.
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 128, 128, 128)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

public extension Theme {
    var accentColor: Color { Color(hex: accent) }
    var foreground: Color { mode == .dark ? .white : .black }
}

/// The summary's palette as a 3×3 mesh gradient (the look of the original SharePreviewCard).
public struct ThemeBackground: View {
    let theme: Theme

    public init(theme: Theme) { self.theme = theme }

    public var body: some View {
        let palette = theme.colors.isEmpty ? Theme.fallback.colors : theme.colors
        let colors = (0..<9).map { Color(hex: palette[$0 % palette.count]) }
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: colors
        )
    }
}

/// Material-style geometry matching the server OG card: layered shapes with soft elevation
/// shadows, concentric rings, hairlines and a dot grid, anchored to the trailing edge.
public struct ThemeGeometry: View {
    let theme: Theme

    public init(theme: Theme) { self.theme = theme }

    public var body: some View {
        let palette = theme.colors.isEmpty ? Theme.fallback.colors : theme.colors
        let color = { (index: Int) in Color(hex: palette[index % palette.count]) }
        let ink = theme.foreground
        GeometryReader { proxy in
            let h = proxy.size.height
            let w = proxy.size.width
            let center = CGPoint(x: w - h * 0.42, y: h * 0.44)
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { ring in
                    Circle()
                        .stroke(ink.opacity(0.2 - Double(ring) * 0.04), lineWidth: 1)
                        .frame(width: h * (1.2 + CGFloat(ring) * 0.16), height: h * (1.2 + CGFloat(ring) * 0.16))
                        .position(center)
                }
                Canvas { context, _ in
                    for row in 0..<5 {
                        for column in 0..<5 {
                            let dot = CGRect(x: w - h * 1.05 + CGFloat(column) * 10, y: h * 0.1 + CGFloat(row) * 10, width: 2.5, height: 2.5)
                            context.fill(Path(ellipseIn: dot), with: .color(ink.opacity(0.28)))
                        }
                    }
                }
                Circle()
                    .fill(color(1))
                    .frame(width: h * 0.62, height: h * 0.62)
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
                    .position(center)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color(2))
                    .frame(width: h * 0.5, height: h * 0.32)
                    .rotationEffect(.degrees(-8))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 5)
                    .position(x: center.x - h * 0.22, y: center.y + h * 0.28)
                Circle()
                    .fill(color(3))
                    .frame(width: h * 0.5, height: h * 0.5)
                    .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                    .position(x: w, y: 0)
                Path { path in
                    for line in 0..<4 {
                        let x = center.x - h * 0.3 + CGFloat(line) * 9
                        path.move(to: CGPoint(x: x, y: h))
                        path.addLine(to: CGPoint(x: x + h * 0.5, y: h * 0.5))
                    }
                }
                .stroke(ink.opacity(0.3), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The theme's mesh gradient with its geometry on top — the OG card's art without any text.
public struct ThemeArtwork: View {
    let theme: Theme

    public init(theme: Theme) { self.theme = theme }

    public var body: some View {
        ZStack {
            ThemeBackground(theme: theme)
            ThemeGeometry(theme: theme)
        }
        .accessibilityHidden(true)
    }
}

/// Stand-in for the OG image while it loads or when it is unavailable.
public struct ThemePlaceholderCard: View {
    let theme: Theme
    let title: String
    let label: String?

    public init(theme: Theme, title: String, label: String? = nil) {
        self.theme = theme
        self.title = title
        self.label = label
    }

    private var scrim: Color { theme.mode == .dark ? .black : .white }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            ThemeArtwork(theme: theme)
            LinearGradient(
                colors: [scrim.opacity(theme.mode == .dark ? 0.55 : 0.7), scrim.opacity(0)],
                startPoint: .leading,
                endPoint: .trailing
            )
            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(theme.accentColor)
                    .frame(width: 22, height: 4)
                    .padding(.bottom, 2)
                Text(title)
                    .font(.headline.weight(.bold))
                    .lineLimit(3)
                    .foregroundStyle(theme.foreground)
                    .shadow(color: .black.opacity(theme.mode == .dark ? 0.3 : 0), radius: 4)
                if let label {
                    Text(label).font(.caption.weight(.semibold)).foregroundStyle(theme.foreground.opacity(0.8))
                }
            }
            .padding(16)
        }
    }
}

/// Small rounded label ("Technology", "#ai").
public struct ChipLabel: View {
    let text: String
    let systemImage: String?
    let tint: Color

    public init(_ text: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

public struct VisibilityBadge: View {
    let visibility: SummaryVisibility
    public init(_ visibility: SummaryVisibility) { self.visibility = visibility }
    public var body: some View {
        ChipLabel(visibility.title, systemImage: visibility.systemImage, tint: visibility == .public ? .green : .orange)
            .accessibilityLabel(visibility == .public ? "Public link" : "Private, link disabled")
    }
}

public struct ExpiryLabel: View {
    let expiresAt: Date?
    public init(_ expiresAt: Date?) { self.expiresAt = expiresAt }
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let text = TTLFormatter.countdown(until: expiresAt, now: context.date)
            let soon = TTLFormatter.isExpiringSoon(expiresAt, now: context.date)
            let expired = expiresAt.map { $0 <= context.date } ?? false
            Label(text, systemImage: expiresAt == nil ? "infinity" : "hourglass")
                .font(.caption)
                .foregroundStyle(expired ? .red : (soon ? .orange : .secondary))
        }
        // TimelineView is greedy; keep the label at its intrinsic size inside rows.
        .fixedSize()
    }
}

/// Wrapping horizontal layout for tags.
public struct FlowLayout: Layout {
    var spacing: CGFloat

    public init(spacing: CGFloat = 6) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
