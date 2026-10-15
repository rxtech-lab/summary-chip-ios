import Foundation

/// Calls keyless (`auth: {"type":"none"}`) connector operations straight from the device, so public
/// APIs see the user's network rather than Chippy's server. Connectors with credentials stay brokered
/// by the server; their secrets never reach the device.
public enum MiniAppPublicAPI {
    public static let responseLimit = 1024 * 1024

    public enum Failure: LocalizedError, Equatable {
        case unavailable(String)
        case invalidInput(String)
        case http(Int)
        case invalidResponse
        case tooLarge

        public var errorDescription: String? {
            switch self {
            case .unavailable(let name): "API operation \(name) is unavailable."
            case .invalidInput(let field): "Invalid API input: \(field)."
            case .http(let status): "The API returned HTTP \(status)."
            case .invalidResponse: "The API did not return supported JSON."
            case .tooLarge: "The API response exceeds 1 MiB."
            }
        }
    }

    /// Whether this connector can be called from the device.
    public static func isPublic(_ connector: JSONValue?) -> Bool {
        connector?["auth"]?["type"]?.stringValue == "none"
    }

    public static func call(connector: JSONValue?, operation: String, input: JSONValue, session: URLSession = .shared) async throws -> JSONValue {
        let request = try makeRequest(connector: connector, operation: operation, input: input)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(status) else { throw Failure.http(status) }
        guard data.count <= responseLimit else { throw Failure.tooLarge }
        guard !data.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) else { return .null }
        do { return try JSONDecoder().decode(JSONValue.self, from: data) } catch { throw Failure.invalidResponse }
    }

    /// Mirrors the server broker: one fixed HTTPS origin, declared inputs only, GET inputs as query
    /// parameters and a JSON body for other methods.
    static func makeRequest(connector: JSONValue?, operation: String, input: JSONValue) throws -> URLRequest {
        guard isPublic(connector), let op = connector?["operations"]?[operation],
              let originText = connector?["origin"]?.stringValue, let origin = URL(string: originText), origin.scheme == "https",
              let method = op["method"]?.stringValue, ["GET", "POST", "PUT", "PATCH", "DELETE"].contains(method),
              let path = op["path"]?.stringValue, let url = URL(string: path, relativeTo: origin)?.absoluteURL,
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port
        else { throw Failure.unavailable(operation) }
        let values = try validate(input, fields: op["input"]?.miniObject ?? [:])

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "GET" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = (components?.percentEncodedQueryItems ?? []).filter { item in values[item.name] == nil }
            for (key, value) in values.sorted(by: { $0.key < $1.key }) where value != .null {
                items.append(URLQueryItem(name: encode(key), value: encode(queryText(value))))
            }
            components?.percentEncodedQueryItems = items.isEmpty ? nil : items
            guard let final = components?.url else { throw Failure.unavailable(operation) }
            request.url = final
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(JSONValue.object(values))
        }
        return request
    }

    private static func validate(_ input: JSONValue, fields: [String: JSONValue]) throws -> [String: JSONValue] {
        let values: [String: JSONValue]
        switch input {
        case .object(let object): values = object
        case .null: values = [:]
        default: throw Failure.invalidInput("input")
        }
        if let unknown = values.keys.first(where: { fields[$0] == nil }) { throw Failure.invalidInput(unknown) }
        for (name, field) in fields {
            let value = values[name] ?? .null
            if value == .null {
                if field["required"]?.miniTruth == true { throw Failure.invalidInput(name) }
                continue
            }
            let valid = switch field["type"]?.stringValue {
            case "number": value.miniNumberLiteral != nil
            case "boolean": value.miniBoolLiteral != nil
            case "json": true
            default: value.stringValue != nil
            }
            if !valid { throw Failure.invalidInput(name) }
        }
        return values
    }

    /// Matches JavaScript's `String(value)` closely enough for query parameters: `1`, not `1.0`.
    static func queryText(_ value: JSONValue) -> String {
        switch value {
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
            return "\(number)"
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let text): return text
        case .null: return ""
        case .object, .array: return String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? ""
        }
    }

    /// `+` and `&` are escaped so servers don't read them as a space or separator.
    private static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

private extension JSONValue {
    var miniNumberLiteral: Double? { if case .number(let value) = self, value.isFinite { value } else { nil } }
    var miniBoolLiteral: Bool? { if case .bool(let value) = self { value } else { nil } }
}
