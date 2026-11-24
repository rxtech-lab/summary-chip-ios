import Foundation

extension SummaryAPIClient {
    private func resumePath(_ id: String) -> String { "/api/v1/resumes/\(id.urlPathEscaped)" }

    public func resume(id: String, variantId: String? = nil, language: String? = nil, revisionToken: String? = nil) async throws -> ResolvedResume {
        let query = ["variantId": variantId, "language": language, "revisionToken": revisionToken]
            .compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        return try await send(get(resumePath(id), query: query))
    }

    public func createResume(title: String, document: ResumeDocument, language: String, idempotencyKey: String) async throws -> ResolvedResume {
        struct Body: Encodable { let title: String; let document: ResumeDocument; let language, idempotencyKey: String }
        return try await send(json("/api/v1/resumes", method: "POST", body: Body(title: title, document: document, language: language, idempotencyKey: idempotencyKey)))
    }

    public func editResume(target: ResumeTarget, operations: [ResumeEdit], idempotencyKey: String) async throws -> ResolvedResume {
        struct Body: Encodable { let variantId: String?; let language, expectedRevisionToken, idempotencyKey: String; let operations: [ResumeEdit] }
        return try await send(json(resumePath(target.familyId) + "/operations", method: "POST", body: Body(variantId: target.variantId,
            language: target.language, expectedRevisionToken: target.revisionToken, idempotencyKey: idempotencyKey, operations: operations)))
    }

    public func createResumeVariant(base: ResumeTarget, company: String, role: String?, description: String?, source: String?, acceptedPaths: [String]?, idempotencyKey: String) async throws -> ResolvedResume {
        struct Body: Encodable {
            let company: String; let targetRole, jobDescription, sourceRevisionToken: String?
            let acceptedPaths: [String]?; let language, expectedRevisionToken, idempotencyKey: String
        }
        return try await send(json(resumePath(base.familyId) + "/variants", method: "POST", body: Body(company: company,
            targetRole: role, jobDescription: description, sourceRevisionToken: source, acceptedPaths: acceptedPaths,
            language: base.language, expectedRevisionToken: base.revisionToken, idempotencyKey: idempotencyKey)))
    }

    public func previewResumeVariant(source: ResumeTarget) async throws -> ResumeVariantPreview {
        struct Body: Encodable { let sourceRevisionToken, language: String }
        return try await send(json(resumePath(source.familyId) + "/variants/preview", method: "POST",
                                   body: Body(sourceRevisionToken: source.revisionToken, language: source.language)))
    }

    public func viewedResumePublications() async throws -> [ViewedResumePublication] {
        struct Envelope: Decodable { let items: [ViewedResumePublication] }
        let result: Envelope = try await send(get("/api/v1/resumes/publications/viewed"))
        return result.items
    }

    public func resumePublications(id: String) async throws -> [ResumePublishedLink] {
        struct Envelope: Decodable { let items: [ResumePublishedLink] }
        let result: Envelope = try await send(get(resumePath(id) + "/publications"))
        return result.items
    }

    public func resumeHistory(target: ResumeTarget) async throws -> [ResumeRevision] {
        var query = [URLQueryItem(name: "language", value: target.language)]
        if let variant = target.variantId { query.append(URLQueryItem(name: "variantId", value: variant)) }
        struct Envelope: Decodable { let history: [ResumeRevision] }
        let result: Envelope = try await send(get(resumePath(target.familyId) + "/history", query: query))
        return result.history
    }

    public func previewResumeRestore(target: ResumeTarget, revisionToken: String) async throws -> JSONValue {
        struct Body: Encodable { let variantId: String?; let language, revisionToken: String }
        return try await send(json(resumePath(target.familyId) + "/restore-preview", method: "POST",
                                   body: Body(variantId: target.variantId, language: target.language, revisionToken: revisionToken)))
    }

    public func restoreResume(target: ResumeTarget, revisionToken: String, idempotencyKey: String) async throws -> ResolvedResume {
        struct Body: Encodable { let variantId: String?; let language, revisionToken, expectedRevisionToken, idempotencyKey: String }
        return try await send(json(resumePath(target.familyId) + "/restore", method: "POST",
                                   body: Body(variantId: target.variantId, language: target.language, revisionToken: revisionToken,
                                              expectedRevisionToken: target.revisionToken, idempotencyKey: idempotencyKey)))
    }

