import SummaryKit
import SwiftUI

@Observable @MainActor
final class ResumeAction {
    var status: String?
    var error: String?
    var successes = 0
    private var lastRequest: AnyHashable?
    private var key = UUID().uuidString

    /// Preserve the key when retrying the same request following an uncertain network result.
    func key(for payload: some Hashable) -> String {
        if lastRequest != AnyHashable(payload) { lastRequest = AnyHashable(payload); key = UUID().uuidString }
        return key
    }

    func run(_ label: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard status == nil else { return }
        status = label
        Task {
            defer { status = nil }
            do { try await action(); successes += 1 }
            catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
    }
}

extension View {
    func resumeFeedback(_ action: ResumeAction) -> some View {
        disabled(action.status != nil)
            .overlay { if let status = action.status { ActionStatusOverlay(status) } }
            .statusAlert("Résumé", message: action.error) { action.error = nil }
            .sensoryFeedback(.success, trigger: action.successes)
            .sensoryFeedback(.error, trigger: action.error)
    }

    func resumeSheet() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .summarySheetFrame(minWidth: 560, idealWidth: 700, minHeight: 600)
    }
}

extension ResolvedResume {
    var companyName: String { variants.first { $0.id == variantId }?.company ?? String(localized: "Base résumé") }
    var provenance: String {
        "\(SummaryLanguage.displayName(for: language)) · Base r\(baseRevision) · \(overrideCount) overrides · \(reviewPaths.count) changes to review · \(missingTranslationPaths.count) translations to review"
    }
}

struct NewResumeSheet: View {
    let api: SummaryAPIClient
    let onCreated: (ResolvedResume) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var headline = ""
    @State private var title = ""
    @State private var language: SummaryLanguage = .en
    @State private var action = ResumeAction()

    var body: some View {
        NavigationStack {
            Form {
                TextField("Library title", text: $title)
                TextField("Candidate name", text: $name)
                TextField("Headline", text: $headline)
                Picker("Language", selection: $language) {
                    ForEach(SummaryLanguage.translations) { Text($0.title).tag($0) }
                }
            }
            .formStyle(.grouped).navigationTitle("New Résumé")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        action.run("Creating résumé…") {
                            let document = ResumeDocument(candidateName: name, headline: headline.nilIfBlank)
                            let result = try await api.createResume(title: title.nilIfBlank ?? name, document: document,
                                language: language.rawValue, idempotencyKey: action.key(for: [title, name, headline, language.rawValue]))
                            onCreated(result)
                            dismiss()
                        }
                    }.disabled(name.nilIfBlank == nil)
                }
            }
        }.resumeFeedback(action).resumeSheet().interactiveDismissDisabled(action.status != nil)
    }
}

struct ResumeDocumentContent: View {
    let document: ResumeDocument
    private var contactLines: [String] { [document.contact?.email, document.contact?.phone, document.contact?.location].compactMap { $0 } }
    var body: some View {
        Section {
            Text(document.candidateName).font(.title.bold())
            if let headline = document.headline { Text(headline).font(.headline) }
            ForEach(contactLines.indices, id: \.self) { index in
                Text(contactLines[index])
            }
            ForEach(document.links) { link in
                if let url = URL(string: link.url) { Link(link.label, destination: url) }
            }
        }
        ForEach(document.sections) { section in
            Section(section.title) {
                ForEach(section.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        if let title = entry.title { Text(title).font(.headline) }
                        if let org = entry.organization { Text(org) }
                        if let location = entry.location { Text(location).foregroundStyle(.secondary) }
                        let dates = [entry.startDate, entry.current == true ? String(localized: "Present") : entry.endDate].compactMap { $0 }
                        if !dates.isEmpty { Text(dates.joined(separator: " – ")).foregroundStyle(.secondary) }
                        if let detail = entry.description { Text(detail) }
                        if let url = entry.url.flatMap(URL.init(string:)) { Link(url.absoluteString, destination: url) }
                        ForEach(entry.bullets) { Text("• " + $0.text) }
                    }
                }
            }
        }
    }
}

