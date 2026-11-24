import SwiftUI
import SummaryKit
import UniformTypeIdentifiers

struct ResumeFile: FileDocument {
    static let wordType = UTType(filenameExtension: "docx") ?? .data
    static var readableContentTypes: [UTType] { [.pdf, wordType] }
    let data: Data
    init(_ data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ResumeExportSheet: View {
    let api: SummaryAPIClient
    let initial: ResolvedResume
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Step] = []
    @State private var edition: ResolvedResume
    @State private var history: [ResumeRevision] = []
    @State private var selection: String
    @State private var presentation = ResumePresentation()
    @State private var preview: ResumePreview?
    @State private var pdf: Data?
    @State private var file: ResumeFile?
    @State private var type = UTType.pdf
    @State private var exporting = false
    @State private var action = ResumeAction()

    enum Step: Int, Hashable, CaseIterable { case edition = 1, template, preview, publish }

    init(api: SummaryAPIClient, initial: ResolvedResume) {
        self.api = api
        self.initial = initial
        _edition = State(initialValue: initial)
        _selection = State(initialValue: initial.revisionToken)
    }

    var body: some View {
        NavigationStack(path: $path) {
            companyPage
                .navigationTitle("Export Résumé")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .edition: editionPage
                    case .template: templatePage
                    case .preview: previewPage
                    case .publish: if let preview { ResumePublishForm(api: api, resume: edition, preview: preview) }
                    }
                }
        }
        .fileExporter(isPresented: $exporting, document: file, contentType: type, defaultFilename: edition.document.candidateName) { result in
            if case .failure(let error) = result { action.error = error.localizedDescription }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .summarySheetFrame(minWidth: 680, idealWidth: 820, minHeight: 720)
        .resumeFeedback(action)
        .sensoryFeedback(.selection, trigger: presentation)
    }

    // MARK: Step 0 – company

