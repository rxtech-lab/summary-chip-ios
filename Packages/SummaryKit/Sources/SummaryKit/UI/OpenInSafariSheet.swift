#if os(iOS) || os(macOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Shown when neither the server nor the device's web view could read a link. Safari usually
/// can (it has the user's cookies and app-free rendering), and sharing the open page to Chippy
/// sends its text straight from the page. A diagram walks through the three steps.
public struct OpenInSafariSheet: View {
    let page: UnreadablePageError
    /// Non-nil for pasted text with a link inside: summarise the text itself instead.
    let onSummariseText: (() -> Void)?
    let onCancel: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var openedSafari = false

    public init(page: UnreadablePageError, onSummariseText: (() -> Void)? = nil, onCancel: @escaping () -> Void) {
        self.page = page
        self.onSummariseText = onSummariseText
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This page needs Safari", systemImage: "safari")
                            .font(.title2.bold())
                        Text("Chippy couldn't read \(host) from the server or this device. Open it in Safari and share it to Chippy — the text is sent straight from the page.")
                            .foregroundStyle(.secondary)
                    }

                    ShareExtensionDiagram(host: host)

                    VStack(spacing: 12) {
                        Button {
                            openInSafari()
                        } label: {
                            Label("Open in Safari", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("open-in-safari")

                        if let onSummariseText {
                            Button {
                                onSummariseText()
                            } label: {
                                Text("Summarise the text instead").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("summarise-text-instead")
                        }
                        #if os(macOS)
                        // Sheet navigation stacks don't display toolbar placements on macOS.
                        Button("Cancel", role: .cancel) { onCancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .keyboardShortcut(.cancelAction)
                        #endif
                    }
                }
                .padding(24)
            }
            .navigationTitle("Open in Safari")
            .summaryInlineNavigationTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
            }
            #endif
        }
        .summarySheetSize()
        .sensoryFeedback(.selection, trigger: openedSafari)
    }

    private var host: String {
        page.url.host()?.replacingOccurrences(of: "www.", with: "") ?? page.url.absoluteString
    }

    private func openInSafari() {
        openedSafari.toggle()
        SafariOpener.open(page.url, fallback: openURL)
        onCancel()
    }
}

/// Opens a page in Safari on macOS; on iOS in the default browser (there's no supported way to
/// force Safari, and every browser's share sheet lists Chippy).
enum SafariOpener {
    @MainActor
    static func open(_ url: URL, fallback: OpenURLAction) {
        #if os(macOS)
        let workspace = NSWorkspace.shared
        if let safari = workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari") {
            workspace.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        #endif
        fallback(url)
    }
}

/// Three illustrated steps: open the page in Safari → Share → Chippy.
struct ShareExtensionDiagram: View {
    let host: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            step(1, title: "Open the page in Safari", detail: host) { SafariAddressBarArt(host: host) }
            connector
            step(2, title: "Share the page", detail: shareDetail) { ShareButtonArt() }
            connector
            step(3, title: "Choose Chippy", detail: "Chippy reads the open page and makes the summary.") { ShareSheetArt() }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var shareDetail: String {
        #if os(macOS)
        "Click the Share button in Safari's toolbar, or choose File › Share."
        #else
        "Tap the Share button (in the ⋯ menu if the toolbar is compact)."
        #endif
    }

    private func step(_ number: Int, title: String, detail: String, @ViewBuilder art: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 14) {
            art()
                .frame(width: 112, height: 72)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    private var connector: some View {
        Image(systemName: "arrow.down")
            .font(.caption.bold())
            .foregroundStyle(.tint)
            .frame(width: 112, height: 22)
    }
}

/// A browser window with the page's address.
private struct SafariAddressBarArt: View {
    let host: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "safari.fill").foregroundStyle(.blue)
                Text(host)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach([1.0, 0.8, 0.9], id: \.self) { width in
                    Capsule().fill(.quaternary).frame(height: 4).frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: width, anchor: .leading)
                }
            }
        }
        .padding(8)
    }
}

/// A toolbar with the Share button highlighted.
private struct ShareButtonArt: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left").foregroundStyle(.tertiary)
            Image(systemName: "square.and.arrow.up")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.tint, in: RoundedRectangle(cornerRadius: 8))
            Image(systemName: "book").foregroundStyle(.tertiary)
        }
    }
}

/// The share sheet's app row with Chippy highlighted.
private struct ShareSheetArt: View {
    var body: some View {
        HStack(spacing: 6) {
            appTile(color: .green, symbol: "message.fill")
            appTile(color: .blue, symbol: "envelope.fill")
            VStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.tint, lineWidth: 2).padding(-3))
                Text("Chippy").font(.system(size: 8, weight: .semibold))
            }
        }
    }

    private func appTile(color: Color, symbol: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            Text(" ").font(.system(size: 8))
        }
    }
}

#Preview {
    OpenInSafariSheet(
        page: UnreadablePageError(url: URL(string: "https://xhslink.cn/o/1RVs1hjAwxb")!, reason: "Timed out"),
        onSummariseText: {},
        onCancel: {}
    )
}
#endif