struct ResumeDetailView: View {
    let environment: AppEnvironment
    let id: String
    @Environment(\.openSideAgent) private var openSideAgent
    @Environment(\.setSideAgentContext) private var setSideAgentContext
    @State private var avatar: Data?
    @State private var agent: ChatModel?
    @State private var resume: ResolvedResume?
    @State private var action = ResumeAction()
    @State private var sheet: Destination?
    private enum Destination: String, Identifiable {
        case edit, company, history, proposal, export, chat, overrides
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let resume { content(resume) }
            else if let error = action.error {
                ContentUnavailableView("Résumé unavailable", systemImage: "doc", description: Text(error))
            } else { ProgressView() }
        }
        .navigationTitle(resume?.title ?? String(localized: "Résumé"))
        .task(id: id) {
            do { resume = try await environment.api.resume(id: id) }
            catch { action.error = error.localizedDescription }
        }
        .onChange(of: resume?.target, initial: true) { _, target in
            guard let target else { return }
            if agent?.resumeTarget == target { return }
            let model = ChatModel(client: environment.chatClient, store: environment.chatStore, resumeTarget: target)
            model.resumeCompany = resume?.companyName
            model.onResumeUpdated = { updated in
                guard let current = resume, current.familyId == updated.familyId, current.variantId == updated.variantId else { return }
                if current.language == updated.language { resume = updated }
                else { refresh() }
            }
            agent = model
            setSideAgentContext?(model)
        }
        .task(id: resume?.document.avatarAssetId) {
            avatar = nil
            guard let asset = resume?.document.avatarAssetId else { return }
            do {
                let data = try await environment.api.resumeArtifact(path: "/api/v1/resumes/\(id)/assets/\(asset)")
                try Task.checkCancellation()
                avatar = data
            } catch { if !Task.isCancelled { action.error = error.localizedDescription } }
        }
        .sheet(item: $sheet, onDismiss: refresh) { destination in
            if let resume {
                switch destination {
                case .edit: ResumeEditorSheet(api: environment.api, saved: resume) { self.resume = $0 }
                case .company: ResumeCompanySheet(api: environment.api, source: resume) { self.resume = $0 }
                case .history: ResumeHistorySheet(api: environment.api, resume: resume) { self.resume = $0 }
                case .proposal: ResumeProposalSheet(api: environment.api, resume: resume) { self.resume = $0 }
                case .export: ResumeExportSheet(api: environment.api, initial: resume)
                case .chat: ChatView(environment: environment, resumeTarget: resume.target, model: agent)
                case .overrides: ResumeOverridesSheet(api: environment.api, resume: resume) { self.resume = $0 }
                }
            }
        }
        .resumeFeedback(action).sensoryFeedback(.selection, trigger: sheet)
    }

    private func content(_ value: ResolvedResume) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ResumeEditionBar(value: value, select: select, newVariant: { sheet = .company },
                                 showOverrides: value.variantId == nil ? nil : { sheet = .overrides })
                ResumeQuickActions { destination in
                    switch destination {
                    case .tailor: sheet = .proposal
                    case .export: sheet = .export
                    case .history: sheet = .history
                    case .chat: if let openSideAgent, let agent { openSideAgent(agent) } else { sheet = .chat }
                    }
                }
                ResumePaperView(document: value.document, avatar: avatar) { sheet = .edit }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { sheet = .edit }.accessibilityIdentifier("resume-edit")
                Menu("Résumé Actions", systemImage: "ellipsis.circle") {
                    Button("Agent Chat", systemImage: "bubble.left.and.bubble.right") {
                        if let openSideAgent, let agent { openSideAgent(agent) } else { sheet = .chat }
                    }
                    Button("Review, Tailor or Translate", systemImage: "sparkles") { sheet = .proposal }
                    Button("Version History", systemImage: "clock.arrow.circlepath") { sheet = .history }
                    Button("Export or Publish", systemImage: "square.and.arrow.up") { sheet = .export }.accessibilityIdentifier("resume-export")
                    if value.variantId != nil {
                        Divider()
                        Button("Company Overrides", systemImage: "list.bullet") { sheet = .overrides }
                        Button("Edit Base Résumé", systemImage: "pencil") {
                            action.run("Opening base résumé…") {
                                resume = try await environment.api.resume(id: id, language: value.language)
                                sheet = .edit
                            }
                        }
                    }
                }.accessibilityIdentifier("resume-actions")
            }
        }
    }

    private func select(_ variant: String?, _ language: String) {
        action.run("Opening edition…") { resume = try await environment.api.resume(id: id, variantId: variant, language: language) }
    }

    private func refresh() {
        guard let current = resume else { return }
        Task {
            if let updated = try? await environment.api.resume(id: id, variantId: current.variantId, language: current.language),
               resume?.target == current.target, sheet == nil { resume = updated }
        }
    }
}

// MARK: - Redesigned résumé page

extension ResumeDocument.SectionKind {
    var symbol: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .experience: "briefcase"
        case .education: "graduationcap"
        case .skills: "wrench.and.screwdriver"
        case .projects: "hammer"
        case .certifications: "checkmark.seal"
        case .custom: "square.stack"
        }
    }
}

