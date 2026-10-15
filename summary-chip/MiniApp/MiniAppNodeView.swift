import MapKit
import SummaryKit
import SwiftUI

/// Stateful native controls share the existing renderer's visual catalog.
struct MiniAppNodeView: View {
    @Bindable var model: MiniAppRuntime
    let id: String
    var item: JSONValue = .null
    var depth = 0
    var expandedRepeat = false
    @State private var confirmsAction = false
    @State private var selectedTab: String?
    @Environment(\.miniGridCell) private var inGridCell

    var body: some View {
        if depth < 24, let node = model.document.ui.elements[id], node.visible == nil || model.value(node.visible, item: item).miniTruth {
            if let items = node.repeat?["items"], !expandedRepeat {
                let rows = model.value(items, item: item).miniArray
                ForEach(Array(rows.prefix(100).enumerated()), id: \.offset) { _, value in
                    AnyView(MiniAppNodeView(model: model, id: id, item: value, depth: depth + 1, expandedRepeat: true))
                }
            } else {
                content(node)
                    .modifier(MiniIdentityModifier(id: node.children.isEmpty ? "mini-node-\(id)" : nil))
                    .task(id: model.app?.revision ?? 0) { if let action = node.events["load"] { await model.run(action, item: item) } }
            }
        }
    }

