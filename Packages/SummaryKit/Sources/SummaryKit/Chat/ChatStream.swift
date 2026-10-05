import Foundation

/// One UI message in the AI SDK shape. iOS only ever sends text parts.
public struct ChatUIMessage: Codable, Sendable, Hashable {
    public struct Part: Codable, Sendable, Hashable {
        public var type: String
        public var text: String
        public init(text: String) {
            self.type = "text"
            self.text = text
        }
    }

    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: String
    public var role: Role
    public var parts: [Part]

    public init(id: String = UUID().uuidString, role: Role, text: String) {
        self.id = id
        self.role = role
        self.parts = [Part(text: text)]
    }
}

public struct ChatRequestBody: Codable, Sendable {
    public var messages: [ChatUIMessage]
    /// Focuses the agent on one summary; the server grounds answers in its original text.
    public var summaryId: String?
    /// The text of the summary's linked local file, read on this device for this request only.
    public var localContent: String?
    /// Chats with the trip agent about one of the user's trips; the agent can edit it.
    public var tripId: String?
    public init(messages: [ChatUIMessage], summaryId: String? = nil, localContent: String? = nil, tripId: String? = nil) {
        self.messages = messages
        self.summaryId = summaryId
        self.localContent = localContent
        self.tripId = tripId
    }
}

/// The chunk types iOS understands (docs/ARCHITECTURE.md → Chat stream).
public enum ChatStreamEvent: Sendable, Hashable {
    case textStart(id: String)
    case textDelta(id: String, delta: String)
    case textEnd(id: String)
    case toolInputAvailable(toolCallId: String, toolName: String, input: JSONValue)
    case toolOutputAvailable(toolCallId: String, output: JSONValue)
    case toolOutputError(toolCallId: String, errorText: String)
    case error(String)
    case finish
    /// `data: [DONE]`
    case done
}

/// Incremental SSE parser for the AI SDK UI message stream.
public struct ChatStreamParser: Sendable {
    public init() {}

    /// Parses one line of the SSE body. Returns `nil` for blank lines, comments, other SSE
    /// fields and chunk types iOS ignores.
    public func parse(line rawLine: String) -> ChatStreamEvent? {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload == "[DONE]" { return .done }
        return parse(chunk: String(payload))
    }

    /// Parses one JSON chunk (the value after `data: `).
    public func parse(chunk: String) -> ChatStreamEvent? {
        guard let data = chunk.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = value["type"]?.stringValue else { return nil }
        switch type {
        case "text-start":
            return .textStart(id: value["id"]?.stringValue ?? "")
        case "text-delta":
            return .textDelta(id: value["id"]?.stringValue ?? "", delta: value["delta"]?.stringValue ?? "")
        case "text-end":
            return .textEnd(id: value["id"]?.stringValue ?? "")
        case "tool-input-available":
            return .toolInputAvailable(
                toolCallId: value["toolCallId"]?.stringValue ?? "",
                toolName: value["toolName"]?.stringValue ?? "",
                input: value["input"] ?? .null
            )
        case "tool-output-available":
            return .toolOutputAvailable(toolCallId: value["toolCallId"]?.stringValue ?? "", output: value["output"] ?? .null)
        case "tool-output-error", "tool-input-error":
            return .toolOutputError(toolCallId: value["toolCallId"]?.stringValue ?? "", errorText: value["errorText"]?.stringValue ?? String(localized: "The tool could not finish.", bundle: .module))
        case "error":
            return .error(value["errorText"]?.stringValue ?? String(localized: "Something went wrong.", bundle: .module))
        case "finish":
            return .finish
        default:
            return nil
        }
    }
}

/// Streams `POST /api/v1/chat`.
public final class ChatStreamClient: Sendable {
    let api: SummaryAPIClient

    public init(api: SummaryAPIClient) { self.api = api }

