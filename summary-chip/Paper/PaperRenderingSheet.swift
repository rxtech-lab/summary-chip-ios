import SummaryKit
import SwiftUI

struct PaperRenderingSheet: View {
    let api: SummaryAPIClient
    let paper: Paper
    let onSaved: (Paper) -> Void
    @State private var style: PaperRendering
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsReset = false
    @State private var changes = 0
    @State private var saved = 0
    @Environment(\.dismiss) private var dismiss

    init(api: SummaryAPIClient, paper: Paper, onSaved: @escaping (Paper) -> Void) {
        self.api = api
        self.paper = paper
        self.onSaved = onSaved
        _style = State(initialValue: paper.rendering)
    }

    var body: some View {
        NavigationStack {
            settings
                .navigationTitle("Rendering Options")
                .summaryInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(isSaving || style == paper.rendering)
                            .accessibilityIdentifier("paper-rendering-save")
                    }
                }
                .overlay { if isSaving { ActionStatusOverlay(String(localized: "Saving rendering options…")) } }
                .interactiveDismissDisabled(isSaving)
                .statusAlert("Couldn't Save Rendering Options", message: errorMessage) { errorMessage = nil }
                .confirmationDialog("Reset rendering options?", isPresented: $confirmsReset, titleVisibility: .visible) {
                    Button("Use Original Layout", role: .destructive) { style = PaperRendering() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("This restores the LaTeX layout after you save. Your source and translations stay unchanged.") }
                .sensoryFeedback(.selection, trigger: changes)
                .sensoryFeedback(.warning, trigger: confirmsReset) { _, shown in shown }
                .sensoryFeedback(.success, trigger: saved)
                .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
        .summarySheetSize()
        .presentationDetents([.large])
        .onChange(of: style) { _, _ in changes += 1 }
    }

    private var settings: some View {
        Form {
            Section {
                Toggle("Use Custom Rendering", isOn: $style.enabled)
                    .accessibilityIdentifier("paper-rendering-enabled")
                presets
            } footer: {
                Text("Applies to the PDF preview and PDF / Word exports in every language. Your source stays unchanged. Text stays editable; pagination may differ between formats.")
            }
            Group {
                pageSettings
                marginSettings
                typeSettings
                paragraphSettings
                headingSettings
                structureSettings
                pageDecorationSettings
            }
            .disabled(!style.enabled)
            Section {
                Button("Reset to Original Layout", role: .destructive) { confirmsReset = true }
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
    }

    private var presets: some View {
        Menu {
            Button("Standard") { style = PaperRendering(); style.enabled = true }
            Button("Two-column Paper") {
                style = PaperRendering()
                style.enabled = true
                style.columns = 2
                style.fontSize = 10
                style.headingSize = 14
                style.paragraphSpacing = 4
                style.marginLeft = 18
                style.marginRight = 18
                style.fontFamily = "serif"
            }
            Button("Comfortable Reading") {
                style = PaperRendering()
                style.enabled = true
                style.fontSize = 14
                style.lineSpacing = 1.5
                style.paragraphSpacing = 10
                style.alignment = "left"
                style.fontFamily = "sans"
            }
        } label: {
            Label("Apply Preset…", systemImage: "wand.and.stars")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("paper-rendering-presets")
    }

    private var pageSettings: some View {
        Section("Page & Columns") {
            Picker("Page Size", selection: $style.pageSize) {
                Text("A4").tag("a4")
                Text("US Letter").tag("letter")
                Text("US Legal").tag("legal")
                Text("A5").tag("a5")
            }
            Picker("Orientation", selection: $style.orientation) {
                Text("Portrait").tag("portrait")
                Text("Landscape").tag("landscape")
            }
            Picker("Columns", selection: $style.columns) {
                Text("One Column").tag(1)
                Text("Two Columns").tag(2)
            }
            .accessibilityIdentifier("paper-rendering-columns")
            numeric("Column Gap", value: $style.columnGap, range: 3...20).disabled(style.columns == 1)
        }
        .pickerStyle(.menu)
    }

    private var marginSettings: some View {
        Section("Margins") {
            numeric("Top", value: $style.marginTop, range: 5...50)
            numeric("Bottom", value: $style.marginBottom, range: 5...50)
            numeric("Left", value: $style.marginLeft, range: 5...50)
            numeric("Right", value: $style.marginRight, range: 5...50)
        }
    }

    private var typeSettings: some View {
        Section("Typography") {
            Picker("Font Family", selection: $style.fontFamily) {
                Text("Original").tag("original")
                Text("Serif").tag("serif")
                Text("Sans Serif").tag("sans")
                Text("Monospace").tag("mono")
            }
            .pickerStyle(.menu)
            numeric("Body Font Size", value: $style.fontSize, range: 8...24, unit: "pt")
            numeric("Line Spacing", value: $style.lineSpacing, range: 1...2.5, step: 0.05, unit: "×")
            Toggle("Hyphenation", isOn: $style.hyphenation)
        }
    }

    private var paragraphSettings: some View {
        Section("Paragraphs") {
            Picker("Alignment", selection: $style.alignment) {
                Text("Justified").tag("justified")
                Text("Left").tag("left")
                Text("Center").tag("center")
                Text("Right").tag("right")
            }
            .pickerStyle(.menu)
            numeric("Paragraph Spacing", value: $style.paragraphSpacing, range: 0...24, unit: "pt")
            numeric("First Line Indent", value: $style.paragraphIndent, range: 0...36, unit: "pt")
        }
    }

    private var headingSettings: some View {
        Section("Headings") {
            numeric("Heading Font Size", value: $style.headingSize, range: 12...32, unit: "pt")
            Picker("Heading Color", selection: $style.headingColor) {
                Text("Black").tag("000000")
                Text("Blue").tag("1D4ED8")
                Text("Indigo").tag("4338CA")
                Text("Teal").tag("0F766E")
                Text("Slate").tag("475569")
            }
            .pickerStyle(.menu)
            Toggle("Number Sections", isOn: $style.sectionNumbers)
        }
    }

    private var structureSettings: some View {
        Section("Document Structure") {
            Toggle("Separate Title Page", isOn: $style.titlePage)
            Toggle("Table of Contents", isOn: $style.tableOfContents)
            Picker("Contents Depth", selection: $style.tocDepth) {
                Text("Sections").tag(1)
                Text("Sections & Subsections").tag(2)
                Text("All Heading Levels").tag(3)
            }
            .pickerStyle(.menu)
            .disabled(!style.tableOfContents)
        }
    }

    private var pageDecorationSettings: some View {
        Section("Headers & Footers") {
            Picker("Page Numbers", selection: $style.pageNumbers) {
                Text("None").tag("none")
                Text("Footer · Left").tag("footer-left")
                Text("Footer · Center").tag("footer-center")
                Text("Footer · Right").tag("footer-right")
                Text("Header · Left").tag("header-left")
                Text("Header · Center").tag("header-center")
                Text("Header · Right").tag("header-right")
            }
            .pickerStyle(.menu)
            TextField("Header Text", text: $style.headerText)
                .onChange(of: style.headerText) { _, value in style.headerText = String(value.prefix(160)) }
            TextField("Footer Text", text: $style.footerText)
                .onChange(of: style.footerText) { _, value in style.footerText = String(value.prefix(160)) }
        }
    }

    private func numeric(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double = 1, unit: String = "mm") -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2)))) \(unit)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let fresh = try await api.savePaperRendering(id: paper.id, options: style)
            saved += 1
            onSaved(fresh)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
