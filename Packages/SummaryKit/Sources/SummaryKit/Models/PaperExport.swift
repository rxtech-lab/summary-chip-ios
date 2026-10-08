import Foundation
import UniformTypeIdentifiers

public enum PaperExportFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case pdf
    case docx

    public var id: String { rawValue }
    public var title: String { self == .pdf ? "PDF" : String(localized: "Word (.docx)", bundle: .module) }
    public var contentType: UTType { self == .pdf ? .pdf : UTType(filenameExtension: "docx") ?? .data }
}

public struct PaperExport: Sendable {
    public let data: Data
    public let format: PaperExportFormat
    public let language: String?
    public let revision: Int?
}
