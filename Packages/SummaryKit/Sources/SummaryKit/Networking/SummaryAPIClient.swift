import Foundation
import StoreKit

/// A source the user picked before it has been uploaded (PDFs still live on disk).
public enum SummaryInput: Sendable, Hashable {
    case url(URL)
    case webpage(WebpageSource)
    case pdf(fileURL: URL, filename: String, sourceURL: URL?)
    case text(String, title: String?)
    /// Read on the device; only its text is sent, and the server doesn't keep it.
    case localFile(LocalFileSource)

    public var displayTitle: String {
        switch self {
        case .url(let url): url.host() ?? url.absoluteString
        case .webpage(let page): page.title ?? page.url.host() ?? page.url.absoluteString
        case .pdf(_, let filename, _): filename
        case .text(let text, let title): title ?? String(text.prefix(80))
        case .localFile(let file): file.filename
        }
    }

    public var systemImage: String {
        switch self {
        case .url, .webpage: "safari"
        case .pdf: "doc.richtext"
        case .text: "text.alignleft"
        case .localFile(let file): file.kind == .pdf ? "doc.richtext" : "doc.text"
        }
    }
}

enum StoreKitBillingProof: Sendable {
    case xcode
    case appleSigned(String)
}

/// Bearer-authenticated client for `/api/v1/*`.
public final class SummaryAPIClient: Sendable {
    public static let maxUploadBytes = 25 * 1024 * 1024
    public static let createTimeout: TimeInterval = 120
    /// Matches the import route's `maxDuration`.
    public static let importTimeout: TimeInterval = 180

    public let baseURL: URL
    let tokenProvider: any AccessTokenProvider
    let session: URLSession
    private let billingProofProvider: @Sendable () async -> StoreKitBillingProof?
    /// Reads a page the server couldn't, on the device. Nil: the server's error stands.
    private let pageReader: PageReader?

    public typealias PageReader = @Sendable (URL) async throws -> WebpageSource

    public convenience init(baseURL: URL, tokenProvider: any AccessTokenProvider, session: URLSession = .shared) {
        self.init(baseURL: baseURL, tokenProvider: tokenProvider, session: session, billingProofProvider: Self.liveBillingProof) { url in
            try await WebPageReader.read(url)
        }
    }

