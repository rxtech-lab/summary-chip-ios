#if os(iOS) || os(macOS)
import Kingfisher
import SwiftUI

public extension EnvironmentValues {
    /// Loader used for OG images and source files. Inject an authorised one in the app and
    /// extensions so private summaries the user owns still render.
    @Entry var summaryAssetLoader: SummaryAssetLoader = .anonymous
}

/// A remote summary image loaded (and cached) through Kingfisher, filling its frame. Sends the
/// bearer token when `authorized`; shows `placeholder` until the image arrives or if it fails.
public struct SummaryRemoteImage<Placeholder: View>: View {
    let url: URL?
    let authorized: Bool
    let placeholder: Placeholder

    @Environment(\.summaryAssetLoader) private var loader

    public init(url: URL?, authorized: Bool = false, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.authorized = authorized
        self.placeholder = placeholder()
    }

    public var body: some View {
        if let url {
            KFImage(url)
                .requestModifier(loader.requestModifier(authorized: authorized))
                .redirectHandler(loader.redirectHandler)
                .backgroundDecode()
                .cancelOnDisappear(true)
                .placeholder { placeholder }
                .onFailureView { placeholder }
                .fade(duration: 0.2)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }
}

/// The 1200×630 OG image of a summary, with the MeshGradient theme card as fallback.
/// Sends the bearer token for owned summaries (private OG images need it).
public struct SummaryOGImage: View {
    public static let aspectRatio: CGFloat = 1200.0 / 630.0

    let url: URL?
    let authorized: Bool
    let theme: Theme
    let title: String
    let label: String?

    public init(summary: Summary) {
        self.url = summary.ogImageUrl
        self.authorized = summary.isOwner
        self.theme = summary.theme
        self.title = summary.title
        self.label = summary.sourceLabel
    }

    public init(url: URL?, theme: Theme = .fallback, title: String, label: String? = nil, authorized: Bool = false) {
        self.url = url
        self.authorized = authorized
        self.theme = theme
        self.title = title
        self.label = label
    }

    public var body: some View {
        Color.clear
            .aspectRatio(Self.aspectRatio, contentMode: .fit)
            .overlay {
                SummaryRemoteImage(url: url, authorized: authorized) {
                    ThemePlaceholderCard(theme: theme, title: title, label: label)
                }
            }
            .clipped()
            .accessibilityElement()
            .accessibilityLabel(Text("Preview image: \(title)", bundle: .module))
    }
}
#endif