extension ResumeDocument.Entry {
    var dateRange: String? {
        let dates = [startDate, current == true ? String(localized: "Present") : endDate].compactMap { $0?.nilIfBlank }
        return dates.isEmpty ? nil : dates.joined(separator: " – ")
    }
    /// Entries with only a title read best as chips (typical for skills).
    var isChip: Bool { organization == nil && description == nil && bullets.isEmpty && dateRange == nil && url == nil && title != nil }
}

/// Company and language switcher with a compact provenance summary.
struct ResumeEditionBar: View {
    let value: ResolvedResume
    let select: (String?, String) -> Void
    let newVariant: () -> Void
    let showOverrides: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    Button("Base résumé", systemImage: value.variantId == nil ? "checkmark" : "doc.text") { select(nil, value.language) }
                    if !value.variants.isEmpty {
                        Section("Companies") {
                            ForEach(value.variants) { variant in
                                Button(variant.company, systemImage: value.variantId == variant.id ? "checkmark" : "building.2") {
                                    select(variant.id, value.language)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("New Company Variant…", systemImage: "plus") { newVariant() }
                } label: {
                    Label(value.companyName, systemImage: value.variantId == nil ? "doc.text" : "building.2")
                }
                .accessibilityIdentifier("resume-company")
                .accessibilityLabel("Company")
                .accessibilityValue(value.companyName)
                Menu {
                    ForEach(value.languages, id: \.self) { lang in
                        Button(SummaryLanguage.displayName(for: lang), systemImage: lang == value.language ? "checkmark" : "globe") {
                            select(value.variantId, lang)
                        }
                    }
                } label: {
                    Label(SummaryLanguage.displayName(for: value.language), systemImage: "globe")
                }
                .accessibilityLabel("Language")
                .accessibilityValue(SummaryLanguage.displayName(for: value.language))
                Spacer(minLength: 0)
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 8) {
                ResumeStatChip("Base r\(value.baseRevision)", systemImage: "number", tint: .secondary)
                if value.variantId != nil {
                    if let showOverrides {
                        Button(action: showOverrides) {
                            ResumeStatChip("\(value.overrideCount) overrides", systemImage: "square.on.square", tint: .accentColor)
                        }.buttonStyle(.plain)
                    }
                }
                if !value.reviewPaths.isEmpty {
                    ResumeStatChip("\(value.reviewPaths.count) to review", systemImage: "exclamationmark.bubble", tint: .orange)
                }
                if !value.missingTranslationPaths.isEmpty {
                    ResumeStatChip("\(value.missingTranslationPaths.count) translations", systemImage: "character.bubble", tint: .purple)
                }
            }
        }
    }
}

struct ResumeStatChip: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    init(_ title: LocalizedStringKey, systemImage: String, tint: Color) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: .capsule)
    }
}

/// Large, tappable shortcuts for the most common résumé workflows.
struct ResumeQuickActions: View {
    enum Action: CaseIterable, Identifiable {
        case tailor, export, history, chat
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .tailor: "Tailor"
            case .export: "Export"
            case .history: "History"
            case .chat: "Ask Agent"
            }
        }
        var symbol: String {
            switch self {
            case .tailor: "sparkles"
            case .export: "square.and.arrow.up"
            case .history: "clock.arrow.circlepath"
            case .chat: "bubble.left.and.bubble.right"
            }
        }
        var tint: Color {
            switch self {
            case .tailor: .purple
            case .export: .blue
            case .history: .orange
            case .chat: .green
            }
        }
    }
    let perform: (Action) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
            ForEach(Action.allCases) { action in
                Button { perform(action) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: action.symbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(action.tint)
                            .frame(width: 32, height: 32)
                            .background(action.tint.opacity(0.14), in: .rect(cornerRadius: 9))
                        Text(action.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(.background, in: .rect(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator.opacity(0.6)))
                    .contentShape(.rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The résumé rendered as a printed page: header, contact chips and timeline sections.
struct ResumePaperView: View {
    let document: ResumeDocument
    var avatar: Data?
    var onEdit: (() -> Void)?

    private var contacts: [(String, String)] {
        [(document.contact?.email, "envelope"), (document.contact?.phone, "phone"), (document.contact?.location, "mappin.and.ellipse")]
            .compactMap { value, icon in value?.nilIfBlank.map { ($0, icon) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            if document.sections.isEmpty {
                ContentUnavailableView {
                    Label("No sections yet", systemImage: "doc.badge.plus")
                } description: {
                    Text("Add experience, education and skills to build out this résumé.")
                } actions: {
                    if let onEdit { Button("Edit Résumé", action: onEdit).buttonStyle(.borderedProminent) }
                }
            }
            ForEach(document.sections) { section in
                ResumeSectionView(section: section)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5)))
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                portrait
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.candidateName)
                        .font(.system(.largeTitle, design: .serif, weight: .bold))
                        .textSelection(.enabled)
                    if let headline = document.headline?.nilIfBlank {
                        Text(headline).font(.title3).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if !contacts.isEmpty || !document.links.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(contacts, id: \.0) { value, icon in
                        Label(value, systemImage: icon)
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.fill.tertiary, in: .capsule)
                            .textSelection(.enabled)
                    }
                    ForEach(document.links) { link in
                        if let url = URL(string: link.url) {
                            Link(destination: url) {
                                Label(link.label.nilIfBlank ?? url.host() ?? link.url, systemImage: "link")
                                    .font(.callout)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.accentColor.opacity(0.12), in: .capsule)
                            }
                        }
                    }
                }
            }
            Rectangle().fill(.tint).frame(width: 48, height: 3).clipShape(.capsule)
        }
    }

    @ViewBuilder private var portrait: some View {
        if let image = avatar.flatMap(Self.image(from:)) {
            image.resizable().scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(.circle)
                .overlay(Circle().strokeBorder(.separator))
                .accessibilityLabel("Candidate photo")
        } else {
            Text(initials)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
                .accessibilityHidden(true)
        }
    }

    private var initials: String {
        let parts = document.candidateName.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}

