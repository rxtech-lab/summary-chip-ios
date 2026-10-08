import SummaryKit
import SwiftUI

/// The toolbar's version switcher: the current version, the newest earlier ones (picking one shows
/// it in place, read-only), restoring the one shown, and the full history.
struct VersionToolbarMenu: View {
    @Bindable var model: DocumentVersionsModel

    var body: some View {
        Menu {
            // Toggles: menus check the one shown and give each its date and author as a subtitle.
            Section {
                if let current = model.current {
                    row(current, title: String(localized: "Current (\(current.label))"), number: nil)
                }
                ForEach(model.recentPast) { version in
                    row(version, title: version.label, number: version.version)
                }
            }
            if model.isPreviewing {
                Divider()
                Button { model.confirmsRestore = true } label: {
                    Label("Restore This Version…", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("version-restore")
                Button { Task { await model.show(nil) } } label: {
                    Label("Back to Current", systemImage: "arrow.uturn.forward")
                }
            }
            Divider()
            Button { model.showsHistory = true } label: {
                Label("All Versions…", systemImage: "list.bullet")
            }
            .accessibilityIdentifier("version-history")
        } label: {
            Label(model.preview?.info.label ?? String(localized: "Versions"),
                  systemImage: model.isPreviewing ? "clock.badge.fill" : "clock.arrow.circlepath")
        }
        .help(model.preview?.info.label ?? String(localized: "Versions"))
        .disabled(model.isBusy)
        .accessibilityIdentifier("version-menu")
    }

    /// `number` nil is the current version.
    private func row(_ version: DocumentVersion, title: String, number: Int?) -> some View {
        Toggle(isOn: Binding {
            model.preview?.info.version == number
        } set: { isOn in
            if isOn { Task { await model.show(number) } }
        }) {
            Text(title)
            Text(version.detail)
        }
        .accessibilityIdentifier("version-menu-\(version.version)")
    }
}

/// Says a past version is shown and offers to restore it or go back to the current one.
struct VersionPreviewBanner: View {
    let model: DocumentVersionsModel

    var body: some View {
        if let preview = model.preview {
            HStack(spacing: 12) {
                Image(systemName: "clock.badge")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.info.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(preview.info.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Current") { Task { await model.show(nil) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("version-banner-current")
                Button("Restore") { model.confirmsRestore = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("version-banner-restore")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Viewing \(preview.info.label)"))
            .accessibilityIdentifier("version-banner")
        }
    }
}

/// Every saved version, newest first; choosing one shows it in place.
struct VersionHistorySheet: View {
    let model: DocumentVersionsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        list
            .onAppear { model.isHistoryOpen = true }
            .onDisappear { model.isHistoryOpen = false }
    }

    private var list: some View {
        NavigationStack {
            List {
                ForEach(model.versions) { version in
                    Button {
                        Task {
                            await model.show(version.version)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: version.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.isCurrent ? String(localized: "\(version.label) (Current)") : version.label)
                                    .font(.body.weight(.semibold))
                                Text(version.title)
                                    .lineLimit(1)
                                Text(version.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if version.version == model.shownVersion {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Shown")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("version-row-\(version.version)")
                }
                if model.nextCursor != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .task { await model.loadMore() }
                }
            }
            .overlay {
                if model.versions.isEmpty {
                    ContentUnavailableView("No Versions Yet", systemImage: "clock",
                                           description: Text("Each edit saves a version you can come back to."))
                }
            }
            .navigationTitle("Versions")
            .summaryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if let number = model.loadingVersion {
                    ActionStatusOverlay(String(localized: "Opening version \(number)…"))
                }
            }
        }
        .summarySheetSize()
        .task { await model.reload() }
    }
}

extension View {
    /// The version history's sheet, restore confirmation, status overlays and feedback for a detail
    /// view. `onRestored` gets the item as restored. Without `presentsHistory` the view presents
    /// `VersionHistorySheet` itself when `showsHistory` turns on (the trip, from its diary sheet).
    func documentVersions(_ model: DocumentVersionsModel, presentsHistory: Bool = true, onRestored: @escaping (DocumentVersionRestore) -> Void) -> some View {
        modifier(DocumentVersionsModifier(model: model, presentsHistory: presentsHistory, onRestored: onRestored))
    }
}

private struct DocumentVersionsModifier: ViewModifier {
    @Bindable var model: DocumentVersionsModel
    let presentsHistory: Bool
    let onRestored: (DocumentVersionRestore) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: presentsHistory ? $model.showsHistory : .constant(false)) {
                VersionHistorySheet(model: model)
            }
            .confirmationDialog(restoreTitle, isPresented: $model.confirmsRestore, titleVisibility: .visible) {
                Button("Restore") {
                    Task { if let restored = await model.restorePreview() { onRestored(restored) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It becomes the newest version. The current one stays in the history, so you can switch back.")
            }
            .overlay {
                if model.isRestoring {
                    ActionStatusOverlay(String(localized: "Restoring…"))
                } else if let number = model.loadingVersion, !model.isHistoryOpen {
                    ActionStatusOverlay(String(localized: "Opening version \(number)…"))
                }
            }
            .statusAlert("Versions", message: model.errorMessage) { model.errorMessage = nil }
            .animation(.spring(duration: 0.3), value: model.preview?.info.version)
            .sensoryFeedback(.selection, trigger: model.switchCount)
            .sensoryFeedback(.success, trigger: model.restoredCount)
            .sensoryFeedback(.error, trigger: model.errorMessage) { _, new in new != nil }
            .sensoryFeedback(.impact(weight: .light), trigger: model.confirmsRestore) { _, new in new }
    }

    private var restoreTitle: String {
        model.preview.map { String(localized: "Restore \($0.info.label)?") } ?? String(localized: "Restore this version?")
    }
}
