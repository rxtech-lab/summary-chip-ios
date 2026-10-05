import SummaryKit
import SwiftUI

/// Creates or edits a custom view: its title, where it shows (the diary's Planning section or a
/// day), and its JSON spec, with a live preview. The server checks the spec against the catalog
/// on save; agents usually write these through the trip agent or MCP `update_trip`.
struct TripViewEditorSheet: View {
    let model: TripEditorModel
    let document: TripDocument
    let isNew: Bool
    @State private var view: TripView
    @State private var json: String

    init(model: TripEditorModel, document: TripDocument, view: TripView?, dayID: String? = nil) {
        self.model = model
        self.document = document
        self.isNew = view == nil
        let initial = view ?? TripView(id: TripDocument.makeID("view"), title: "", dayId: dayID, spec: Self.template(currency: document.currency))
        _view = State(initialValue: initial)
        _json = State(initialValue: Self.text(of: initial.spec))
    }

    private var parsed: Result<TripViewSpec, SpecError> { Self.parse(json) }

    var body: some View {
        TripEditorScaffold(
            title: isNew ? String(localized: "New View") : String(localized: "Edit View"),
            canSave: view.title.nilIfBlank != nil && (try? parsed.get()) != nil,
            deleteTitle: isNew ? nil : String(localized: "Delete View"),
            deleteMessage: String(localized: "The view is removed from the trip."),
            save: save,
            delete: delete
        ) {
            Section {
                TextField("Title", text: $view.title)
                    .accessibilityIdentifier("trip-view-title-field")
                Picker("Show In", selection: $view.dayId) {
                    Text("Whole Trip").tag(String?.none)
                    ForEach(Array(document.orderedDays.enumerated()), id: \.element.id) { index, day in
                        Text("Day \(index + 1) · \(day.title)").tag(String?.some(day.id))
                    }
                }
            }
            Section {
                TextEditor(text: $json)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 220)
                    .autocorrectionDisabled()
                    .summaryInputCapitalization()
                    .accessibilityIdentifier("trip-view-json-editor")
            } header: {
                Text("Spec (JSON)")
            } footer: {
                Text("Elements are { type, props, children }. Components: Stack, Grid, Card, Disclosure, Heading, Text, Badge, Stat, Callout, KeyValue, List, Table, BarChart, Divider, Link, Image, Gallery, Place. Or ask the trip agent to build one.")
            }
            Section("Preview") {
                switch parsed {
                case .success(let spec):
                    TripViewRenderer(spec: spec, currency: document.currency)
                        .padding(.vertical, 4)
                case .failure(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func save() async throws {
        var view = view
        view.title = view.title.nilIfBlank ?? view.title
        view.spec = try parsed.get()
        try await model.update { $0.upsert(view) }
    }

    private func delete() async throws {
        let id = view.id
        try await model.update { $0.remove(.views, id: id) }
    }

    // MARK: Spec text

    struct SpecError: Error {
        let message: String
    }

    static func parse(_ text: String) -> Result<TripViewSpec, SpecError> {
        let spec: TripViewSpec
        do {
            spec = try JSONDecoder().decode(TripViewSpec.self, from: Data(text.utf8))
        } catch DecodingError.keyNotFound(let key, _) {
            return .failure(SpecError(message: String(localized: "Missing “\(key.stringValue)”.")))
        } catch DecodingError.typeMismatch(_, let context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return .failure(SpecError(message: String(localized: "Wrong type at “\(path)”.")))
        } catch {
            return .failure(SpecError(message: String(localized: "This isn't valid JSON.")))
        }
        guard spec.elements[spec.root] != nil else {
            return .failure(SpecError(message: String(localized: "The root “\(spec.root)” isn't one of the elements.")))
        }
        for (id, element) in spec.elements {
            if let missing = element.children.first(where: { spec.elements[$0] == nil }) {
                return .failure(SpecError(message: String(localized: "“\(id)” lists a child “\(missing)” that isn't one of the elements.")))
            }
        }
        return .success(spec)
    }

    static func text(of spec: TripViewSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(spec)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// A small comparison table to start from.
    static func template(currency: String) -> TripViewSpec {
        func row(_ item: String, _ a: Double, _ b: Double) -> JSONValue {
            .object(["cells": .object(["item": .string(item), "a": .number(a), "b": .number(b)])])
        }
        return TripViewSpec(root: "root", elements: [
            "root": TripViewElement(type: "Stack", children: ["intro", "table"]),
            "intro": TripViewElement(type: "Text", props: ["text": .string(String(localized: "Compare two options side by side.")), "tone": .string("muted")]),
            "table": TripViewElement(type: "Table", props: [
                "columns": .array([
                    .object(["key": .string("item"), "label": .string(String(localized: "Item"))]),
                    .object(["key": .string("a"), "label": .string(String(localized: "Option A")), "align": .string("trailing"), "format": .string("money"), "currency": .string(currency), "total": .bool(true)]),
                    .object(["key": .string("b"), "label": .string(String(localized: "Option B")), "align": .string("trailing"), "format": .string("money"), "currency": .string(currency), "total": .bool(true)]),
                ]),
                "rows": .array([row(String(localized: "First"), 0, 0), row(String(localized: "Second"), 0, 0)]),
            ]),
        ])
    }
}
