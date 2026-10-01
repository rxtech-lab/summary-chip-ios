import SwiftUI

public extension Color {
    static var summaryGroupedBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    static var summaryCardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

public extension ToolbarItemPlacement {
    static var summaryTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    static var summaryLeading: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }
}

public extension View {
    @ViewBuilder
    func summaryInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder
    func summaryInputCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func summaryHideTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// Give desktop sheets enough room for forms, navigation, and summary previews.
    @ViewBuilder
    func summarySheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 560, idealWidth: 640, minHeight: 540, idealHeight: 640)
        #else
        self
        #endif
    }
}