    public func resumeProposal(target: ResumeTarget, kind: String, targetLanguage: String?, idempotencyKey: String) async throws -> ResumeProposal {
        struct Body: Encodable { let kind, language: String; let variantId, targetLanguage: String?; let expectedRevisionToken, idempotencyKey: String }
        var request = try json(resumePath(target.familyId) + "/proposals", method: "POST",
                               body: Body(kind: kind, language: target.language, variantId: target.variantId, targetLanguage: targetLanguage,
                                          expectedRevisionToken: target.revisionToken, idempotencyKey: idempotencyKey))
        request.timeoutInterval = Self.createTimeout
        await applyBillingProof(to: &request)
        return try await send(request)
    }

    public func resumeProposalStatus(id: String, proposalId: String) async throws -> ResumeProposal {
        try await send(get(resumePath(id) + "/proposals/" + proposalId.urlPathEscaped))
    }

    public func applyResumeProposal(target: ResumeTarget, proposalId: String, acceptedPaths: [String], idempotencyKey: String) async throws -> ResolvedResume {
        struct Body: Encodable { let acceptedPaths: [String]; let expectedRevisionToken, idempotencyKey: String }
        return try await send(json(resumePath(target.familyId) + "/proposals/" + proposalId.urlPathEscaped + "/apply", method: "POST",
                                   body: Body(acceptedPaths: acceptedPaths, expectedRevisionToken: target.revisionToken, idempotencyKey: idempotencyKey)))
    }

    public func previewResume(target: ResumeTarget, presentation: ResumePresentation) async throws -> ResumePreview {
        struct Body: Encodable { let language: String; let variantId: String?; let revisionToken: String; let presentation: ResumePresentation }
        var request = try json(resumePath(target.familyId) + "/preview", method: "POST",
                               body: Body(language: target.language, variantId: target.variantId, revisionToken: target.revisionToken, presentation: presentation))
        request.timeoutInterval = Self.createTimeout
        return try await send(request)
    }

    public func resumeArtifact(path: String) async throws -> Data {
        guard path.hasPrefix("/api/v1/resumes/") || path.hasPrefix("/s/") else { throw SummaryAPIError.invalidResponse }
        var request = get(path)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await sendRaw(request)
    }

    public func resumePublication(slug: String) async throws -> ResumePublication {
        var request = get("/s/\(slug.urlPathEscaped)/resume.json")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await send(request)
    }

    public func publishResume(id: String, previewId: String, access: ShareLinkAccess, ttlDays: Int, emails: [String], replacing: ResumePublishedLink?, acceptedWordingPaths: [String], idempotencyKey: String) async throws -> SummaryShareLink {
        struct Body: Encodable { let previewId: String; let access: ShareLinkAccess; let ttlDays: Int; let emails: [String]; let linkId, expectedPreviewId: String?; let acceptedWordingPaths: [String]; let idempotencyKey: String }
        return try await send(json(resumePath(id) + "/publications", method: "POST",
                                   body: Body(previewId: previewId, access: access, ttlDays: ttlDays, emails: emails, linkId: replacing?.id, expectedPreviewId: replacing?.previewId, acceptedWordingPaths: acceptedWordingPaths, idempotencyKey: idempotencyKey)))
    }

    public func uploadResumeAvatar(id: String, data: Data, filename: String, mimeType: String,
                                   progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> String {
        let ticket: UploadTicket = try await send(json(resumePath(id) + "/assets/upload", method: "POST",
                                                      body: CreateUploadRequest(filename: filename, mimeType: mimeType, byteSize: data.count)))
        try await uploadDocumentData(data, ticket: ticket, progress: progress)
        struct Body: Encodable { let uploadId: String }
        struct Asset: Decodable { let id: String }
        let result: Asset = try await send(json(resumePath(id) + "/assets", method: "POST", body: Body(uploadId: ticket.key)))
        return result.id
    }
}
