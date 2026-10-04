import Foundation
import Testing
@testable import SummaryKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct ModelDecodingTests {
    @Test func decodesContractSummary() throws {
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: fixture("summary.json"))
        #expect(summary.slug == "a1B2c3D4e5")
        #expect(summary.shareUrl.absoluteString == "https://summary.rxlab.app/s/a1B2c3D4e5")
        #expect(summary.sourceType == .url)
        #expect(summary.source == .web)
        #expect(summary.sourceFileUrl == nil)
        #expect(summary.hasSourceMarkdown)
        #expect(summary.highlights == ["One", "Two"])
        #expect(summary.theme.mode == .dark)
        #expect(summary.theme.colors.count == 3)
        #expect(summary.visibility == .public)
        #expect(summary.ttlDays == 7)
        #expect(summary.expiresAt == SummaryJSON.parseISO8601("2026-10-08T00:00:00Z"))
        #expect(summary.isOwner)
        #expect(summary.sourceLabel == "Example")
        #expect(summary.tileImageUrl?.absoluteString == "https://summary.rxlab.app/s/a1B2c3D4e5/art.png?v=1759276800000")
    }

    @Test func decodesPublicSummaryWithoutOwnerFields() throws {
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: fixture("public-summary.json"))
        #expect(summary.isOwner == false)
        #expect(summary.hasSourceMarkdown == false) // absent → not kept
        #expect(summary.artImageUrl == nil)
        #expect(summary.tileImageUrl == summary.ogImageUrl)
        #expect(summary.visibility == .public)
        #expect(summary.ttlDays == nil)
        #expect(summary.viewCount == 0)
        #expect(summary.sourceType == .pdf)
        #expect(summary.source == .pdf) // absent → inferred from sourceType
        #expect(summary.imageStyle == .illustration)
        #expect(summary.originalURL?.absoluteString == "https://summary.rxlab.app/s/zzzzzzzzzz/source")
        #expect(summary.sourceLabel == "PDF")
    }

    @Test func decodesUnknownSourceWithoutFailing() throws {
        var json = String(decoding: try fixture("summary.json"), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"source\": \"web\"", with: "\"source\": \"tiktok\"")
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: Data(json.utf8))
        #expect(summary.source == .other("tiktok"))
        #expect(summary.source.rawValue == "tiktok")
    }

    @Test func decodesPlatformSources() throws {
        let json = String(decoding: try fixture("summary.json"), as: UTF8.self)
        for origin in SummaryOrigin.known {
            let data = Data(json.replacingOccurrences(of: "\"source\": \"web\"", with: "\"source\": \"\(origin.rawValue)\"").utf8)
            let summary = try SummaryJSON.decoder().decode(Summary.self, from: data)
            #expect(summary.source == origin)
            #expect(SummaryOrigin(rawValue: origin.rawValue) == origin)
        }
        #expect(SummaryListQuery(source: .youtube).queryItems == [URLQueryItem(name: "source", value: "youtube")])
    }

    @Test func decodesPagesFacetsViewedAtAndErrors() throws {
        let item = String(decoding: try fixture("summary.json"), as: UTF8.self)
        let page = try SummaryJSON.decoder().decode(SummaryPage.self, from: Data(#"{"items":[\#(item)],"nextCursor":null}"#.utf8))
        #expect(page.items.count == 1)
        #expect(page.nextCursor == nil)

        var object = try #require(try JSONSerialization.jsonObject(with: Data(item.utf8)) as? [String: Any])
        object["isOwner"] = false
        object["viewedAt"] = "2026-10-02T12:00:00.123Z"
        let viewedItem = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let library = try SummaryJSON.decoder().decode(SummaryPage.self, from: Data(#"{"items":[\#(viewedItem)],"nextCursor":"abc"}"#.utf8))
        let viewed = try #require(library.items.first)
        #expect(viewed.slug == "a1B2c3D4e5")
        #expect(viewed.viewedAt != nil)
        #expect(viewed.activityDate == viewed.viewedAt)
        #expect(!viewed.isOwner)
        #expect(library.nextCursor == "abc")

        let facets = try SummaryJSON.decoder().decode(Facets.self, from: Data(#"{"categories":[{"name":"Technology","count":4}],"tags":[{"name":"ai","count":2}]}"#.utf8))
        #expect(facets.categories.first == FacetCount(name: "Technology", count: 4))

        let upload = try SummaryJSON.decoder().decode(UploadTicket.self, from: Data(#"{"key":"uploads/x.pdf","uploadUrl":"https://r2.example/x?sig=1","method":"PUT","headers":{"Content-Type":"application/pdf"},"expiresAt":"2026-10-01T00:10:00Z"}"#.utf8))
        #expect(upload.key == "uploads/x.pdf")
        #expect(upload.headers["Content-Type"] == "application/pdf")

        let error = try SummaryJSON.decoder().decode(APIErrorEnvelope.self, from: Data(#"{"error":{"code":"NOT_FOUND","message":"Nope","requestId":"r1"}}"#.utf8))
        #expect(error.error.code == "NOT_FOUND")
    }

    @Test func encodesCreateRequestSources() throws {
        func json(_ value: some Encodable) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: SummaryJSON.encoder().encode(value)) as! [String: Any]
        }
        let url = try json(CreateSummaryRequest(source: .url(URL(string: "https://a.com")!)))
        #expect((url["source"] as? [String: Any])?["type"] as? String == "url")
        #expect(url["ttlDays"] as? Int == 7)
        #expect(url["language"] as? String == "auto")
        #expect(url["imageStyle"] as? String == "graphic")
        #expect(url["visibility"] as? String == "public")
        #expect(url["keepSourceText"] == nil)

        let kept = try json(CreateSummaryRequest(source: .local(LocalFileSource(filename: "a.md", kind: .text, text: "# A")), options: .init(keepsSourceText: true)))
        #expect(kept["keepSourceText"] as? Bool == true)

        let never = try json(CreateSummaryRequest(source: .text("hi", title: nil), options: .init(language: .zhHans, ttl: .never, visibility: .private)))
        #expect(never["ttlDays"] is NSNull)
        #expect(never["language"] as? String == "zh-Hans")
        #expect(never["visibility"] as? String == "private")

        let long = String(repeating: "a", count: 70_000)
        let web = try json(CreateSummaryRequest(source: .webpage(WebpageSource(url: URL(string: "https://a.com")!, title: "T", content: long, siteName: "A", lang: "en"))))
        let source = try #require(web["source"] as? [String: Any])
        #expect(source["type"] as? String == "webpage")
        #expect((source["content"] as? String)?.count == 60_000)
        #expect(source["html"] == nil)

        let rich = try json(CreateSummaryRequest(source: .webpage(WebpageSource(url: URL(string: "https://a.com")!, title: nil, content: "c", html: "<p><a href=\"https://a.com/x\">x</a></p>", siteName: nil, lang: nil))))
        #expect((rich["source"] as? [String: Any])?["html"] as? String == "<p><a href=\"https://a.com/x\">x</a></p>")
        let huge = WebpageSource(url: URL(string: "https://a.com")!, title: nil, content: "c", html: String(repeating: "a", count: WebpageSource.maxHTMLLength + 1), siteName: nil, lang: nil)
        #expect(huge.html == nil)

        let pdf = try json(CreateSummaryRequest(source: .pdf(uploadKey: "uploads/k", filename: "x.pdf", sourceUrl: nil)))
        let pdfSource = try #require(pdf["source"] as? [String: Any])
        #expect(pdfSource["uploadKey"] as? String == "uploads/k")
        #expect(pdfSource["sourceUrl"] is NSNull)
    }

    @Test func encodesPatch() throws {
        let data = try SummaryJSON.encoder().encode(SummaryPatch(visibility: .private, ttl: .never))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ttlDays":null,"visibility":"private"}"#)
        let onlyTTL = try SummaryJSON.encoder().encode(SummaryPatch(ttl: .days(30)))
        #expect(String(decoding: onlyTTL, as: UTF8.self) == #"{"ttlDays":30}"#)
    }

    @Test func encodesDisplayLanguagePatch() throws {
        let translated = try SummaryJSON.encoder().encode(SummaryPatch(displayLanguage: .zhHant))
        #expect(String(decoding: translated, as: UTF8.self) == #"{"displayLanguage":"zh-Hant"}"#)
        // `.auto` reads the summary as written.
        let original = try SummaryJSON.encoder().encode(SummaryPatch(displayLanguage: .auto))
        #expect(String(decoding: original, as: UTF8.self) == #"{"displayLanguage":null}"#)
    }

    @Test func decodesTranslatedSummary() throws {
        var object = try #require(JSONSerialization.jsonObject(with: fixture("summary.json")) as? [String: Any])
        object["language"] = "ja"
        object["originalLanguage"] = "en"
        object["displayLanguage"] = "ja"
        object["sourceTranslationPending"] = true
        let summary = try SummaryJSON.decoder().decode(Summary.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(summary.isTranslated)
        #expect(summary.displayLanguage == "ja")
        #expect(summary.sourceTranslationPending)
        #expect(summary.translationPending == false)

        // Older payloads: the summary is in the language it was written in.
        let untranslated = try SummaryJSON.decoder().decode(Summary.self, from: fixture("summary.json"))
        #expect(untranslated.originalLanguage == untranslated.language)
        #expect(untranslated.isTranslated == false)
    }

    @Test func mapsLanguageTags() {
        #expect(SummaryLanguage(languageTag: "zh-Hant-TW") == .zhHant)
        #expect(SummaryLanguage(languageTag: "zh-HK") == .zhHant)
        #expect(SummaryLanguage(languageTag: "zh-CN") == .zhHans)
        #expect(SummaryLanguage(languageTag: "en-GB") == .en)
        #expect(SummaryLanguage(languageTag: "it") == nil)
        #expect(SummaryLanguage(languageTag: "auto") == nil)
        #expect(SummaryLanguage.translations.contains(.auto) == false)
    }

    @Test func listQueryDropsEmptyValues() {
        let items = SummaryListQuery(q: "  ", category: "Technology", tag: nil, visibility: .private, cursor: "c", limit: 20).queryItems
        #expect(items.map(\.name) == ["category", "visibility", "cursor", "limit"])
    }

    @Test func parsesSummaryLinks() {
        #expect(SummaryLink.slug(from: URL(string: "https://summary.rxlab.app/s/a1B2c3D4e5")!, siteHost: "summary.rxlab.app") == "a1B2c3D4e5")
        #expect(SummaryLink.slug(from: URL(string: "https://summary.rxlab.app/s/a1B2c3D4e5/og.png")!) == nil)
        #expect(SummaryLink.slug(from: URL(string: "https://evil.com/s/abc")!, siteHost: "summary.rxlab.app") == nil)
        #expect(SummaryLink.slug(from: URL(string: "summarychip://s/abc")!) == "abc")
        #expect(SummaryLink.summaryID(from: SummaryLink.openInAppURL(summaryID: "id-1")) == "id-1")
    }

    @Test func configurationTreatsUnexpandedValuesAsUnset() {
        #expect(SummaryConfiguration.sanitized("$(SUMMARY_CHIP_API_BASE_URL)") == nil)
        #expect(SummaryConfiguration.sanitized("  ") == nil)
        #expect(SummaryConfiguration.sanitized("https://x") == "https://x")
    }

    @Test func decodesCreatedAPIKey() throws {
        let json = Data("""
        {"key":"chippy_abcdEFGH","apiKey":{"id":"k1","name":"Claude Code","hint":"chippy_abcd…EFGH","toolCallCount":3,
        "summariesAddedCount":1,"lastUsedAt":null,"createdAt":"2026-10-04T10:00:00.123Z"}}
        """.utf8)
        let created = try SummaryJSON.decoder().decode(CreatedAPIKey.self, from: json)
        #expect(created.key == "chippy_abcdEFGH")
        #expect(created.apiKey.name == "Claude Code")
        #expect(created.apiKey.toolCallCount == 3)
        #expect(created.apiKey.summariesAddedCount == 1)
        #expect(created.apiKey.lastUsedAt == nil)
        #expect(created.apiKey.createdAt == SummaryJSON.parseISO8601("2026-10-04T10:00:00.123Z"))
    }

    @Test func mcpEndpointIsUnderTheAPIBase() {
        let client = SummaryAPIClient(baseURL: URL(string: "https://summary.rxlab.app")!, tokenProvider: StaticTokenProvider())
        #expect(client.mcpEndpoint.absoluteString == "https://summary.rxlab.app/api/mcp")
    }
}

private struct StaticTokenProvider: AccessTokenProvider {
    func accessToken(forceRefresh: Bool) async throws -> String { "token" }
}
