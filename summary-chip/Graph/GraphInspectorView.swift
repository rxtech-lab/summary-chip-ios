import SummaryKit
import SwiftUI

/// Everything about a node or edge: pictures, its JSON-rendered view and its properties. The body of
/// both the popover (macOS, iPad, wide iPhones) and the half sheet (iPhone).
struct GraphInspectorContent: View {
    let model: GraphModel
    let element: GraphElementRef
    let onOpen: (GraphElementRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch element {
            case .node(let id):
                if let node = model.node(id) { nodeContent(node) } else { gone }
            case .edge(let id):
                if let edge = model.edge(id) { edgeContent(edge) } else { gone }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("graph-inspector")
    }

    private var gone: some View {
        ContentUnavailableView("No Longer in This Graph", systemImage: "questionmark.circle")
    }

    @ViewBuilder
    private func nodeContent(_ node: GraphNode) -> some View {
        Text(node.label).font(.title3.weight(.semibold)).textSelection(.enabled)
        if !node.types.isEmpty { GraphTypeChips(types: node.types) }
        data(images: node.images, view: node.view, properties: node.properties)
        let links = model.document?.edges.filter { $0.source == node.id || $0.target == node.id } ?? []
        if !links.isEmpty {
            GraphInfoSection(title: "Connections") {
                ForEach(links.prefix(50)) { edge in
                    let other = edge.source == node.id ? edge.target : edge.source
                    Button {
                        onOpen(.edge(edge.id))
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: edge.source == node.id ? "arrow.up.right" : "arrow.down.left").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(model.node(other)?.label ?? other).lineLimit(1)
                                Text(edge.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if links.count > 50 { Text("And \(links.count - 50) more").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder
    private func edgeContent(_ edge: GraphEdge) -> some View {
        Text(edge.label).font(.title3.weight(.semibold)).textSelection(.enabled)
        HStack(spacing: 8) {
            endpoint(edge.source)
            Image(systemName: edge.directed ? "arrow.right" : "arrow.left.and.right").foregroundStyle(.secondary).accessibilityHidden(true)
            endpoint(edge.target)
        }
        data(images: edge.images, view: edge.view, properties: edge.properties)
    }

    private func endpoint(_ id: String) -> some View {
        Button(model.node(id)?.label ?? id) { onOpen(.node(id)) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lineLimit(1)
    }

    @ViewBuilder
    private func data(images: [GraphImage], view: TripViewSpec?, properties: [String: JSONValue]) -> some View {
        if !images.isEmpty { GraphImageStrip(images: images) }
        if let view { NativeJSONViewRenderer(spec: view, currency: "USD") }
        if !properties.isEmpty {
            GraphInfoSection(title: "Properties") {
                GraphJSONObjectView(object: properties, depth: 0)
            }
            DisclosureGroup("Raw JSON") {
                Text(verbatim: GraphJSON.pretty(.object(properties)))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .font(.subheadline)
            .accessibilityIdentifier("graph-raw-json")
        }
    }
}

private struct GraphInfoSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct GraphTypeChips: View {
    let types: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(types, id: \.self) { type in
                    Text(type).font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

struct GraphImageStrip: View {
    let images: [GraphImage]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    VStack(alignment: .leading, spacing: 4) {
                        AsyncImage(url: image.url) { phase in
                            if let picture = phase.image { picture.resizable().scaledToFill() }
                            else { Rectangle().fill(.quaternary).overlay { if phase.error == nil { ProgressView() } else { Image(systemName: "photo") } } }
                        }
                        .frame(width: 160, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel(Text(image.caption ?? String(localized: "Image")))
                        if let caption = image.caption, !caption.isEmpty {
                            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 160, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

enum GraphJSON {
    static func pretty(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses an object typed in an editor; empty text is an empty object.
    static func parseObject(_ text: String) throws -> [String: JSONValue] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        guard case .object(let object) = value else { throw GraphJSONError.notAnObject }
        return object
    }
}

enum GraphJSONError: LocalizedError {
    case notAnObject

    var errorDescription: String? { String(localized: "Enter a JSON object, like {\"name\": \"Ada\"}.") }
}

/// Native rendering of schemaless data: any JSON a node holds becomes rows, without a schema.
struct GraphJSONObjectView: View {
    let object: [String: JSONValue]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(object.keys.sorted(), id: \.self) { key in
                GraphJSONRow(key: key, value: object[key] ?? .null, depth: depth)
            }
        }
    }
}

private struct GraphJSONRow: View {
    let key: String
    let value: JSONValue
    let depth: Int

    var body: some View {
        switch value {
        case .object(let object) where depth < 6 && !object.isEmpty:
            DisclosureGroup(key) {
                AnyView(GraphJSONObjectView(object: object, depth: depth + 1)).padding(.top, 4)
            }
            .font(.subheadline)
        case .array(let items) where depth < 6 && !items.isEmpty && items.contains(where: Self.isContainer):
            DisclosureGroup("\(key) (\(items.count))") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.prefix(100).enumerated()), id: \.offset) { index, item in
                        AnyView(GraphJSONRow(key: "\(index + 1)", value: item, depth: depth + 1))
                    }
                }
                .padding(.top, 4)
            }
            .font(.subheadline)
        default:
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(key).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                leaf.font(.subheadline).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func isContainer(_ value: JSONValue) -> Bool {
        switch value {
        case .object, .array: true
        default: false
        }
    }

    @ViewBuilder private var leaf: some View {
        switch value {
        case .string(let text):
            if let url = URL(string: text), url.scheme == "https", url.host() != nil { Link(text, destination: url).lineLimit(2) }
            else { Text(text) }
        case .number(let number):
            Text(number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)).monospacedDigit()
        case .bool(let flag):
            Image(systemName: flag ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(flag ? .green : .secondary)
                .accessibilityLabel(flag ? Text("Yes") : Text("No"))
        case .null:
            Text(verbatim: "—").foregroundStyle(.tertiary)
        case .array(let items):
            Text(items.compactMap(\.graphPlainText).joined(separator: ", "))
        case .object:
            Text(verbatim: "{ }").foregroundStyle(.tertiary)
        }
    }
}

private extension JSONValue {
    var graphPlainText: String? {
        switch self {
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
        case .bool(let flag): flag ? "true" : "false"
        default: nil
        }
    }
}
