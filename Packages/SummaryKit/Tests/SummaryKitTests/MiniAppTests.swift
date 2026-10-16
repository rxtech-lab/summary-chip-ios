import Foundation
import Testing
@testable import SummaryKit

struct MiniAppTests {
    @Test func definitionRoundTripAndKind() throws {
        let original = MiniAppDocument.blank(title: "Tracker")
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(MiniAppDocument.self, from: data) == original)
        #expect(try JSONDecoder().decode(SummaryKind.self, from: Data("\"mini_app\"".utf8)) == .miniApp)
    }
    @Test func expressionsAndSafeNestedBindings() {
        var state: [String: JSONValue] = [:]
        MiniAppExpression.write(&state, path: "form.title", value: .string("Keep me"))
        #expect(MiniAppExpression.read(.object(state), path: "form.title") == .string("Keep me"))
        MiniAppExpression.write(&state, path: "constructor.value", value: .string("blocked"))
        #expect(state["constructor"] == nil)
        let expression: JSONValue = .object(["op": .string("add"), "args": .array([.number(2), .number(3)])])
        #expect(MiniAppExpression.evaluate(expression, context: [:]) == .number(5))
        #expect(MiniAppExpression.evaluate(.object(["get": .string("state.form.title")]), context: ["state": .object(state)]) == .string("Keep me"))
    }
    @Test func publicConnectorRequestsAreBuiltOnDevice() throws {
        let connector = try JSONDecoder().decode(JSONValue.self, from: Data(#"""
        {"title":"Forecast","origin":"https://api.open-meteo.com","auth":{"type":"none"},"operations":{
          "forecast":{"method":"GET","path":"/v1/forecast","input":{"latitude":{"type":"number","required":true},"current":{"type":"string"},"days":{"type":"number"}}},
          "save":{"method":"POST","path":"/v1/save","input":{"note":{"type":"string","required":true}}},
          "escape":{"method":"GET","path":"https://evil.example/v1","input":{}}}}
        """#.utf8))
        let get = try MiniAppPublicAPI.makeRequest(connector: connector, operation: "forecast", input: .object(["latitude": .number(52.52), "current": .string("a+b,c"), "days": .number(1)]))
        #expect(get.url?.absoluteString == "https://api.open-meteo.com/v1/forecast?current=a%2Bb,c&days=1&latitude=52.52")
        #expect(get.httpMethod == "GET")
        let post = try MiniAppPublicAPI.makeRequest(connector: connector, operation: "save", input: .object(["note": .string("Hi")]))
        #expect(post.httpBody.map { String(decoding: $0, as: UTF8.self) } == #"{"note":"Hi"}"#)
        #expect(throws: MiniAppPublicAPI.Failure.invalidInput("latitude")) { try MiniAppPublicAPI.makeRequest(connector: connector, operation: "forecast", input: .object(["latitude": .string("x")])) }
        #expect(throws: MiniAppPublicAPI.Failure.invalidInput("extra")) { try MiniAppPublicAPI.makeRequest(connector: connector, operation: "forecast", input: .object(["latitude": .number(1), "extra": .number(1)])) }
        #expect(throws: MiniAppPublicAPI.Failure.unavailable("escape")) { try MiniAppPublicAPI.makeRequest(connector: connector, operation: "escape", input: .null) }
        var keyed = connector.miniObject; keyed["auth"] = .object(["type": .string("apiKey"), "header": .string("X-Key")])
        #expect(!MiniAppPublicAPI.isPublic(.object(keyed)))
        #expect(throws: MiniAppPublicAPI.Failure.unavailable("forecast")) { try MiniAppPublicAPI.makeRequest(connector: .object(keyed), operation: "forecast", input: .object(["latitude": .number(1)])) }
    }
    @Test func exportBuildsFilesFromEvaluatedContent() throws {
        let rows: JSONValue = .array([.object(["title": .string("Milk, 2L"), "done": .bool(false)]), .object(["title": .string("Say \"hi\""), "count": .number(3)])])
        let csv = try MiniAppFile.export(.object(["filename": .string("tasks"), "format": .string("csv"), "content": rows]))
        #expect(csv.filename == "tasks.csv")
        #expect(String(decoding: csv.data, as: UTF8.self) == "count,done,title\r\n,false,\"Milk, 2L\"\r\n3,,\"Say \"\"hi\"\"\"\r\n")
        let ordered = MiniAppFile.csv(.array([.array([.string("B"), .string("A")]), .array([.number(1.5), .null])]))
        #expect(ordered == "B,A\r\n1.5,\r\n")
        let json = try MiniAppFile.export(.object(["filename": .string("data.json"), "format": .string("json"), "content": .object(["b": .number(1), "a": .string("x/y")])]))
        #expect(json.filename == "data.json")
        #expect(String(decoding: json.data, as: UTF8.self) == "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
        let text = try MiniAppFile.export(.object(["filename": .string("../notes"), "content": .string("Hello")]))
        #expect(text.filename == "-notes.txt")
        #expect(text.data == Data("Hello".utf8))
        #expect(try MiniAppFile.export(.object(["filename": .string("  "), "content": .null])).filename == "Export.txt")
        #expect(throws: MiniAppFile.Failure.tooLarge(MiniAppFile.exportLimit)) {
            try MiniAppFile.export(.object(["filename": .string("big"), "content": .string(String(repeating: "x", count: MiniAppFile.exportLimit + 1))]))
        }
    }
    @Test func downloadsAcceptOnlyHTTPSWithoutCredentials() throws {
        #expect(try MiniAppFile.downloadURL(.string("https://files.example.com/report.pdf")).host == "files.example.com")
        for bad in ["http://files.example.com/a", "https://user:pw@files.example.com/a", "file:///etc/hosts", "https://", "report.pdf"] {
            #expect(throws: MiniAppFile.Failure.invalidURL) { try MiniAppFile.downloadURL(.string(bad)) }
        }
        #expect(throws: MiniAppFile.Failure.invalidURL) { try MiniAppFile.downloadURL(.number(1)) }
        #expect(MiniAppFile.filename("report.pdf", fallback: "Download", defaultExtension: nil) == "report.pdf")
    }
}