    private var companyPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ResumeExportHeader(step: nil, title: "Choose an edition",
                                   subtitle: "Export the base résumé or a version tailored to a company.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ResumeChoiceCard(title: String(localized: "Base résumé"), subtitle: String(localized: "Shared by every company"),
                                     systemImage: "doc.text", tint: .blue, selected: initial.variantId == nil) { select(variant: nil) }
                    ForEach(initial.variants) { company in
                        ResumeChoiceCard(title: company.company, subtitle: company.targetRole ?? String(localized: "Company variant"),
                                         systemImage: "building.2", tint: .purple, selected: initial.variantId == company.id) {
                            select(variant: company.id)
                        }
                        .accessibilityIdentifier("export-company-" + company.id)
                    }
                }
            }
            .padding(24)
        }
        .background(.background.secondary)
    }

    // MARK: Step 1 – language and revision

    private var editionPage: some View {
        Form {
            Section {
                ResumeExportHeader(step: .edition, title: edition.companyName, subtitle: edition.provenance)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Picker(selection: Binding(get: { edition.language }, set: { language in
                    action.run("Opening edition…") { try await load(edition.variantId, language) }
                })) {
                    ForEach(edition.languages, id: \.self) { Text(SummaryLanguage.displayName(for: $0)).tag($0) }
                } label: { Label("Language", systemImage: "globe") }
                Picker(selection: $selection) {
                    Text("Latest saved revision").tag(edition.revisionToken)
                    ForEach(history.filter { $0.revisionToken != edition.revisionToken }) { item in
                        Text("\(item.origin.capitalized) r\(item.revision) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))").tag(item.revisionToken)
                    }
                } label: { Label("Revision", systemImage: "clock.arrow.circlepath") }
            } footer: {
                Text("Pick an older revision to export the résumé exactly as it was saved then.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Language and Revision")
        .resumeExportFooter {
            Button {
                action.run("Opening revision…") {
                    edition = try await api.resume(id: initial.familyId, variantId: edition.variantId, language: edition.language, revisionToken: selection)
                    path.append(.template)
                }
            } label: { Label("Choose Template", systemImage: "arrow.right") }
        }
    }

    // MARK: Step 2 – template

    private var templatePage: some View {
        Form {
            Section {
                ResumeExportHeader(step: .template, title: "Design your PDF", subtitle: edition.companyName + " · " + SummaryLanguage.displayName(for: edition.language))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section("Template") {
                HStack(spacing: 14) {
                    ForEach(ResumePresentation.Template.allCases, id: \.self) { template in
                        ResumeTemplateCard(template: template, selected: presentation.template == template) {
                            withAnimation(.snappy) { presentation.template = template }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Layout") {
                Picker(selection: $presentation.paperSize) {
                    ForEach(ResumePresentation.PaperSize.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                } label: { Label("Paper size", systemImage: "doc") }
                .pickerStyle(.segmented)
                if presentation.template == .profile, edition.document.avatarAssetId != nil {
                    Toggle(isOn: $presentation.showAvatar) { Label("Show avatar", systemImage: "person.crop.circle") }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Template")
        .resumeExportFooter {
            Button {
                action.run("Rendering preview…") {
                    let prepared = try await api.previewResume(target: edition.target, presentation: presentation)
                    pdf = try await api.resumeArtifact(path: prepared.pdfUrl)
                    preview = prepared
                    path.append(.preview)
                }
            } label: { Label("Preview PDF", systemImage: "eye") }
        }
    }

    // MARK: Step 3 – preview and export

    private var previewPage: some View {
        VStack(spacing: 0) {
            ResumeExportHeader(step: .preview, title: "Review and export",
                               subtitle: edition.companyName + " · " + presentation.template.title + " · " + presentation.paperSize.rawValue)
                .padding(.horizontal, 24).padding(.vertical, 16)
            Group {
                if let pdf {
                    PaperPDFView(data: pdf)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
                        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .background(.background.secondary)
        .navigationTitle("Export Preview")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("resume-export-close") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exportButtons }
                VStack(spacing: 8) { exportButtons }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    @ViewBuilder private var exportButtons: some View {
        Button { path.append(.publish) } label: { Label("Publish Link", systemImage: "link").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
        Button {
            guard let preview else { return }
            action.run("Preparing Word document…") {
                file = ResumeFile(try await api.resumeArtifact(path: preview.docxUrl))
                type = ResumeFile.wordType; exporting = true
            }
        } label: { Label("Save DOCX", systemImage: "doc.richtext").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
        Button { if let pdf { file = ResumeFile(pdf); type = .pdf; exporting = true } } label: {
            Label("Save PDF", systemImage: "arrow.down.doc").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    private func select(variant: String?) {
        action.run("Opening edition…") {
            if variant == initial.variantId {
                edition = initial
                selection = initial.revisionToken
                history = try await api.resumeHistory(target: initial.target)
            } else { try await load(variant, initial.language) }
            path.append(.edition)
        }
    }

    private func load(_ variant: String?, _ language: String) async throws {
        let loaded = try await api.resume(id: initial.familyId, variantId: variant, language: language)
        let revisions = try await api.resumeHistory(target: loaded.target)
        edition = loaded; selection = loaded.revisionToken; history = revisions
    }
}

// MARK: - Export sheet components

extension ResumePresentation.Template {
    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .profile: String(localized: "Profile")
        }
    }
    var blurb: LocalizedStringKey {
        switch self {
        case .compact: "Dense single column, ideal for applicant tracking systems."
        case .profile: "Sidebar layout with an optional photo."
        }
    }
}

extension ResumeExportSheet.Step {
    var title: LocalizedStringKey {
        switch self {
        case .edition: "Edition"
        case .template: "Template"
        case .preview: "Preview"
        case .publish: "Publish"
        }
    }
}

/// Step progress plus a title for each export page.
private struct ResumeExportHeader: View {
    let step: ResumeExportSheet.Step?
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach([ResumeExportSheet.Step.edition, .template, .preview], id: \.self) { item in
                    let reached = (step?.rawValue ?? 0) >= item.rawValue
                    HStack(spacing: 6) {
                        Text("\(item.rawValue)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(reached ? .white : .secondary)
                            .frame(width: 18, height: 18)
                            .background(reached ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.secondary), in: .circle)
                        Text(item.title).font(.caption.weight(.semibold)).foregroundStyle(reached ? .primary : .secondary)
                    }
                    if item != .preview {
                        Capsule().fill(reached ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.fill.secondary))
                            .frame(width: 24, height: 2)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ResumeChoiceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.14), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                if selected {
                    Text("Current").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(.tint.opacity(0.12), in: .capsule)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.background, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// A selectable miniature of each PDF template.
private struct ResumeTemplateCard: View {
    let template: ResumePresentation.Template
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(.white, in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.08)))
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
                HStack {
                    Text(template.title).font(.headline)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .font(.title3)
                }
                Text(template.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.fill.quaternary), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var thumbnail: some View {
        let ink = Color.black.opacity(0.14)
        switch template {
        case .compact:
            VStack(alignment: .leading, spacing: 5) {
                bar(ink.opacity(2.5), 0.5, 7)
                bar(ink, 0.35, 4)
                Rectangle().fill(Color.accentColor.opacity(0.7)).frame(height: 1.5).padding(.vertical, 3)
                ForEach(0..<3, id: \.self) { _ in
                    bar(Color.accentColor.opacity(0.6), 0.25, 4)
                    bar(ink, 0.95, 3); bar(ink, 0.85, 3); bar(ink, 0.7, 3)
                }
                Spacer(minLength: 0)
            }
        case .profile:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Circle().fill(Color.accentColor.opacity(0.35)).frame(width: 26, height: 26)
                    ForEach(0..<6, id: \.self) { _ in bar(ink, 0.8, 3) }
                    Spacer(minLength: 0)
                }
                .padding(6)
                .frame(width: 52)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 5) {
                    bar(ink.opacity(2.5), 0.6, 7)
                    bar(ink, 0.4, 4).padding(.bottom, 4)
                    ForEach(0..<2, id: \.self) { _ in
                        bar(Color.accentColor.opacity(0.6), 0.3, 4)
                        bar(ink, 0.95, 3); bar(ink, 0.8, 3); bar(ink, 0.9, 3)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func bar(_ color: Color, _ fraction: CGFloat, _ height: CGFloat) -> some View {
        GeometryReader { proxy in
            Capsule().fill(color).frame(width: proxy.size.width * fraction)
        }
        .frame(height: height)
    }
}

private extension View {
    /// Pins the primary step action to the bottom of an export page.
    func resumeExportFooter(@ViewBuilder _ button: () -> some View) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                button()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.bar)
        }
    }
}

private struct ResumePublishForm: View {
    let api: SummaryAPIClient
    let resume: ResolvedResume
    let preview: ResumePreview
    @State private var links: [ResumePublishedLink] = []
    @State private var linkId: String?
    @State private var access = ShareLinkAccess.anyone
    @State private var days = 7
    @State private var invitees = ""
    @State private var approved = Set<String>()
    @State private var result: SummaryShareLink?
    @State private var action = ResumeAction()
    @State private var revoke = false

    private var previous: ResumePublishedLink? { links.first { $0.id == linkId } }
    var body: some View {
        Form {
            if let result {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: result.url)
                        Text("Résumé published").font(.title2.bold())
                        Text(result.url.absoluteString)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        ShareLink(item: result.url) { Label("Share Published Résumé", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
            } else {
                Section {
                    Picker(selection: $linkId) {
                        Text("New link").tag(String?.none)
                        ForEach(links) { link in Text(link.label ?? String(link.url.lastPathComponent.prefix(8))).tag(Optional(link.id)) }
                    } label: { Label("Link", systemImage: "link") }
                } footer: { Text("Republishing an existing link keeps its URL and swaps in this preview.") }
                Section {
                    Picker(selection: $access) {
                        ForEach(ShareLinkAccess.allCases) { Text($0.title).tag($0) }
                    } label: { Label("Access", systemImage: "person.2") }
                    if access == .invited { TextField("Invited email addresses", text: $invitees, axis: .vertical) }
                    Picker(selection: $days) {
                        ForEach(TTLOption.allowedDays, id: \.self) { Text("\($0) days").tag($0) }
                    } label: { Label("Expires in", systemImage: "timer") }
                } footer: { Text(access == .invited ? "Recipients sign in to the Chippy app with an invited email address." : "Anyone with this link can open the résumé in a browser.") }
                if let missing = preview.missingTranslationPaths, !missing.isEmpty {
                    Section("Approve wording without a translation") {
                        ForEach(missing, id: \.self) { path in
                            Toggle(isOn: Binding(get: { approved.contains(path) }, set: { value in
                                if value { approved.insert(path) } else { approved.remove(path) }
                            })) {
                                Text(path).font(.caption)
                                Text((try? resume.document.value(at: path))?.stringValue ?? "")
                            }
                        }
                    }
                }
                if previous != nil {
                    Section { Button("Revoke Link", systemImage: "link.badge.minus", role: .destructive) { revoke = true } }
                }
            }
        }
        .formStyle(.grouped).navigationTitle("Publish Résumé")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if result == nil {
                HStack {
                    Spacer()
                    Button(previous == nil ? "Publish Previewed PDF" : "Republish Previewed PDF", systemImage: "paperplane") { publish() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(approved.count < (preview.missingTranslationPaths?.count ?? 0) || (access == .invited && invitees.nilIfBlank == nil))
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(.bar)
            }
        }
        .task { do { links = try await api.resumePublications(id: resume.familyId) } catch { action.error = error.localizedDescription } }
        .onChange(of: linkId) { _, _ in
            access = previous?.access ?? .anyone; days = previous?.ttlDays ?? 7
            invitees = previous?.emails.map(\.email).joined(separator: ", ") ?? ""
        }
        .confirmationDialog("Revoke this published link?", isPresented: $revoke) {
            Button("Revoke", role: .destructive) {
                guard let previous else { return }
                action.run("Revoking link…") {
                    try await api.deleteShareLink(summaryID: resume.familyId, linkID: previous.id)
                    links.removeAll { $0.id == previous.id }; linkId = nil
                }
            }
        }.resumeFeedback(action)
    }

    private func publish() {
        action.run("Publishing résumé…") {
            let emails = access == .invited ? invitees.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) : []
            result = try await api.publishResume(id: resume.familyId, previewId: preview.id, access: access, ttlDays: days, emails: emails,
                replacing: previous, acceptedWordingPaths: approved.sorted(),
                idempotencyKey: action.key(for: [preview.id, access.rawValue, String(days), linkId ?? "", previous?.previewId ?? ""] + emails + approved.sorted()))
        }
    }
}

struct ResumeRecipientView: View {
    let api: SummaryAPIClient
    let slug: String
    @State var publication: ResumePublication
    @State private var pdf: Data?
    @State private var unavailable: String?
    @State private var exporting = false
    @Environment(\.scenePhase) private var phase
    @State private var action = ResumeAction()

    var body: some View {
        Group {
            if let unavailable {
                ContentUnavailableView("Résumé unavailable", systemImage: "lock", description: Text(unavailable))
            } else if let pdf {
                PaperPDFView(data: pdf)
            } else { ProgressView() }
        }
        .navigationTitle(unavailable == nil ? publication.document.candidateName : String(localized: "Résumé"))
        .toolbar {
            if pdf != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Download PDF", systemImage: "arrow.down.document") {
                        action.run("Downloading PDF…") {
                            do { pdf = try await api.resumeArtifact(path: publication.pdfUrl); exporting = true }
                            catch { pdf = nil; unavailable = error.localizedDescription; throw error }
                        }
                    }
                }
            }
        }
        .task(id: phase) {
            pdf = nil
            guard phase == .active else { return }
            do {
                let fresh = try await api.resumePublication(slug: slug)
                let bytes = try await api.resumeArtifact(path: fresh.pdfUrl)
                try Task.checkCancellation()
                publication = fresh; unavailable = nil; pdf = bytes
                if let expiry = fresh.expiresAt {
                    try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
                    pdf = nil; unavailable = String(localized: "This link has expired.")
                }
            } catch is CancellationError {}
            catch { if !Task.isCancelled { unavailable = error.localizedDescription } }
        }
        .fileExporter(isPresented: $exporting, document: pdf.map(ResumeFile.init), contentType: .pdf,
                      defaultFilename: publication.document.candidateName) { result in
            if case .failure(let error) = result { action.error = error.localizedDescription }
        }.resumeFeedback(action)
    }
}

struct ViewedResumeLinksSheet: View {
    let api: SummaryAPIClient
    let open: (String) -> Void
    @State private var links: [ViewedResumePublication] = []
    @State private var loaded = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(links) { link in
                Button { open(link.slug) } label: {
                    VStack(alignment: .leading) {
                        Text(link.title)
                        Text("\(SummaryLanguage.displayName(for: link.language)) · \(link.viewedAt.formatted()) · \(link.slug.prefix(6))").font(.caption)
                    }
                }
            }.overlay {
                if let error { ContentUnavailableView("Couldn’t load links", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else if !loaded { ProgressView() }
                else if links.isEmpty { ContentUnavailableView("No viewed résumés", systemImage: "link") }
            }
            .navigationTitle("Viewed Résumés")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                do { links = try await api.viewedResumePublications(); loaded = true }
                catch { self.error = error.localizedDescription }
            }
        }.resumeSheet()
    }
}