    @ViewBuilder private func content(_ node: MiniAppNode) -> some View {
        switch node.type {
        case "Navigation": navigation(node)
        case "Tabs": tabs(node)
        case "Tab": scrollContent(node).modifier(MiniRefreshModifier(model: model, action: node.events["refresh"], item: item))
        case "Sheet", "Dialog", "Alert", "Confirmation": scrollContent(node)
        case "Toolbar": EmptyView()
        case "Stack":
            if string(node, "direction") == "horizontal" { HStack(alignment: .top, spacing: 12) { children(node) } }
            else { VStack(alignment: .leading, spacing: 12) { children(node) } }
        case "Grid": LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: min(4, max(1, props(node)["columns"]?.intValue ?? 2)))) { children(node).environment(\.miniGridCell, true) }
        // In a Grid, cards fill the row so neighbours share the tallest card's height.
        case "Card": VStack(alignment: .leading, spacing: 12) { if !string(node, "title").isEmpty { Text(string(node, "title")).font(.headline) }; children(node) }.padding()
            .frame(maxWidth: inGridCell ? .infinity : nil, maxHeight: inGridCell ? .infinity : nil, alignment: .topLeading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        case "Disclosure": DisclosureGroup(string(node, "title")) { children(node) }
        case "Form": Form { children(node) }.formStyle(.grouped)
        case "Section": Section(string(node, "title")) { children(node) }
        case "Menu": Menu { children(node) } label: { Label(string(node, "title"), systemImage: string(node, "icon", fallback: "ellipsis.circle")) }
        case "Button": button(node)
        case "TextField": textField(node)
        case "TextEditor": TextEditor(text: textBinding(node)).frame(minHeight: 120).accessibilityLabel(string(node, "title"))
        case "Toggle": Toggle(string(node, "title"), isOn: boolBinding(node))
        case "Picker": picker(node)
        case "DatePicker": DatePicker(string(node, "title"), selection: dateBinding(node), displayedComponents: [.date])
        case "FilePicker": MiniFilePicker(model: model, node: node, item: item, title: string(node, "title", fallback: String(localized: "Add File")), icon: string(node, "icon", fallback: "paperclip"))
        case "Location": MiniLocationButton(model: model, node: node, item: item, title: string(node, "title", fallback: String(localized: "Use Current Location")), icon: string(node, "icon", fallback: "location.fill"))
        case "Map": MiniMapView(model: model, node: node, props: props(node), item: item)
        case "Progress": ProgressView(string(node, "title", fallback: "Loading…"))
        case "Empty": ContentUnavailableView(string(node, "title"), systemImage: string(node, "icon", fallback: "tray"), description: Text(string(node, "message"))).frame(maxWidth: .infinity)
        default:
            NativeJSONViewRenderer(spec: TripViewSpec(root: id, elements: [id: TripViewElement(type: node.type, props: props(node))]), currency: string(node, "currency", fallback: "USD"))
        }
    }

    /// A sole Form or Tabs child fills the screen itself instead of scrolling inside a stack.
    @ViewBuilder private func scrollContent(_ node: MiniAppNode) -> some View {
        let content = node.children.filter { model.document.ui.elements[$0]?.type != "Toolbar" }
        let shown = content.filter { id in
            guard let child = model.document.ui.elements[id] else { return false }
            return child.visible == nil || model.value(child.visible, item: item).miniTruth
        }
        if content.count == 1, ["Form", "Tabs"].contains(model.document.ui.elements[content[0]]?.type ?? "") {
            children(node)
        } else if shown.count == 1, model.document.ui.elements[shown[0]]?.type == "Empty" {
            // An empty state on its own fills the screen; the scroll view keeps pull to refresh.
            ScrollView { AnyView(MiniAppNodeView(model: model, id: shown[0], item: item, depth: depth + 1)).containerRelativeFrame([.horizontal, .vertical]) }
        } else {
            ScrollView { VStack(alignment: .leading, spacing: 12) { children(node) }.frame(maxWidth: .infinity, alignment: .leading).padding() }
        }
    }
    private func navigation(_ node: MiniAppNode) -> some View {
        scrollContent(node)
            .navigationTitle(string(node, "title", fallback: model.document.title))
            .modifier(MiniRefreshModifier(model: model, action: node.events["refresh"], item: item))
            .modifier(MiniSearchModifier(model: model, node: node, item: item))
            .toolbar { toolbarItems(node.children) }
    }
    /// A native tab bar of `Tab` children. The shared search field and the toolbar (the Tabs' own
    /// Toolbar children plus the selected tab's) attach to the tab view, so they reach the navigation bar.
    private func tabs(_ node: MiniAppNode) -> some View {
        let ids = node.children.filter { id in
            guard let tab = model.document.ui.elements[id], tab.type == "Tab" else { return false }
            return tab.visible == nil || model.value(tab.visible, item: item).miniTruth
        }
        let selection = tabSelection(node, ids: ids)
        return tabBar(ids: ids, selection: selection)
        .modifier(MiniSearchModifier(model: model, node: node, item: item))
        .toolbar { toolbarItems(node.children + (model.document.ui.elements[selection.wrappedValue]?.children ?? [])) }
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
    #if os(macOS)
    /// macOS puts the tabs in the navigation bar as a segmented control above the selected tab.
    private func tabBar(ids: [String], selection: Binding<String>) -> some View {
        AnyView(MiniAppNodeView(model: model, id: selection.wrappedValue, item: item, depth: depth + 1))
            .id(selection.wrappedValue)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Tabs", selection: selection) {
                        ForEach(ids, id: \.self) { id in
                            let tab = model.document.ui.elements[id] ?? MiniAppNode(type: "Tab")
                            Label(string(tab, "title", fallback: id), systemImage: string(tab, "icon", fallback: "square.grid.2x2")).tag(id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
                    .accessibilityIdentifier("mini-tabs")
                }
            }
    }
    #else
    private func tabBar(ids: [String], selection: Binding<String>) -> some View {
        TabView(selection: selection) {
            ForEach(ids, id: \.self) { id in
                let tab = model.document.ui.elements[id] ?? MiniAppNode(type: "Tab")
                let badge = string(tab, "badge")
                Tab(string(tab, "title", fallback: id), systemImage: string(tab, "icon", fallback: "square.grid.2x2"), value: id) {
                    AnyView(MiniAppNodeView(model: model, id: id, item: item, depth: depth + 1))
                }
                .badge(badge.isEmpty || badge == "0" ? nil : Text(badge))
            }
        }
    }
    #endif
    /// The selected tab lives at the Tabs' `binding` when it has one; switching fires `change`.
    private func tabSelection(_ node: MiniAppNode, ids: [String]) -> Binding<String> {
        let path = node.props["binding"]?.stringValue
        return Binding(get: {
            let current = path.map { model.binding($0).wrappedValue.miniText } ?? selectedTab ?? ""
            return ids.contains(current) ? current : ids.first ?? ""
        }, set: { value in
            if let path { model.binding(path).wrappedValue = .string(value) } else { selectedTab = value }
            model.event(node, "change", item: item)
        })
    }
    /// Each visible Toolbar child becomes a native toolbar group at its `placement`.
    @ToolbarContentBuilder private func toolbarItems(_ ids: [String]) -> some ToolbarContent {
        let toolbars = ids.filter { id in
            guard let toolbar = model.document.ui.elements[id], toolbar.type == "Toolbar" else { return false }
            return toolbar.visible == nil || model.value(toolbar.visible, item: item).miniTruth
        }
        ForEach(toolbars, id: \.self) { id in
            ToolbarItemGroup(placement: placement(model.document.ui.elements[id]?.props["placement"]?.stringValue)) {
                if let toolbar = model.document.ui.elements[id] { children(toolbar) }
            }
        }
    }
    private func placement(_ name: String?) -> ToolbarItemPlacement {
        switch name {
        case "leading": return .navigation
        case "secondary": return .secondaryAction
        case "bottom":
            #if os(iOS)
            return .bottomBar
            #else
            return .automatic
            #endif
        default: return .primaryAction
        }
    }
    private func button(_ node: MiniAppNode) -> some View {
        Button {
            if string(node, "role") == "destructive" { confirmsAction = true }
            else { model.event(node, "press", item: item) }
        } label: { Label(string(node, "title", fallback: "Continue"), systemImage: string(node, "icon", fallback: "arrow.right")) }
            .disabled(props(node)["disabled"]?.miniTruth == true)
            .confirmationDialog(string(node, "title"), isPresented: $confirmsAction, titleVisibility: .visible) {
                Button(string(node, "title"), role: .destructive) { model.event(node, "press", item: item) }
                Button("Cancel", role: .cancel) {}
            }
    }
    private func textField(_ node: MiniAppNode) -> some View {
        TextField(string(node, "title"), text: textBinding(node))
            .textFieldStyle(.roundedBorder)
            .onSubmit { model.event(node, "submit", item: item) }
    }
    private func picker(_ node: MiniAppNode) -> some View {
        Picker(string(node, "title"), selection: textBinding(node)) {
            ForEach(props(node)["options"]?.miniArray ?? [], id: \.self) { option in
                Text(option["label"]?.miniText ?? option.miniText).tag(option["value"]?.miniText ?? option.miniText)
            }
        }
    }
    private func props(_ node: MiniAppNode) -> [String: JSONValue] { node.props.mapValues { model.value($0, item: item) } }
    private func string(_ node: MiniAppNode, _ key: String, fallback: String = "") -> String { props(node)[key]?.miniText ?? fallback }
    private func textBinding(_ node: MiniAppNode) -> Binding<String> {
        let binding = model.binding(node.props["binding"]?.stringValue ?? id)
        return Binding(get: { binding.wrappedValue.miniText }, set: { value in
            binding.wrappedValue = node.props["format"]?.stringValue == "number" ? Double(value).map(JSONValue.number) ?? .null : .string(value)
            model.event(node, "change", item: item)
        })
    }
    private func boolBinding(_ node: MiniAppNode) -> Binding<Bool> {
        let binding = model.binding(node.props["binding"]?.stringValue ?? id)
        return Binding(get: { binding.wrappedValue.miniTruth }, set: { binding.wrappedValue = .bool($0); model.event(node, "change", item: item) })
    }
    private func dateBinding(_ node: MiniAppNode) -> Binding<Date> {
        let binding = model.binding(node.props["binding"]?.stringValue ?? id)
        return Binding(get: { ISO8601DateFormatter().date(from: binding.wrappedValue.miniText) ?? ISO8601DateFormatter().date(from: binding.wrappedValue.miniText + "T00:00:00Z") ?? Date() }, set: { binding.wrappedValue = .string(ISO8601DateFormatter().string(from: $0)); model.event(node, "change", item: item) })
    }
    private func children(_ node: MiniAppNode) -> some View {
        ForEach(node.children, id: \.self) { child in AnyView(MiniAppNodeView(model: model, id: child, item: item, depth: depth + 1)) }
    }
}
/// Writes the device's when-in-use position to the node's binding, then fires `change`.
/// Asks for access only from a press; `auto` fills in on appear once access was granted.
private struct MiniLocationButton: View {
    @Bindable var model: MiniAppRuntime
    let node: MiniAppNode
    let item: JSONValue
    let title: String
    let icon: String
    @State private var location = LocationProvider()
    @State private var locating = false
    @State private var denied = false