    init(
        baseURL: URL,
        tokenProvider: any AccessTokenProvider,
        session: URLSession,
        billingProofProvider: @escaping @Sendable () async -> StoreKitBillingProof?,
        pageReader: PageReader? = nil
    ) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.session = session
        self.billingProofProvider = billingProofProvider
        self.pageReader = pageReader
    }

    private static func liveBillingProof() async -> StoreKitBillingProof? {
        guard let proof = try? await AppTransaction.shared,
              case .verified(let transaction) = proof else { return nil }
        if transaction.environment == .xcode {
            #if DEBUG
            return .xcode
            #else
            return nil
            #endif
        }
        return .appleSigned(proof.jwsRepresentation)
    }

    // MARK: Summaries

    public func listSummaries(_ query: SummaryListQuery = .init()) async throws -> SummaryPage {
        try await send(get("/api/v1/summaries", query: query.queryItems))
    }

    public func summary(id: String) async throws -> Summary {
        try await send(get("/api/v1/summaries/\(id.urlPathEscaped)"))
    }

    /// The summary's source rewritten as Markdown. Fails with `404 SOURCE_NOT_KEPT` when it wasn't kept.
    public func sourceMarkdown(id: String) async throws -> String {
        try await sourceDocument(id: id).markdown
    }

    /// The source document in the language the summary is read in, once translated (see `translationPending`).
    public func sourceDocument(id: String) async throws -> SourceMarkdown {
        try await send(get("/api/v1/summaries/\(id.urlPathEscaped)/markdown"))
    }

    /// The languages the summary is already translated into; nothing is translated by asking.
    public func translations(id: String) async throws -> SummaryTranslations {
        try await send(get("/api/v1/summaries/\(id.urlPathEscaped)/translations"))
    }

    public func updateSummary(id: String, patch: SummaryPatch) async throws -> Summary {
        try await send(json("/api/v1/summaries/\(id.urlPathEscaped)", method: "PATCH", body: patch))
    }

    public func deleteSummary(id: String) async throws {
        var request = request("/api/v1/summaries/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    /// Stars (`liked`) or unstars a summary; returns when it was starred, nil once unstarred.
    public func setLiked(id: String, liked: Bool) async throws -> Date? {
        struct Like: Decodable { let likedAt: Date? }
        var request = request("/api/v1/summaries/\(id.urlPathEscaped)/like")
        request.httpMethod = liked ? "PUT" : "DELETE"
        let like: Like = try await send(request)
        return like.likedAt
    }

    public func regenerateImage(id: String, style: ImageStyle) async throws -> Summary {
        var request = try json("/api/v1/summaries/\(id.urlPathEscaped)/image", method: "POST", body: RegenerateImageRequest(imageStyle: style))
        request.timeoutInterval = Self.createTimeout
        return try await send(request)
    }

    public func facets() async throws -> Facets {
        try await send(get("/api/v1/facets"))
    }

    /// One facet list whose names contain `query`, paged.
    public func facets(kind: FacetKind, query: String? = nil, cursor: String? = nil, limit: Int = 10) async throws -> FacetPage {
        var items = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "limit", value: String(limit))]
        if let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(get("/api/v1/facets", query: items))
    }

    public func recordView(slug: String) async throws -> Summary {
        try await send(json("/api/v1/views", method: "POST", body: RecordViewRequest(slug: slug)))
    }

    // MARK: Account

    public func registerPushDevice(installationId: String, token: String, environment: String, platform: String) async throws {
        struct Registration: Encodable { let installationId: String; let token: String; let environment: String; let platform: String }
        _ = try await sendRaw(json("/api/v1/devices", method: "POST", body: Registration(installationId: installationId, token: token, environment: environment, platform: platform)))
    }

    public func unregisterPushDevice(installationId: String) async throws {
        struct Installation: Encodable { let installationId: String }
        _ = try await sendRaw(json("/api/v1/devices", method: "DELETE", body: Installation(installationId: installationId)))
    }

    public func billingConnection() async throws -> BillingConnection {
        try await send(get("/api/v1/billing"))
    }

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

    // MARK: MCP

    /// The hosted MCP server agents connect to with an API key.
    public var mcpEndpoint: URL { baseURL.appending(path: "/api/mcp") }

    /// The account's MCP API keys with their usage, newest first.
    public func apiKeys() async throws -> [APIKey] {
        struct Page: Decodable { let items: [APIKey] }
        let page: Page = try await send(get("/api/v1/api-keys"))
        return page.items
    }

    public func createAPIKey(name: String) async throws -> CreatedAPIKey {
        try await send(json("/api/v1/api-keys", method: "POST", body: APIKeyName(name: name)))
    }

    public func renameAPIKey(id: String, name: String) async throws -> APIKey {
        try await send(json("/api/v1/api-keys/\(id.urlPathEscaped)", method: "PATCH", body: APIKeyName(name: name)))
    }

    /// Agents using the key are refused from their next request on.
    public func revokeAPIKey(id: String) async throws {
        var request = request("/api/v1/api-keys/\(id.urlPathEscaped)")
        request.httpMethod = "DELETE"
        _ = try await sendRaw(request)
    }

    private struct APIKeyName: Encodable { let name: String }

    // MARK: Creation

    public func createSummary(_ body: CreateSummaryRequest) async throws -> Summary {
        var request = try json("/api/v1/summaries", method: "POST", body: body)
        request.timeoutInterval = Self.createTimeout
        return try await send(request)
    }

    /// Creates a summary from any input, uploading PDFs first. `followLinks: false` summarises
    /// shared text as-is instead of reading a link inside it.
    public func createSummary(
        from input: SummaryInput,
        options: GenerationOptions,
        followLinks: Bool = true,
        onUploaded: (@Sendable () -> Void)? = nil
    ) async throws -> Summary {
        let source = try await source(for: input, onUploaded: onUploaded)
        return try await createSummary(source, options: options, followLinks: followLinks)
    }

    /// The contract `source` for an input, uploading a PDF first.
    func source(for input: SummaryInput, onUploaded: (@Sendable () -> Void)? = nil) async throws -> SummarySource {
        switch input {
        case .url(let url): return .url(url)
        case .webpage(let page): return .webpage(page)
        case .text(let text, let title): return .text(text, title: title)
        case .localFile(let file): return .local(file)
        case .pdf(let fileURL, let filename, let sourceURL):
            let key = try await uploadPDF(fileURL: fileURL, filename: filename)
            onUploaded?()
            return .pdf(uploadKey: key, filename: filename, sourceUrl: sourceURL)
        }
    }

    /// Links are read on the server first (plain fetch, then its headless browser). When it can't
    /// read the page it answers `SOURCE_NEEDS_DEVICE`; the page is then read in a web view here and
    /// sent as a `webpage`. When the device can't read it either, `UnreadablePageError` lets the UI
    /// offer opening the page in Safari and sharing it to Chippy from there.
    private func createSummary(_ source: SummarySource, options: GenerationOptions, followLinks: Bool) async throws -> Summary {
        do {
            return try await createSummary(CreateSummaryRequest(
                source: source, options: options, deviceReader: pageReader != nil, followLinks: followLinks))
        } catch let error as SummaryAPIError {
            guard let pageReader, let url = error.deviceReadURL else { throw error }
            SummaryLog.api.notice("Server could not read \(url.absoluteString, privacy: .private); reading it on the device")
            let page: WebpageSource
            do {
                page = try await pageReader(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let readError {
                SummaryLog.api.error("On-device read failed: \(readError.logDescription, privacy: .public)")
                throw UnreadablePageError(url: url, reason: readError.localizedDescription)
            }
            return try await createSummary(CreateSummaryRequest(source: .webpage(page), options: options, deviceReader: true))
        }
    }

    /// Saves a summary written elsewhere. A chip already in the library fails with `409 DUPLICATE_SUMMARY`
    /// (`details.duplicate` is the existing summary) unless `allowDuplicate` is set.
    public func importSummary(_ body: ImportSummaryRequest) async throws -> Summary {
        var request = try json("/api/v1/summaries/import", method: "POST", body: body)
        // The server checks for duplicates with a model and designs the cover before answering.
        request.timeoutInterval = Self.importTimeout
        return try await send(request)
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
        // Presigned URL: log host only, the query carries the signature.
        let uploadHost = ticket.uploadUrl.host() ?? "?"
        SummaryLog.api.info("→ upload \(filename, privacy: .private) (\(size) bytes) to \(uploadHost, privacy: .public)")
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: put, fromFile: fileURL)
        } catch {
            SummaryLog.api.error("✗ upload to \(uploadHost, privacy: .public) failed: \(error.logDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            SummaryLog.api.error("← upload to \(uploadHost, privacy: .public) returned \(http.statusCode)")
            throw SummaryAPIError.uploadFailed(status: http.statusCode)
        }
        return ticket.key
    }

    // MARK: Plumbing

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Others' summaries come back translated into the user's language.
        request.setValue(Locale.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        request.setAppVersionHeaders()
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
            SummaryLog.api.error("Decoding \(String(describing: T.self), privacy: .public) failed for \(request.logDescription, privacy: .public): \(String(describing: error), privacy: .public)")
            throw SummaryAPIError.decoding(String(describing: error))
        }
    }

    /// Adds the bearer token, retries once with a forced refresh on 401, decodes error bodies.
    func sendRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await authorizedData(for: request)
        try Self.validate(data: data, response: response)
        return data
    }

    /// Tells the server which StoreKit environment's points to use, on the requests that spend or show them.
    func applyBillingProof(to request: inout URLRequest) async {
        let path = request.url?.path
        guard path == "/api/v1/billing" ||
            (request.httpMethod == "POST" && (path == "/api/v1/summaries" || path == "/api/v1/summaries/import" || path == "/api/v1/chat"
                || Self.isTripIngestPath(path))),
            let proof = await billingProofProvider() else { return }
        switch proof {
        case .xcode:
            // Xcode signs locally; the server authorizes the authenticated test account.
            request.setValue("xcode", forHTTPHeaderField: "x-storekit-environment")
        case .appleSigned(let signature):
            request.setValue(signature, forHTTPHeaderField: "x-storekit-app-transaction")
        }
    }

    /// Performs the request with a bearer token; on 401 forces one refresh and retries.
    func authorizedData(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = try await perform(request, forceRefresh: false)
        guard first.1.statusCode == 401 else { return first }
        SummaryLog.api.notice("401 for \(request.logDescription, privacy: .public); refreshing token and retrying")
        return try await perform(request, forceRefresh: true)
    }

    private func perform(_ request: URLRequest, forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        var request = request
        let token: String
        do {
            token = try await tokenProvider.accessToken(forceRefresh: forceRefresh)
        } catch TokenBrokerError.missingSession {
            SummaryLog.api.notice("\(request.logDescription, privacy: .public) skipped: not signed in")
            throw SummaryAPIError.notSignedIn
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        await applyBillingProof(to: &request)
        let label = request.logDescription
        let clock = ContinuousClock.now
        SummaryLog.api.debug("→ \(label, privacy: .public)\(forceRefresh ? " (retry after token refresh)" : "", privacy: .public)")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SummaryLog.api.error("✗ \(label, privacy: .public) failed after \(clock.duration(to: .now), privacy: .public): \(error.logDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            SummaryLog.api.error("✗ \(label, privacy: .public): non-HTTP response")
            throw SummaryAPIError.invalidResponse
        }
        let elapsed = clock.duration(to: .now)
        if (200..<300).contains(http.statusCode) {
            SummaryLog.api.info("← \(label, privacy: .public) \(http.statusCode) in \(elapsed, privacy: .public), \(data.count) bytes")
        } else {
            SummaryLog.api.error("← \(label, privacy: .public) \(http.statusCode) in \(elapsed, privacy: .public): \(String(decoding: data.prefix(500), as: UTF8.self), privacy: .public)")
        }
        return (data, http)
    }

    static func validate(data: Data, response: HTTPURLResponse) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if let envelope = try? SummaryJSON.decoder().decode(APIErrorEnvelope.self, from: data) {
            let error = SummaryAPIError.server(status: response.statusCode, body: envelope.error)
            AppUpdateCenter.report(error)
            throw error
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
        request.setValue(Locale.acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        request.setAppVersionHeaders()
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            SummaryLog.api.error("✗ \(request.logDescription, privacy: .public) failed: \(error.logDescription, privacy: .public)")
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
        SummaryLog.api.info("← \(request.logDescription, privacy: .public) \(http.statusCode)")
        try SummaryAPIClient.validate(data: data, response: http)
        do {
            return try SummaryJSON.decoder().decode(Summary.self, from: data)
        } catch {
            SummaryLog.api.error("Decoding public Summary failed: \(String(describing: error), privacy: .public)")
            throw SummaryAPIError.decoding(String(describing: error))
        }
    }
}

extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }
}

extension Locale {
    /// `Accept-Language` for the user's preferred languages, most preferred first (`ja-JP, en-US;q=0.9`).
    /// The server shows shared summaries in the first one it can translate into.
    static var acceptLanguageHeader: String {
        Locale.preferredLanguages.prefix(6).enumerated().map { index, tag in
            index == 0 ? tag : "\(tag);q=\(String(format: "%.1f", 1 - Double(index) * 0.1))"
        }.joined(separator: ", ")
    }
}