    public func stream(messages: [ChatUIMessage], summaryID: String? = nil, localContent: String? = nil, tripID: String? = nil) -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let api = self.api
        let (stream, continuation) = AsyncThrowingStream<ChatStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                var request = try api.json("/api/v1/chat", method: "POST", body: ChatRequestBody(messages: messages, summaryId: summaryID, localContent: localContent, tripId: tripID))
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 300
                let bytes = try await Self.openStream(api: api, request: request)
                let parser = ChatStreamParser()
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard let event = parser.parse(line: line) else { continue }
                    continuation.yield(event)
                    if event == .done { break }
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                SummaryLog.chat.error("Chat stream ended with error: \(error.logDescription, privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func openStream(api: SummaryAPIClient, request: URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            var request = request
            let token: String
            do {
                token = try await api.tokenProvider.accessToken(forceRefresh: attempt > 0)
            } catch TokenBrokerError.missingSession {
                throw SummaryAPIError.notSignedIn
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            await api.applyBillingProof(to: &request)
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await api.session.bytes(for: request)
            } catch {
                SummaryLog.chat.error("✗ \(request.logDescription, privacy: .public) failed: \(error.logDescription, privacy: .public)")
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw SummaryAPIError.invalidResponse }
            SummaryLog.chat.info("← \(request.logDescription, privacy: .public) \(http.statusCode)")
            if http.statusCode == 401, attempt == 0 {
                attempt += 1
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 64_000 { break }
                }
                try SummaryAPIClient.validate(data: data, response: http)
                throw SummaryAPIError.http(status: http.statusCode)
            }
            return bytes
        }
    }
}

// MARK: - Tool outputs

/// A lightweight summary reference returned by the chat agent's tools.
public struct SummaryReference: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var slug: String?
    public var title: String
    public var summary: String?
    public var category: String?
    public var tags: [String]
    public var siteName: String?
    public var sourceUrl: URL?
    public var shareUrl: URL?
    public var ogImageUrl: URL?
    public var createdAt: Date?
    public var viewedAt: Date?

    public init(id: String, slug: String?, title: String, summary: String?, category: String?, tags: [String], siteName: String?, sourceUrl: URL?, shareUrl: URL?, ogImageUrl: URL?, createdAt: Date?, viewedAt: Date?) {
        self.id = id; self.slug = slug; self.title = title; self.summary = summary
        self.category = category; self.tags = tags; self.siteName = siteName; self.sourceUrl = sourceUrl
        self.shareUrl = shareUrl; self.ogImageUrl = ogImageUrl; self.createdAt = createdAt; self.viewedAt = viewedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? String(localized: "Untitled", bundle: .module)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        tags = (try? c.decodeIfPresent([String].self, forKey: .tags)) ?? []
        siteName = try c.decodeIfPresent(String.self, forKey: .siteName)
        sourceUrl = try c.decodeLenientURL(forKey: .sourceUrl)
        shareUrl = try c.decodeLenientURL(forKey: .shareUrl)
        ogImageUrl = try c.decodeLenientURL(forKey: .ogImageUrl)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        viewedAt = try? c.decodeIfPresent(Date.self, forKey: .viewedAt)
    }
}

public enum ChatToolOutput {
    public static func webReferences(from output: JSONValue) -> [ChatWebReference] {
        guard case .array(let results)? = output["results"] else { return [] }
        var seen = Set<URL>()
        return results.compactMap { result in
            guard let raw = result["url"]?.stringValue, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  seen.insert(url).inserted else { return nil }
            return ChatWebReference(title: result["title"]?.stringValue ?? url.host ?? raw,
                                    url: url, snippet: result["snippet"]?.stringValue,
                                    date: result["date"]?.stringValue)
        }
    }

    public static func renderedUI(from output: JSONValue) -> ChatRenderedUI? {
        guard output["error"] == nil, let ui = output["ui"],
              let result = try? ui.decode(ChatRenderedUI.self),
              !result.title.isEmpty, result.spec.elements[result.spec.root] != nil,
              result.spec.elements.count <= 300 else { return nil }
        return result
    }

    /// Extracts library cards from `searchSummaries` / `listTrips` (`{results:[…]}`) or `getSummary` / `getTrip`
    /// (`{summary:{…}}`) output. Unknown shapes yield an empty list.
    public static func references(from output: JSONValue) -> [SummaryReference] {
        if case .array(let results)? = output["results"] {
            return results.compactMap { try? $0.decode(SummaryReference.self) }
        }
        if let summary = output["summary"], let reference = try? summary.decode(SummaryReference.self) {
            return [reference]
        }
        return []
    }