private struct ResumeSectionView: View {
    let section: ResumeDocument.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(section.title.uppercased(), systemImage: section.kind.symbol)
                .font(.footnote.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.tint)
            let chips = section.entries.filter(\.isChip)
            let rows = section.entries.filter { !$0.isChip }
            if !chips.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(chips) { entry in
                        Text(entry.title ?? "")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.fill.tertiary, in: .capsule)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                ResumeEntryRow(entry: entry, isLast: index == rows.count - 1, showsTimeline: section.kind != .profile)
            }
        }
    }
}

private struct ResumeEntryRow: View {
    let entry: ResumeDocument.Entry
    let isLast: Bool
    let showsTimeline: Bool

    private var subtitle: String? {
        let parts = [entry.organization, entry.location].compactMap { $0?.nilIfBlank }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if showsTimeline {
                VStack(spacing: 0) {
                    Circle().fill(entry.current == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 10, height: 10)
                        .padding(.top, 6)
                    if !isLast { Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity) }
                }
                .frame(width: 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        titleBlock
                        Spacer(minLength: 12)
                        dates
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        titleBlock
                        dates
                    }
                }
                if let detail = entry.description?.nilIfBlank {
                    Text(detail).foregroundStyle(.primary.opacity(0.85)).textSelection(.enabled)
                }
                if !entry.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(entry.bullets) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.tint)
                                Text(bullet.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let url = entry.url.flatMap(URL.init(string:)) {
                    Link(destination: url) { Label(url.host() ?? url.absoluteString, systemImage: "arrow.up.right.square") }
                        .font(.callout)
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = entry.title?.nilIfBlank { Text(title).font(.headline) }
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var dates: some View {
        if let range = entry.dateRange {
            Text(range)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.fill.quaternary, in: .capsule)
                .fixedSize()
        }
    }
}

#Preview("Résumé paper") {
    var document = ResumeDocument(candidateName: "Mariam Haddad", headline: "Product Designer")
    var contact = ResumeDocument.Contact()
    contact.email = "mariam@example.com"; contact.location = "Berlin"
    document.contact = contact
    document.links = [.init(label: "Portfolio", url: "https://example.com")]
    var job = ResumeDocument.Entry()
    job.title = "Lead Designer"; job.organization = "Atelier"; job.location = "Remote"
    job.startDate = "2021"; job.current = true
    job.bullets = [.init(text: "Led the design system used by 40 engineers."), .init(text: "Shipped the iOS redesign.")]
    var school = ResumeDocument.Entry()
    school.title = "BA Interaction Design"; school.organization = "UdK Berlin"; school.startDate = "2014"; school.endDate = "2018"
    let skills = ["Figma", "SwiftUI", "Prototyping", "Research"].map { name -> ResumeDocument.Entry in
        var entry = ResumeDocument.Entry(); entry.title = name; return entry
    }
    document.sections = [
        .init(kind: .experience, title: "Experience", entries: [job, school]),
        .init(kind: .skills, title: "Skills", entries: skills),
    ]
    return ScrollView { ResumePaperView(document: document).padding() }.background(.background.secondary)
}
