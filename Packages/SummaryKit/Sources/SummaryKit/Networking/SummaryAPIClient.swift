import Foundation

/// A source the user picked before it has been uploaded (PDFs still live on disk).
public enum SummaryInput: Sendable, Hashable {
    case url(URL)
    case webpage(WebpageSource)
    case pdf(fileURL: URL, filename: String, sourceURL: URL?)
    case text(String, title: String?)

    public var displayTitle: String {
        switch self {
        case .url(let url): url.host() ?? url.absoluteString
        case .webpage(let page): page.title ?? page.url.host() ?? page.url.absoluteString
        case .pdf(_, let filename, _): filename
        case .text(let text, let title): title ?? String(text.prefix(80))
        }
    }

    public var systemImage: String {
        switch self {
        case .url, .webpage: "safari"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        }
    }
}

/// Bearer-authenticated client for `/api/v1/*`.
public final class SummaryAPIClient: Sendable {
    public static let maxUploadBytes = 25 * 1024 * 1024
    public static let createTimeout: TimeInterval = 120

    public let baseURL: URL
    let tokenProvider: any AccessTokenProvider
    let session: URLSession

    public init(baseURL: URL, tokenProvider: any AccessTokenProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
    }

    // MARK: Summaries

    public func listSummaries(_ query: SummaryListQuery = .init()) async throws -> SummaryPage {
        try await send(get("/api/v1/summaries", query: query.queryItems))
    }

    public func summary(id: String) async throws -> Summary {
        try await send(get("/api/v1/summaries/\(id.urlPathEscaped)"))
    }

    public func updateSummary(id: String, patch: SummaryPatch) async throws -> Summary {
        try await send(json("/api/v1/summaries/\(id.urlPathEscaped)", method: "PATCH", body: patch))
    }

    public func deleteSummary(id: String) async throws {
        var request = request("/api/v1/summaries/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    public func regenerateImage(id: String, style: ImageStyle) async throws -> Summary {
        var request = try json("/api/v1/summaries/\(id.urlPathEscaped)/image", method: "POST", body: RegenerateImageRequest(imageStyle: style))
        request.timeoutInterval = Self.createTimeout
        return try await send(request)
    }

    public func facets() async throws -> Facets {
        try await send(get("/api/v1/facets"))
    }

    public func recordView(slug: String) async throws -> Summary {
        try await send(json("/api/v1/views", method: "POST", body: RecordViewRequest(slug: slug)))
    }

    // MARK: Account

    public func accountDeletionState() async throws -> AccountDeletionState {
        try await send(get("/api/v1/account/deletion"))
    }

    /// Starts the 7-day grace period. Idempotent: re-requesting keeps the original deadline.
    public func requestAccountDeletion() async throws -> AccountDeletionState {
        var request = request("/api/v1/account/deletion")
        request.httpMethod = "POST"
        return try await send(request)
    }

    public func cancelAccountDeletion() async throws -> AccountDeletionState {
        var request = request("/api/v1/account/deletion")
        request.httpMethod = "DELETE"
        return try await send(request)
    }

    // MARK: Creation

    public func createSummary(_ body: CreateSummaryRequest) async throws -> Summary {
        var request = try json("/api/v1/summaries", method: "POST", body: body)
        request.timeoutInterval = Self.createTimeout
        return try await send(request)
    }

    /// Creates a summary from any input, uploading PDFs first.
    public func createSummary(from input: SummaryInput, options: GenerationOptions, onUploaded: (@Sendable () -> Void)? = nil) async throws -> Summary {
        let source: SummarySource
        switch input {
        case .url(let url): source = .url(url)
        case .webpage(let page): source = .webpage(page)
        case .text(let text, let title): source = .text(text, title: title)
        case .pdf(let fileURL, let filename, let sourceURL):
            let key = try await uploadPDF(fileURL: fileURL, filename: filename)
            onUploaded?()
            source = .pdf(uploadKey: key, filename: filename, sourceUrl: sourceURL)
        }
        return try await createSummary(CreateSummaryRequest(source: source, options: options))
    }

    public func createUpload(_ body: CreateUploadRequest) async throws -> UploadTicket {
        try await send(json("/api/v1/uploads", method: "POST", body: body))
    }

    /// `POST /api/v1/uploads` then `PUT` the file to the presigned URL. Returns the upload key.
    public func uploadPDF(fileURL: URL, filename: String) async throws -> String {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxUploadBytes else { throw SummaryAPIError.fileTooLarge(maxBytes: Self.maxUploadBytes) }
        let ticket = try await createUpload(CreateUploadRequest(filename: filename, mimeType: "application/pdf", byteSize: size))
        var put = URLRequest(url: ticket.uploadUrl)
        put.httpMethod = ticket.method.isEmpty ? "PUT" : ticket.method
        put.timeoutInterval = Self.createTimeout
        for (name, value) in ticket.headers { put.setValue(value, forHTTPHeaderField: name) }
        if put.value(forHTTPHeaderField: "Content-Type") == nil {
            put.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        }
        // Streams from disk: keeps the share extension well below its memory cap.
        let (_, response) = try await session.upload(for: put, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SummaryAPIError.uploadFailed(status: http.statusCode) }
        return ticket.key
    }

    // MARK: Plumbing

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        return request
    }

    func get(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        request(path, query: query)
    }

    func json(_ path: String, method: String, body: some Encodable) throws -> URLRequest {
        var request = request(path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try SummaryJSON.encoder().encode(body)
        return request
    }

    func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await sendRaw(request)
        do {
            return try SummaryJSON.decoder().decode(T.self, from: data)
        } catch {
            throw SummaryAPIError.decoding(String(describing: error))
        }
    }

    /// Adds the bearer token, retries once with a forced refresh on 401, decodes error bodies.
    func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await authorizedData(for: request)
        try Self.validate(data: data, response: response)
        return data
    }

    /// Performs the request with a bearer token; on 401 forces one refresh and retries.
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = try await perform(request, forceRefresh: false)
        guard first.1.statusCode == 401 else { return first }
        return try await perform(request, forceRefresh: true)
    }

    private func perform(_ request: URLRequest, forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let token: String
        do {
            token = try await tokenProvider.accessToken(forceRefresh: forceRefresh)
        } catch TokenBrokerError.missingSession {
            throw SummaryAPIError.notSignedIn
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        return (data, http)
    }

    static func validate(data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if let envelope = try? SummaryJSON.decoder().decode(APIErrorEnvelope.self, from: data) {
            throw SummaryAPIError.server(status: response.statusCode, body: envelope.error)
        }
        throw SummaryAPIError.http(status: response.statusCode)
    }
}

/// Anonymous client for `/api/public/*` (App Clip).
public final class PublicSummaryClient: Sendable {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func summary(slug: String) async throws -> Summary {
        var request = URLRequest(url: baseURL.appending(path: "/api/public/summaries/\(slug.urlPathEscaped)"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        try SummaryAPIClient.validate(data: data, response: http)
        do {
            return try SummaryJSON.decoder().decode(Summary.self, from: data)
        } catch {
            throw SummaryAPIError.decoding(String(describing: error))
        }
    }
}

extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}
