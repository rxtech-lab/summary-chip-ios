import Foundation

private struct PaperEnvelope: Decodable { let paper: Paper }
private struct PaperListEnvelope: Decodable { let papers: [PaperListItem] }

/// `POST /api/v1/papers/:id/versions`: the paper after its manual edits were saved as a version.
public struct PaperCommit: Decodable, Sendable, Hashable {
    public var paper: Paper
    /// The version added; nil when nothing changed since the last one.
    public var version: Int?
}

extension SummaryAPIClient {
    /// LaTeX can take a while on a long paper with a bibliography.
    public static let paperCompileTimeout: TimeInterval = 120

    // MARK: Papers

    /// The account's papers, most recently edited first (`GET /api/v1/papers`).
    public func listPapers() async throws -> [PaperListItem] {
        let envelope: PaperListEnvelope = try await send(get("/api/v1/papers"))
        return envelope.papers
    }

    /// A paper's working copy; `id` is its library item's id.
    public func paper(id: String) async throws -> Paper {
        let envelope: PaperEnvelope = try await send(get("/api/v1/papers/\(id.urlPathEscaped)"))
        return envelope.paper
    }

    /// A new paper from a template, as version 1. It designs the paper's cover, so it takes a while.
    public func createPaper(title: String, template: PaperTemplate, compiler: PaperCompiler = .pdflatex, visibility: SummaryVisibility = .private) async throws -> Paper {
        struct Body: Encodable { let title: String; let template: PaperTemplate; let compiler: PaperCompiler; let visibility: SummaryVisibility }
        var request = try json("/api/v1/papers", method: "POST", body: Body(title: title, template: template, compiler: compiler, visibility: visibility))
        request.timeoutInterval = Self.createTimeout
        let envelope: PaperEnvelope = try await send(request)
        return envelope.paper
    }

    /// The editor's autosave of the whole working copy edited at `revision`. Not a version. Fails
    /// with `409 PAPER_REVISION_CONFLICT` (`isPaperRevisionConflict`) when an agent saved since.
    public func savePaper(id: String, source: PaperSource, revision: Int) async throws -> Paper {
        struct Body: Encodable {
            let title: String
            let files: [PaperFile]
            let mainFile: String
            let compiler: PaperCompiler
            let revision: Int
        }
        let body = Body(title: source.title, files: source.files, mainFile: source.mainFile, compiler: source.compiler, revision: revision)
        let envelope: PaperEnvelope = try await send(json("/api/v1/papers/\(id.urlPathEscaped)", method: "PUT", body: body))
        return envelope.paper
    }

    /// Saves the manual edits since the last version as a new one (called when the editor closes).
    @discardableResult
    public func commitPaper(id: String) async throws -> PaperCommit {
        var request = request("/api/v1/papers/\(id.urlPathEscaped)/versions")
        request.httpMethod = "POST"
        return try await send(request)
    }

    /// The working copy (or saved `version`) compiled to a PDF. A compile that produced no PDF
    /// fails with `422 LATEX_COMPILE_FAILED` (`latexIssues`); the service being down is `503`.
    public func paperPDF(id: String, version: Int? = nil) async throws -> PaperPDF {
        var request = request("/api/v1/papers/\(id.urlPathEscaped)/pdf", query: version.map { [URLQueryItem(name: "version", value: String($0))] } ?? [])
        request.setValue("application/pdf, application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.paperCompileTimeout
        let (data, response) = try await authorizedData(for: request)
        try Self.validate(data: data, response: response)
        let revision = (response.value(forHTTPHeaderField: "x-paper-revision")).flatMap(Int.init)
        return PaperPDF(data: data, revision: revision)
    }

    /// Compiles the working copy strictly and lists its LaTeX errors by file and line.
    public func checkPaper(id: String) async throws -> PaperCheck {
        var request = request("/api/v1/papers/\(id.urlPathEscaped)/check")
        request.httpMethod = "POST"
        request.timeoutInterval = Self.paperCompileTimeout
        return try await send(request)
    }

    public func deletePaper(id: String) async throws {
        var request = request("/api/v1/papers/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    /// Uploads raw image bytes to the presigned S3 URL, without forwarding app credentials.
    public func uploadPaperImage(path: String, data: Data) async throws -> PaperFile {
        try PaperLimits.validateImage(path: path, data: data)
        let ext = (path as NSString).pathExtension.lowercased()
        let mimeType = ext == "png" ? "image/png" : ext == "pdf" ? "application/pdf" : "image/jpeg"
        let ticket = try await createUpload(CreateUploadRequest(filename: (path as NSString).lastPathComponent, mimeType: mimeType, byteSize: data.count))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = "PUT"
        put.timeoutInterval = Self.createTimeout
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await session.upload(for: put, from: data)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        return PaperFile(path: path, asset: PaperAsset(key: ticket.key, mimeType: mimeType, byteSize: data.count))
    }

    /// Private preview of an image in the working copy, or in an owner-only saved version.
    public func paperImage(id: String, path: String, version: Int? = nil) async throws -> Data {
        var query = [URLQueryItem(name: "path", value: path)]
        if let version { query.append(URLQueryItem(name: "version", value: String(version))) }
        let (data, response) = try await authorizedData(for: request("/api/v1/papers/\(id.urlPathEscaped)/assets", query: query))
        try Self.validate(data: data, response: response)
        return data
    }
}
