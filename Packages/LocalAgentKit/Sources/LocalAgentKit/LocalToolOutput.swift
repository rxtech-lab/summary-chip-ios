import Foundation

/// Translates what a local agent's tools return into what the chat transcript and open documents expect.
public enum LocalToolOutput {
    /// `mcp__chippy_app__search_summaries` becomes `searchSummaries`, the name the transcript has labels for.
    public static func chatToolName(_ name: String) -> String {
        let parts = displayToolName(name).split(separator: "_")
        guard let first = parts.first, parts.count > 1 else { return name }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    /// JSON for the transcript. Chippy's MCP tools can return a sentence before their JSON, and
    /// an agent's own tools usually return plain text, which gets wrapped.
    public static func chatOutput(toolName: String, output: String) -> Data {
        let output = mcpText(in: output) ?? output
        guard var payload = payload(in: output) else {
            return (try? JSONSerialization.data(withJSONObject: ["text": output])) ?? Data("{}".utf8)
        }
        // The hosted tool saves the selection for the next load and reports it as `selection`.
        // The cloud agent's `graphSelection` is what makes the open graph show it right away.
        if toolName == "selectGraphElements", let selection = payload["selection"] {
            payload["graphSelection"] = selection
        }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// Whether this tool changes a document that's probably open, so it should reload.
    public static func changesOpenDocument(toolName: String) -> Bool {
        toolName.hasPrefix("update") || toolName.hasPrefix("addToTrip")
            || toolName == "choosePlanOption" || toolName == "restoreVersion"
    }

    /// Codex reports a whole MCP result, `{"content":[{"type":"text","text":"…"}]}`, rather than its text.
    private static func mcpText(in output: String) -> String? {
        guard let content = object(output)?["content"] as? [[String: Any]] else { return nil }
        let text = content.compactMap { $0["text"] as? String }
        return text.isEmpty ? nil : text.joined(separator: "\n")
    }

    private static func payload(in output: String) -> [String: Any]? {
        if let whole = object(output) { return whole }
        // Text blocks arrive joined by newlines, and Chippy's JSON is always the last one.
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            if let found = object(String(line)) { return found }
        }
        return nil
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
