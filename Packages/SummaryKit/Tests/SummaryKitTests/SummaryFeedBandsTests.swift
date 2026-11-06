#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SummaryKit

@MainActor
struct SummaryFeedBandsTests {
    private typealias Feed = SummaryCardFeed<EmptyView, EmptyView>

    private func summary(_ id: String, title: String, body: String) throws -> Summary {
        let fields: [String: String] = [
            "id": id, "kind": "summary", "slug": id, "shareUrl": "https://example.com/s/\(id)",
            "title": title, "summary": body, "createdAt": "2026-10-28T00:00:00Z",
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Summary.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func entries(count: Int) throws -> [SummaryFeedEntry] {
        let titles = ["Short title", "研究人员发现 Haiou：Codex 越狱工具包内藏「提示广告」", "Together Compiler 发布：面向多态推理的持续编译优化系统", "A rather longer English headline about masonry layouts"]
        let body = String(repeating: "Bitcoin 标 2026-11-02 凌晨发现安全事件，仅影响在线热钱包。", count: 6)
        return try (0..<count).map { index in
            try SummaryFeedEntry(summary: summary("card-\(index)", title: titles[index % titles.count], body: body))
        }
    }

    private func style(_ target: SummaryTileView.Style, in entries: [SummaryFeedEntry]) throws -> Summary {
        try #require(entries.first { SummaryTileView.Style.style(for: $0.summary) == target }?.summary)
    }

    /// The real card's height, compared with the estimate the bands are balanced on.
    @Test(arguments: [SummaryTileView.Style.text, .inset, .hero], [CGFloat(172), 240, 355, 520])
    func estimateTracksRenderedCard(style target: SummaryTileView.Style, width: CGFloat) throws {
        let summary = try style(target, in: entries(count: 40))
        let host = NSHostingController(rootView: SummaryTileView(summary: summary).frame(width: width))
        let rendered = host.sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        let estimate = target.estimatedHeight(of: summary, columnWidth: width, fonts: .current)
        #expect(abs(estimate - rendered) / rendered < 0.15, "\(target) at \(width): estimated \(estimate), rendered \(rendered)")
    }

    /// A filling card keeps its natural height unless a band offers it more.
    @Test(arguments: [SummaryTileView.Style.text, .inset, .hero])
    func fillingCardGrowsOnlyWhenOffered(style target: SummaryTileView.Style) throws {
        let summary = try style(target, in: entries(count: 40))
        func height<Content: View>(_ view: Content, offered: CGFloat) -> CGFloat {
            NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 355, height: offered)).height
        }
        let natural = SummaryTileView(summary: summary).frame(width: 355).fixedSize(horizontal: false, vertical: true)
        let filling = SummaryTileView(summary: summary, fillsHeight: true).frame(width: 355)
        #expect(height(filling.fixedSize(horizontal: false, vertical: true), offered: 2_000) == height(natural, offered: 2_000))
        #expect(height(filling, offered: 900) == 900)
    }

    /// Every band but the last must leave less room than the shortest card would need, or the
    /// shorter column ends in a hole that a card could have filled.
    @Test(arguments: [(2, CGFloat(355)), (3, 300), (5, 280)])
    func closedBandsEndNearlyLevel(columns: Int, width: CGFloat) throws {
        let bands = try Feed.bands(entries(count: 300), into: columns, columnWidth: width)
        let fonts = SummaryTileView.EstimateFonts.current
        let spreads = bands.dropLast().map { band in
            let heights = band.map { column in
                column.reduce(CGFloat(0)) { total, entry in
                    total + 14 + SummaryTileView.Style.style(for: entry.summary).estimatedHeight(of: entry.summary, columnWidth: width, fonts: fonts)
                }
            }
            return (heights.max() ?? 0) - (heights.min() ?? 0)
        }
        #expect(!spreads.isEmpty)
        #expect(spreads.allSatisfy { $0 < 200 }, "spreads: \(spreads)")
    }
}
#endif