    var body: some View {
        Button {
            Task { await locate(prompt: true) }
        } label: {
            if locating { ProgressView().controlSize(.small) } else { Label(title, systemImage: icon) }
        }
        .disabled(locating)
        .task {
            location.refreshAuthorization()
            if node.props["auto"]?.miniTruth == true, location.isAuthorized { await locate(prompt: false) }
        }
        .alert("Location Unavailable", isPresented: $denied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Allow Chippy to use your location in Settings, then try again.")
        }
        .sensoryFeedback(.success, trigger: locating) { old, new in old && !new && !denied }
    }

    private func locate(prompt: Bool) async {
        locating = true
        defer { locating = false }
        if prompt, !location.isAuthorized { location.requestAccess() }
        guard let fix = await location.currentLocation(timeout: prompt ? .seconds(30) : .seconds(8)) else {
            location.refreshAuthorization()
            if prompt { denied = true }
            return
        }
        model.binding(node.props["binding"]?.stringValue ?? "location").wrappedValue = .object([
            "latitude": .number(fix.coordinate.latitude),
            "longitude": .number(fix.coordinate.longitude),
            "accuracy": .number(fix.horizontalAccuracy)
        ])
        model.event(node, "change", item: item)
    }
}

/// A MapKit map centered on `latitude`/`longitude` (or fitted to its markers). Selecting a marker
/// writes its id to `binding` and fires `change`.
private struct MiniMapView: View {
    @Bindable var model: MiniAppRuntime
    let node: MiniAppNode
    let props: [String: JSONValue]
    let item: JSONValue
    @State private var position: MapCameraPosition = .automatic
    @State private var selection: String?

