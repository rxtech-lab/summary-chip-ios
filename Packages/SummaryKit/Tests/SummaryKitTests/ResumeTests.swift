import Foundation
import Testing
@testable import SummaryKit

struct ResumeTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "resume", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func multilingualFixtureRoundTripsWithoutInventingFields() throws {
        let data = try fixture()
        let doc = try JSONDecoder().decode(ResumeDocument.self, from: data)
        let encoded = try JSONEncoder().encode(doc)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == JSONDecoder().decode(JSONValue.self, from: data))
        #expect(doc.sections[0].entries[1].startDate == "2018")
        #expect(doc.avatarAssetId == nil)
        #expect(SummaryKind.known.filter { $0 == .resume }.count == 1)
        #expect(SummaryKind(rawValue: "resume") == .resume)
    }

    @Test func draftProducesScopedChangesAndStableMoves() throws {
        let previous = try JSONDecoder().decode(ResumeDocument.self, from: fixture())
        var next = previous
        next.sections[0].entries[0].bullets[0].text = "Nouvelle formulation"
        next.sections[0].entries.reverse()
        let edits = try next.edits(from: previous)
        #expect(edits == [.init("move", path: "/sections/work/entries/job2", after: .null),
                          .init("set", path: "/sections/work/entries/job1/bullets/bullet1/text", value: .string("Nouvelle formulation"))])
        #expect(try next.edits(from: next).isEmpty)
        next.contact = nil
        #expect(try next.edits(from: previous).contains(.init("set", path: "/contact/email", value: .null)))
    }

    @Test func voiceAndTextContextCarryTheSelectedRevision() throws {
        let target = ResumeTarget(familyId: "f", variantId: "acme", language: "fr", revisionToken: "r9")
        let body = ChatRequestBody(messages: [.init(role: .user, text: "Réviser")], resumeTarget: target)
        let saved = try JSONEncoder().encode(body)
        #expect(try JSONDecoder().decode(ChatRequestBody.self, from: saved).resumeTarget == target)
    }
}

extension ResumeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RESUME_HTTP_E2E"] == "1"))
    func authenticatedNativeReleaseFlow() async throws {
        struct Auth: Decodable { let access_token: String }
        var issue = URLRequest(url: URL(string: "http://127.0.0.1:3181/token")!)
        issue.httpMethod = "POST"
        issue.setValue("application/json", forHTTPHeaderField: "Content-Type")
        issue.httpBody = try JSONEncoder().encode(["sub":"resume-local-owner", "clientId":"e2e-client"])
        let (data, _) = try await URLSession.shared.data(for: issue)
        let auth = try JSONDecoder().decode(Auth.self, from: data)
        let api = SummaryAPIClient(baseURL: URL(string: "http://127.0.0.1:3180")!, tokenProvider: StaticTokenProvider(token: auth.access_token),
                                   session: URLSession(configuration: .ephemeral), billingProofProvider: { nil })
        let doc = try JSONDecoder().decode(ResumeDocument.self, from: fixture())
        let base = try await api.createResume(title: "Native cross-check", document: doc, language: "fr", idempotencyKey: UUID().uuidString)
        let a = try await api.createResumeVariant(base: base.target, company: "Atelier", role: nil, description: nil, source: nil, acceptedPaths: nil, idempotencyKey: UUID().uuidString)
        let b = try await api.createResumeVariant(base: base.target, company: "Studio", role: nil, description: nil, source: nil, acceptedPaths: nil, idempotencyKey: UUID().uuidString)
        let edited = try await api.editResume(target: a.target, operations: [.init("set", path:"/headline", value: .string("Ingénieure, Atelier"))], idempotencyKey: UUID().uuidString)
        let preview = try await api.previewResume(target: edited.target, presentation: .init())
        let pdf = try await api.resumeArtifact(path: preview.pdfUrl)
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        let docx = try await api.resumeArtifact(path: preview.docxUrl)
        #expect(docx.starts(with: Data("PK".utf8)))
        let publication = try await api.publishResume(id: base.familyId, previewId: preview.id, access: .anyone, ttlDays: 1, emails: [], replacing: nil,
                                                     acceptedWordingPaths: [], idempotencyKey: UUID().uuidString)
        let updated = try await api.editResume(target: base.target, operations: [.init("set", path:"/headline", value: .string("Nouvelle fonction"))], idempotencyKey: UUID().uuidString)
        let sibling = try await api.resume(id: base.familyId, variantId: b.variantId, language:"fr")
        #expect(sibling.document.headline == updated.document.headline)
        let recipient = try await api.resumePublication(slug: publication.url.lastPathComponent)
        #expect(recipient.document == edited.document)
        #expect(try await api.resumeArtifact(path: recipient.pdfUrl) == pdf)
        let revisions = try await api.resumeHistory(target: edited.target)
        #expect(revisions.contains { $0.origin == "company" })
        let links = try await api.resumePublications(id: base.familyId)
        #expect(links.contains { $0.previewId == preview.id && $0.id == publication.id })
        try await api.deleteShareLink(summaryID: base.familyId, linkID: publication.id)
        do {
            _ = try await api.resumeArtifact(path: recipient.pdfUrl)
            Issue.record("A revoked publication still returned PDF bytes")
        } catch let error as SummaryAPIError { #expect(error.isNotFound) }
    }
}
