import Foundation

private struct ReviewEnvelope: Decodable { let review: PaperReview }
private struct ReviewListEnvelope: Decodable { let reviews: [PaperReview] }

extension SummaryAPIClient {
    // MARK: Reviews

    /// The owner's review comments on a paper, oldest first; `unresolved` leaves out the finished ones.
    public func paperReviews(id: String, unresolved: Bool = false) async throws -> [PaperReview] {
        let query = unresolved ? [URLQueryItem(name: "status", value: "unresolved")] : []
        let envelope: ReviewListEnvelope = try await send(get("/api/v1/papers/\(id.urlPathEscaped)/reviews", query: query))
        return envelope.reviews
    }

    /// A comment on a selected passage. Pending edits are saved as a version first, so the review
    /// names the source it was made on.
    public func createPaperReview(id: String, draft: PaperReviewDraft) async throws -> PaperReview {
        let envelope: ReviewEnvelope = try await send(json("/api/v1/papers/\(id.urlPathEscaped)/reviews", method: "POST", body: draft))
        return envelope.review
    }

    /// Accepts an addressed review (`.resolved`), asks the agent again (`.open`), or rewords the comment.
    public func updatePaperReview(id: String, reviewId: String, status: PaperReviewStatus? = nil, comment: String? = nil) async throws -> PaperReview {
        struct Body: Encodable { let status: String?; let comment: String? }
        let body = Body(status: status?.rawValue, comment: comment)
        let envelope: ReviewEnvelope = try await send(json("/api/v1/papers/\(id.urlPathEscaped)/reviews/\(reviewId.urlPathEscaped)", method: "PATCH", body: body))
        return envelope.review
    }

    public func deletePaperReview(id: String, reviewId: String) async throws {
        var request = request("/api/v1/papers/\(id.urlPathEscaped)/reviews/\(reviewId.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    // MARK: Figures

    /// One TikZ or pgfplots figure of the paper drawn by LaTeX on its own, as a cropped PDF, for
    /// the native reader. A figure that doesn't compile fails with `422 LATEX_COMPILE_FAILED`.
    public func paperFigure(id: String, source: String, version: Int? = nil) async throws -> Data {
        struct Body: Encodable { let source: String; let version: Int? }
        var request = try json("/api/v1/papers/\(id.urlPathEscaped)/figures", method: "POST", body: Body(source: source, version: version))
        request.setValue("application/pdf, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.paperCompileTimeout
        let (data, response) = try await authorizedData(for: request)
        try Self.validate(data: data, response: response)
        return data
    }
}