    private struct Pin: Identifiable {
        let id: String
        let title: String
        let icon: String
        let tint: Color
        let coordinate: CLLocationCoordinate2D
    }

    var body: some View {
        Map(position: $position, interactionModes: props["interactive"] == .bool(false) ? [] : .all, selection: $selection) {
            ForEach(pins) { pin in
                Marker(pin.title, systemImage: pin.icon, coordinate: pin.coordinate).tint(pin.tint).tag(pin.id)
            }
        }
        .frame(height: min(600, max(120, props["height"]?.miniNumber ?? 260)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel(pins.isEmpty ? String(localized: "Map") : pins.map(\.title).joined(separator: ", "))
        .onChange(of: cameraKey, initial: true) { position = camera }
        .onChange(of: selection) { _, id in
            if let path = node.props["binding"]?.stringValue { model.binding(path).wrappedValue = id.map(JSONValue.string) ?? .null }
            if id != nil { model.event(node, "change", item: item) }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private var center: CLLocationCoordinate2D? {
        guard let latitude = props["latitude"]?.miniNumber, let longitude = props["longitude"]?.miniNumber,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
    private var span: Double { min(20_000_000, max(100, props["span"]?.miniNumber ?? 5_000)) }
    private var camera: MapCameraPosition {
        guard let center else { return .automatic }
        return .region(MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span))
    }
    /// Recenters when the data moves the map, not on every redraw.
    private var cameraKey: String {
        "\(center?.latitude ?? 0),\(center?.longitude ?? 0),\(span),\(pins.map(\.id).joined(separator: "|"))"
    }
    private var pins: [Pin] {
        (props["markers"]?.miniArray ?? []).prefix(100).enumerated().compactMap { index, marker in
            guard let latitude = marker["latitude"]?.miniNumber, let longitude = marker["longitude"]?.miniNumber,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            let tint: Color = switch marker["tone"]?.stringValue {
            case "accent": .accentColor
            case "positive": .green
            case "warning": .orange
            case "negative": .red
            default: .red
            }
            return Pin(id: marker["id"].map(\.miniText).flatMap { $0.isEmpty ? nil : $0 } ?? "\(index)", title: marker["title"]?.miniText ?? "",
                       icon: marker["icon"]?.stringValue ?? "mappin", tint: tint,
                       coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }
}

/// `searchable` adds a native search field: typing writes `state.search` and fires `search`
/// (debounced); pressing Return fires `submit`.
private struct MiniSearchModifier: ViewModifier {
    @Bindable var model: MiniAppRuntime
    let node: MiniAppNode
    let item: JSONValue
    func body(content: Content) -> some View {
        if model.value(node.props["searchable"], item: item).miniTruth {
            content
                .searchable(text: $model.search)
                .task(id: model.search) {
                    do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() } catch { return }
                    MiniAppExpression.write(&model.state, path: "search", value: .string(model.search))
                    if let action = node.events["search"] { await model.run(action, item: item) }
                }
                .onSubmit(of: .search) {
                    MiniAppExpression.write(&model.state, path: "search", value: .string(model.search))
                    model.event(node, "submit", item: item)
                }
        } else { content }
    }
}

/// Pull to refresh only where a `refresh` event is wired.
private struct MiniRefreshModifier: ViewModifier {
    let model: MiniAppRuntime
    let action: String?
    let item: JSONValue
    func body(content: Content) -> some View {
        if let action { content.refreshable { await model.run(action, item: item) } } else { content }
    }
}

private struct MiniIdentityModifier: ViewModifier {
    let id: String?
    func body(content: Content) -> some View {
        if let id { content.accessibilityIdentifier(id) } else { content }
    }
}

extension EnvironmentValues {
    /// True for a Mini App Grid's cells, so cards stretch to the height of their row.
    @Entry var miniGridCell = false
}
