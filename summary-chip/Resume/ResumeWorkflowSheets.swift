import SwiftUI
import SummaryKit

extension ResumeEdit {
    var detail: String {
        if let text = value?.stringValue { return text }
        if op == "move" { return "Move after " + (after?.stringValue ?? "start") }
        if let value { return value.resumeDescription }
        return op.capitalized
    }
}

extension JSONValue {
    var resumeDescription: String {
        switch self {
        case .string(let text): text
        case .null: "Remove"
        case .bool(let flag): flag ? "Yes" : "No"
        case .number(let n): n.formatted()
        case .object(let obj): obj["title"]?.stringValue ?? obj["text"]?.stringValue ?? obj["label"]?.stringValue ?? "Item"
        case .array(let list): list.map(\.resumeDescription).joined(separator: ", ")
        }
    }
}

struct ResumeCompanySheet: View {
    let api: SummaryAPIClient
    let source: ResolvedResume
    let onSave: (ResolvedResume) -> Void
    @State private var base: ResolvedResume?
    @State private var differences: [ResumeEdit] = []
    @State private var selected = Set<String>()
    @State private var company = ""
    @State private var role = ""
    @State private var job = ""
    @State private var action = ResumeAction()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Company") {
                    TextField("Company name", text: $company)
                    TextField("Target role", text: $role)
                    TextField("Job description", text: $job, axis: .vertical)
                }
                if !differences.isEmpty {
                    Section("Copy changes from \(source.companyName)") {
                        ForEach(differences.indices, id: \.self) { index in
                            let change = differences[index]
                            let path = change.op == "insert" ? change.path + "/" + (change.value?["id"]?.stringValue ?? "") : change.path
                            Toggle(isOn: selected.binding(for: path, in: $selected)) {
                                Text(path).font(.caption)
                                Text(change.detail)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped).navigationTitle("New Company Variant")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create() }.disabled(company.nilIfBlank == nil || base == nil) }
            }
            .task {
                do {
                    let fresh = try await api.resume(id: source.familyId, language: source.language)
                    if fresh.revisionToken != source.revisionToken {
                        let preview = try await api.previewResumeVariant(source: source.target)
                        differences = preview.operations
                        base = try await api.resume(id: source.familyId, language: source.language, revisionToken: preview.revisionToken)
                    } else { base = fresh }
                } catch { action.error = error.localizedDescription }
            }
        }.resumeFeedback(action).resumeSheet()
    }

    private func create() {
        guard let base else { return }
        action.run("Creating company résumé…") {
            let fresh = try await api.createResumeVariant(base: base.target, company: company, role: role.nilIfBlank, description: job.nilIfBlank,
                source: differences.isEmpty ? nil : source.revisionToken, acceptedPaths: differences.isEmpty ? nil : selected.sorted(),
                idempotencyKey: action.key(for: [base.revisionToken, company, role, job] + selected.sorted()))
            onSave(fresh); dismiss()
        }
    }
}

private extension Set where Element == String {
    func binding(for value: String, in binding: Binding<Self>) -> Binding<Bool> {
        .init(get: { binding.wrappedValue.contains(value) }, set: { selected in
            if selected { binding.wrappedValue.insert(value) } else { binding.wrappedValue.remove(value) }
        })
    }
}

struct ResumeOverridesSheet: View {
    let api: SummaryAPIClient
    @State var resume: ResolvedResume
    let onSave: (ResolvedResume) -> Void
    @State private var differences: [ResumeEdit] = []
    @State private var action = ResumeAction()
    @State private var pending: ResumeEdit?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(resume.recoverablePaths, id: \.self) { path in
                    Section("Removed from base") {
                        Text(path)
                        Button("Keep as Company Content") { pending = .init("keep", path: path) }
                        Button("Discard", role: .destructive) { pending = .init("discard", path: path) }
                    }
                }
                ForEach(resume.overridePaths ?? differences.map(\.path), id: \.self) { path in
                    Section {
                        Text((try? resume.document.value(at: path))?.resumeDescription ?? String(localized: "Hidden in this company"))
                        if resume.reviewPaths.contains(path) { Label("Base value changed", systemImage: "arrow.triangle.2.circlepath") }
                        Button("Use Base Value") { pending = .init("reset", path: path) }
                    } header: { Text(path) }
                }
            }
            .navigationTitle(resume.companyName)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task(id: resume.revisionToken) {
                do {
                    guard resume.overridePaths == nil else { return }
                    let base = try await api.resume(id: resume.familyId, language: resume.language)
                    differences = try resume.document.edits(from: base.document)
                } catch { action.error = error.localizedDescription }
            }
            .confirmationDialog("Apply to this company?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { operation in
                Button("Apply Change") {
                    action.run("Updating company résumé…") {
                        resume = try await api.editResume(target: resume.target, operations: [operation], idempotencyKey: action.key(for: [resume.revisionToken, operation.path, operation.op]))
                        onSave(resume)
                    }
                }
            }
        }.resumeSheet().resumeFeedback(action)
    }
}

