import SummaryKit
import SwiftUI

struct PodcastChipPicker: View {
    let api: SummaryAPIClient
    let dayChips: [PodcastChip]?
    @Binding var selected: [String: PodcastChip]
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var source: SummaryOrigin?
    @State private var results: [PodcastChip] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var error: String?
    @State private var taps = 0
    private var query: SummaryListQuery { .init(q: search, source: source, kind: .summary, limit: 50) }
    private var visible: [PodcastChip] {
        guard let dayChips else { return results }
        return dayChips.filter { (source == nil || $0.source == source) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationStack {
            chipList
            .overlay {
                if loading { ProgressView("Loading chips…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
            }
            .animation(.snappy, value: selected.count)
            .navigationTitle("Choose Chips")
            .summaryInlineNavigationTitle()
            .searchable(text: $search, prompt: "Search chips")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? String(localized: "Done") : String(localized: "Done (\(selected.count))")) { dismiss() }
                        .accessibilityIdentifier("podcast-chip-picker-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Source", selection: $source) {
                            Label("All Sources", systemImage: "square.stack").tag(SummaryOrigin?.none)
                            ForEach(SummaryOrigin.known) { origin in
                                Label { Text(origin.title) } icon: { origin.image }.tag(Optional(origin))
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        if dayChips != nil {
                            Button("Select All", systemImage: "checkmark.circle") {
                                for chip in visible { selected[chip.id] = chip }; taps += 1
                            }
                            .disabled(visible.isEmpty)
                        }
                        Button("Clear Selection", systemImage: "xmark.circle", role: .destructive) { selected.removeAll(); taps += 1 }
                            .disabled(selected.isEmpty)
                    } label: {
                        Label("Filter", systemImage: source == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("podcast-source-filter")
                }
            }
            .onChange(of: source) { taps += 1 }
            .task(id: query) {
                guard dayChips == nil else { return }
                do { try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation() }
                catch { return }
                await load(more: false)
            }
            .alert("Couldn't Load Chips", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sensoryFeedback(.selection, trigger: taps)
        }
        .summarySheetFrame(minWidth: 320, idealWidth: 520, minHeight: 480)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationDetents([.large])
    }
    private var chipList: some View {
        List {
            Section {
                if visible.isEmpty && !loading {
                    ContentUnavailableView {
                        Label(search.isEmpty ? "No Chips" : "No Results", systemImage: search.isEmpty ? "square.stack" : "magnifyingglass")
                    } description: {
                        Text(source == nil ? "Try a different search." : "Try another source or search.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(visible) { chip in
                    PodcastChipRow(chip: chip, isSelected: selected[chip.id] != nil) {
                        if selected[chip.id] != nil { selected.removeValue(forKey: chip.id) }
                        else { selected[chip.id] = chip }
                        taps += 1
                    }
                }
                if cursor != nil {
                    Button { Task { await load(more: true) } } label: {
                        Label("Load More", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                    }
                    .disabled(loading)
                }
            } header: {
                HStack {
                    Text(source.map(\.title) ?? String(localized: "All Sources"))
                    Spacer()
                    if !selected.isEmpty {
                        Text("\(selected.count) selected")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                            .textCase(nil)
                    }
                }
            }
        }
    }

    private func load(more: Bool) async {
        var request = query
        if more { request.cursor = cursor }
        loading = true
        defer { loading = false }
        do {
            let page = try await api.listSummaries(request)
            try Task.checkCancellation()
            guard query.q == request.q, query.source == request.source else { return }
            let chips = page.items.filter { !$0.isExpired || $0.isOwner }.map { PodcastChip(id: $0.id, title: $0.title, source: $0.source) }
            results = more ? results + chips : chips
            cursor = page.nextCursor
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            guard !Task.isCancelled, query.q == request.q, query.source == request.source else { return }
            self.error = error.localizedDescription
        }
    }
}

private struct PodcastChipRow: View {
    let chip: PodcastChip
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                chip.source.image
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isSelected ? Color.white : .secondary)
                    .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(chip.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(chip.source.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
