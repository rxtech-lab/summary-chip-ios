import Foundation

/// Saved independently of the LaTeX source. Both preview and PDF/Word exports use these options.
public struct PaperRendering: Codable, Hashable, Sendable {
    public var enabled = false
    public var pageSize = "a4"
    public var orientation = "portrait"
    public var columns = 1
    public var columnGap: Double = 6
    public var marginTop: Double = 20
    public var marginBottom: Double = 20
    public var marginLeft: Double = 20
    public var marginRight: Double = 20
    public var fontFamily = "original"
    public var fontSize: Double = 12
    public var lineSpacing: Double = 1.15
    public var paragraphSpacing: Double = 6
    public var paragraphIndent: Double = 0
    public var alignment = "justified"
    public var headingSize: Double = 18
    public var headingColor = "000000"
    public var sectionNumbers = true
    public var tableOfContents = false
    public var tocDepth = 2
    public var titlePage = false
    public var hyphenation = true
    public var pageNumbers = "footer-center"
    public var headerText = ""
    public var footerText = ""

    public init() {}
}