struct ResumeProposalSheet: View {
    let api: SummaryAPIClient
    let resume: ResolvedResume
    let onSave: (ResolvedResume) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "review"
    @State private var language = ""
    @State private var proposal: ResumeProposal?
    @State private var selected = Set<String>()
    @State private var action = ResumeAction()

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(resume.companyName); Text(resume.provenance).font(.footnote) }
                if let proposal {
                    if proposal.status == "failed" {
                        Text(proposal.error ?? "Proposal failed")
                    } else if proposal.status != "ready" {
                        ProgressView("Preparing proposal…")
                    } else if let findings = proposal.findings, !findings.isEmpty {
                        ForEach(findings) { finding in
                            Section {
                                Text(finding.rationale)
                                if let source = finding.source { LabeledContent("Source", value: source) }
                                if let current = finding.current { LabeledContent("Current", value: current) }
                                if let operation = finding.operation {
                                    LabeledContent("Proposed", value: operation.detail)
                                    Toggle("Accept change", isOn: selected.binding(for: finding.path, in: $selected))
                                }
                            } header: { Text(finding.path) } footer: {
                                if finding.conflict { Text("The translation was manually edited. Compare both versions before accepting.") }
                            }
                        }
                    } else { Text("No changes proposed.") }
                } else {
                    Picker("Action", selection: $kind) {
                        Text("Review").tag("review")
                        if resume.variantId != nil { Text("Tailor for company").tag("tailor") }
                        Text("Translate or refresh").tag("translate")
                    }
                    if kind == "translate" {
                        Picker("Target language", selection: $language) {
                            ForEach(SummaryLanguage.translations.filter { $0.rawValue != resume.language }) { Text($0.title).tag($0.rawValue) }
                        }
                    }
                    Button("Generate Proposal") {
                        action.run("Preparing proposal…") {
                            proposal = try await api.resumeProposal(target: resume.target, kind: kind, targetLanguage: kind == "translate" ? language : nil,
                                idempotencyKey: action.key(for: [resume.revisionToken, kind, language]))
                        }
                    }
                }
            }
            .formStyle(.grouped).navigationTitle("Résumé Review")
            .onAppear { if language.isEmpty { language = SummaryLanguage.translations.first { $0.rawValue != resume.language }!.rawValue } }
            .task(id: proposal?.id) {
                guard var current = proposal else { return }
                do {
                    while ["queued","running"].contains(current.status) {
                        try await Task.sleep(for: .seconds(3))
                        current = try await api.resumeProposalStatus(id: resume.familyId, proposalId: current.id)
                        proposal = current
                    }
                } catch is CancellationError {} catch { action.error = error.localizedDescription }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if let proposal, proposal.status == "ready" {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply Selected") {
                            action.run("Saving accepted changes…") {
                                let fresh = try await api.applyResumeProposal(target: resume.target, proposalId: proposal.id, acceptedPaths: selected.sorted(),
                                    idempotencyKey: action.key(for: [proposal.id] + selected.sorted()))
                                onSave(fresh); dismiss()
                            }
                        }.disabled(selected.isEmpty)
                    }
                }
            }
        }.resumeSheet().resumeFeedback(action)
    }
}

struct ResumeHistorySheet: View {
    let api: SummaryAPIClient
    let resume: ResolvedResume
    let onSave: (ResolvedResume) -> Void
    @State private var history: [ResumeRevision] = []
    @State private var action = ResumeAction()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(history) { revision in
                NavigationLink {
                    ResumeHistoryDetail(api: api, current: resume, revision: revision) { fresh in onSave(fresh); dismiss() }
                } label: {
                    VStack(alignment: .leading) {
                        Text("\(revision.origin.capitalized) · r\(revision.revision) · \(revision.language)")
                        Text(revision.createdAt.formatted()).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.navigationTitle("Version History")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { do { history = try await api.resumeHistory(target: resume.target) } catch { action.error = error.localizedDescription } }
        }.resumeFeedback(action).resumeSheet()
    }
}

private struct ResumeHistoryDetail: View {
    let api: SummaryAPIClient
    let current: ResolvedResume
    let revision: ResumeRevision
    let onSave: (ResolvedResume) -> Void
    @State private var history: ResolvedResume?
    @State private var preview: JSONValue?
    @State private var confirm = false
    @State private var company = false
    @State private var action = ResumeAction()

    var body: some View {
        List {
            if let history {
                ResumeDocumentContent(document: history.document)
                Button("Create Company Variant…") { company = true }
                Button("Preview Restore…") {
                    action.run("Preparing restore…") { preview = try await api.previewResumeRestore(target: current.target, revisionToken: revision.revisionToken) }
                }
            }
        }.navigationTitle("Revision \(revision.revision)")
        .task {
            do { history = try await api.resume(id: current.familyId, variantId: current.variantId, language: current.language, revisionToken: revision.revisionToken) }
            catch { action.error = error.localizedDescription }
        }
        .sheet(isPresented: $company) {
            if let history { ResumeCompanySheet(api: api, source: history, onSave: onSave) }
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            NavigationStack {
                List {
                    if let preview {
                        if let doc = try? preview["document"]?.decode(ResumeDocument.self) { ResumeDocumentContent(document: doc) }
                        if case .array(let changes) = preview["operations"] {
                            ForEach(changes.indices, id: \.self) { i in Text(changes[i]["path"]?.stringValue ?? changes[i].resumeDescription) }
                        }
                    }
                    if current.variantId == nil {
                        Section("Inheriting companies") { ForEach(current.variants) { Text($0.company) } }
                    }
                }.navigationTitle(current.variantId == nil ? "Restore Base Résumé" : "Restore Company Overrides")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { preview = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Restore") { confirm = true }
                    }
                }
                .confirmationDialog("Append a restored revision?", isPresented: $confirm) {
                    Button("Restore") {
                        action.run("Restoring revision…") {
                            let fresh = try await api.restoreResume(target: current.target, revisionToken: revision.revisionToken,
                                idempotencyKey: action.key(for: [current.revisionToken, revision.revisionToken]))
                            preview = nil; onSave(fresh)
                        }
                    }
                }
            }.resumeFeedback(action).resumeSheet()
        }
        .resumeFeedback(action)
    }
}
