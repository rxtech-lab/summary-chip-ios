import Foundation
import Testing
@testable import SummaryKit

@Suite struct PaperFigureTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
    private var image: PaperFile { PaperFile(path: "images/figure.png", asset: PaperAsset(key: "uploads/staged.png", mimeType: "image/png", byteSize: png.count)) }

    private func source(preamble: String = "") -> PaperSource {
        PaperSource(title: "Figures", files: [
            PaperFile(path: "main.tex", content: "\\documentclass{article}\n\(preamble)\n\\begin{document}\n\\input{sections/intro}\n\\end{document}\n"),
            PaperFile(path: "sections/intro.tex", content: "\\section{Introduction}\n"),
        ], mainFile: "main.tex")
    }

    @Test func imagesRoundTripAndStayBinaryOnRename() throws {
        try PaperLimits.validateImage(path: image.path, data: png)
        #expect(image.isImage && image.content.isEmpty)
        let decoded = try SummaryJSON.decoder().decode(PaperFile.self, from: JSONEncoder().encode(image))
        #expect(decoded == image)
        var project = source()
        project.write(image)
        project.rename(image.path, to: "images/renamed.png")
        #expect(project.file("images/renamed.png")?.asset == image.asset)
        #expect(project.file("main.tex")?.asset == nil)
    }

    @Test func imageFigureLoadsGraphicxAndInsertsInSelectedSection() throws {
        var project = source()
        try project.addFigure(kind: .image, path: "figures/photo.tex", caption: "50% & x_y #1", code: "", image: image, target: "sections/intro.tex")
        #expect(project.file(image.path) == image)
        #expect(project.file("main.tex")?.content.contains(#"\usepackage{graphicx}"#) == true)
        #expect(project.file("figures/photo.tex")?.content.contains(#"\includegraphics[width=0.8\linewidth]{images/figure.png}"#) == true)
        let captionLine = project.file("figures/photo.tex")?.content.split(separator: "\n").first { $0.hasPrefix("\\caption") }
        #expect(captionLine == "\\caption{50\\% \\& x\\_y \\#1}")
        #expect(project.file("sections/intro.tex")?.content.hasSuffix("\\input{figures/photo.tex}\n") == true)
        #expect(project.file("main.tex")?.content.contains("\\input{figures/photo.tex}") == false)
    }

    @Test func diagramsAndPlotsInsertBeforeEndDocumentAndLoadPackages() throws {
        for kind in [PaperFigureKind.tikz, .plot] {
            var project = source(preamble: "% \\usepackage{pgfplots}\n% \\begin{document}")
            try project.addFigure(kind: kind, path: "figures/chart.tex", caption: "Example", code: kind.starter)
            let main = try #require(project.file("main.tex")?.content)
            let package = kind == .tikz ? "tikz" : "pgfplots"
            #expect(main.contains("\n\\usepackage{\(package)}\n"))
            #expect(main.contains("\\input{figures/chart.tex}\n\\end{document}"))
            if kind == .plot { #expect(main.contains(#"\pgfplotsset{compat=1.18}"#)) }
            #expect(project.file("figures/chart.tex")?.content.contains(kind.starter) == true)
        }
    }

    @Test func preservesExistingPackageOptions() throws {
        var project = source(preamble: "\\usepackage[draft]{graphicx, tikz}\n")
        try project.addFigure(kind: .tikz, path: "figures/one.tex", caption: "First", code: PaperFigureKind.tikz.starter)
        try project.addFigure(kind: .tikz, path: "figures/two.tex", caption: "Second", code: PaperFigureKind.tikz.starter)
        let main = try #require(project.file("main.tex")?.content)
        #expect(main.components(separatedBy: "\\usepackage").count == 2)
        #expect(main.contains(#"\usepackage[draft]{graphicx, tikz}"#))
    }

    @Test func invalidFiguresLeaveTheProjectUntouched() throws {
        var project = source()
        let original = project
        #expect(throws: PaperProjectError.self) {
            try project.addFigure(kind: .tikz, path: "main.tex", caption: "", code: PaperFigureKind.tikz.starter)
        }
        #expect(project == original)
        #expect(throws: PaperProjectError.self) {
            try project.addFigure(kind: .image, path: "figures/photo.tex", caption: "", code: "")
        }
        #expect(project == original)
        project.files[0].content = "% \\begin{document}\n"
        #expect(throws: PaperProjectError.self) {
            try project.addFigure(kind: .plot, path: "figures/plot.tex", caption: "", code: PaperFigureKind.plot.starter)
        }
    }

    @Test func validatesAssetTypeAndCombinedLimits() throws {
        #expect(throws: PaperProjectError.self) { try PaperLimits.validateImage(path: "image.pdf", data: png) }
        #expect(throws: PaperProjectError.self) { try PaperLimits.validateImage(path: "image.png", data: Data(repeating: 0, count: PaperLimits.maxImageBytes + 1)) }
        var project = source()
        let asset = PaperAsset(key: "uploads/large", mimeType: "image/png", byteSize: PaperLimits.maxImageBytes)
        project.write(PaperFile(path: "images/one.png", asset: asset))
        #expect(PaperLimits.problem(with: project) == nil)
        project.write(PaperFile(path: "images/two.png", asset: asset))
        project.write(PaperFile(path: "images/three.png", asset: asset))
        #expect(PaperLimits.problem(with: project) != nil)
    }
}