    /// The query or id a tool call was made with, shown on its card (`nil` when there's nothing to show).
    public static func detail(toolName: String, input: JSONValue) -> String? {
        switch toolName {
        case "searchWeb":
            if let query = input["query"]?.stringValue { return query }
            if case .array(let queries)? = input["query"] {
                return queries.compactMap(\.stringValue).joined(separator: " · ")
            }
            return nil
        case "renderUI":
            return input["title"]?.stringValue
        case "searchSummaries":
            let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let filters = [input["category"]?.stringValue, input["tag"]?.stringValue.map { "#\($0)" }].compactMap { $0 }
            let parts = (query.isEmpty ? [] : ["“\(query)”"]) + filters
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case "grepLocalFile":
            return input["pattern"]?.stringValue.map { "“\($0)”" }
        case "readWebPage":
            return input["url"]?.stringValue.flatMap { URL(string: $0)?.host() }
        case "readLocalFile":
            guard let start = input["startLine"]?.intValue else { return nil }
            return input["endLine"]?.intValue.map { String(localized: "Lines \(start)–\($0)", bundle: .module) } ?? String(localized: "From line \(start)", bundle: .module)
        default:
            return nil
        }
    }

    /// A short result line for the local-file tools, e.g. "3 matches" or "Lines 10–40 of 120".
    public static func localFileStatus(toolName: String, output: JSONValue) -> String? {
        switch toolName {
        case "grepLocalFile":
            guard let total = output["totalMatches"]?.intValue else { return nil }
            return total == 0 ? String(localized: "No matches", bundle: .module) : total == 1 ? String(localized: "1 match", bundle: .module) : String(localized: "\(total) matches", bundle: .module)
        case "readLocalFile":
            guard let start = output["startLine"]?.intValue, let end = output["endLine"]?.intValue,
                  let total = output["totalLines"]?.intValue else { return nil }
            return String(localized: "Lines \(start)–\(end) of \(total)", bundle: .module)
        default:
            return nil
        }
    }

    /// What the trip agent's `updateTrip` call changed: its change summary and how many edits were
    /// saved (`nil` when it was refused and sent back to the agent).
    public static func tripUpdate(from output: JSONValue) -> (summary: String?, applied: Int)? {
        guard output["error"] == nil, let applied = output["applied"]?.intValue else { return nil }
        let summary = output["changeSummary"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (summary?.isEmpty == false ? summary : nil, applied)
    }

    /// Whether a `searchSummaries` output was ranked by meaning (vector search) rather than keywords alone.
    public static func isSemantic(_ output: JSONValue) -> Bool {
        if case .bool(true)? = output["semantic"] { return true }
        return false
    }

    /// The error a tool reported in its output (e.g. `getSummary` on an inaccessible id).
    public static func errorText(from output: JSONValue) -> String? {
        guard let error = output["error"]?.stringValue else { return nil }
        return output["message"]?.stringValue ?? error
    }

    /// Human readable label for an in-flight tool call.
    public static func activityLabel(toolName: String, input: JSONValue) -> String {
        switch toolName {
        case "searchWeb":
            return String(localized: "Searching the web…", bundle: .module)
        case "renderUI":
            return String(localized: "Creating a view…", bundle: .module)
        case "searchSummaries":
            if let query = input["query"]?.stringValue, !query.isEmpty { return String(localized: "Searching for “\(query)”…", bundle: .module) }
            return String(localized: "Searching summaries…", bundle: .module)
        case "getSummary":
            return String(localized: "Reading summary…", bundle: .module)
        case "listTrips":
            return String(localized: "Finding your trips…", bundle: .module)
        case "getTrip":
            return String(localized: "Reading the trip…", bundle: .module)
        case "grepLocalFile":
            return String(localized: "Searching the file…", bundle: .module)
        case "readLocalFile":
            return String(localized: "Reading the file…", bundle: .module)
        case "readWebPage":
            return String(localized: "Reading the page…", bundle: .module)
        case "updateTrip":
            return String(localized: "Updating the trip…", bundle: .module)
        default:
            return String(localized: "Working…", bundle: .module)
        }
    }
}

/// A web result stays separate from the user's saved summaries.
public struct ChatWebReference: Codable, Sendable, Hashable, Identifiable {
    public var title: String
    public var url: URL
    public var snippet: String?
    public var date: String?
    public var id: String { url.absoluteString }

    public init(title: String, url: URL, snippet: String? = nil, date: String? = nil) {
        self.title = title; self.url = url; self.snippet = snippet; self.date = date
    }
}

/// A validated JSON component tree, rendered with the same native catalog as trip views.
public struct ChatRenderedUI: Codable, Sendable, Hashable {
    public var title: String
    public var currency: String
    public var spec: TripViewSpec
}
