#if DEBUG
import Foundation
import SummaryKit
import SwiftUI

/// Offline fixture for reviewing the real paper menu, export sheet and saved rendering controls.
struct PaperExportPreviewHost: View {
    @State private var environment: AppEnvironment = {
        let token = SharedTokenBundle(accessToken: "preview-token", refreshToken: nil, idToken: nil,
                                      expiresAt: .now.addingTimeInterval(86_400), subject: "preview-user")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaperExportPreviewProtocol.self]
        return AppEnvironment.live(configuration: .live(), vault: InMemoryTokenVault(token),
                                   session: URLSession(configuration: configuration), authenticationState: .signedIn)
    }()

    var body: some View {
        NavigationStack {
            PaperDetailView(environment: environment, paperID: "preview-paper", title: "Motion")
        }
    }
}

nonisolated final class PaperExportPreviewProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let (data, type) = PaperExportPreviewStore.shared.respond(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": type, "X-Paper-Revision": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

nonisolated private final class PaperExportPreviewStore: @unchecked Sendable {
    static let shared = PaperExportPreviewStore()
    private let lock = NSLock()
    private var paper = Paper(id: "preview-paper", slug: "preview-paper", revision: 0,
                              shareUrl: URL(string: "https://preview.invalid/s/preview-paper")!, title: "Motion",
                              files: [PaperFile(path: "main.tex", content: #"\documentclass{article}\title{Motion}\begin{document}\maketitle\section{Results}Energy is conserved. $E=mc^2$.\end{document}"#)], mainFile: "main.tex", originalLanguage: "en", language: "en")

    func respond(to request: URLRequest) -> (Data, String) {
        lock.withLock {
            if request.url?.lastPathComponent == "pdf" { return (Self.pdf, "application/pdf") }
            var body: [String: Any]
            switch request.url?.lastPathComponent {
            case "rendering":
                if let style = try? SummaryJSON.decoder().decode(PaperRendering.self, from: Self.body(request)) { paper.renderingOptions = style }
                body = paperBody
            case "translations": body = ["originalLanguage": "en", "items": []]
            case "versions": body = request.httpMethod == "POST" ? paperBody.merging(["version": NSNull()]) { _, new in new } : ["items": [], "nextCursor": NSNull()]
            default: body = paperBody
            }
            return (try! JSONSerialization.data(withJSONObject: body), "application/json")
        }
    }

    private var paperBody: [String: Any] {
        ["paper": try! JSONSerialization.jsonObject(with: SummaryJSON.encoder().encode(paper))]
    }

    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private static var pdf: Data {
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R >>", "<< /Length 0 >>\nstream\n\nendstream"]
        var content = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(content.utf8.count)
            content += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = content.utf8.count
        content += "xref\n0 5\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        content += "trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(content.utf8)
    }
}
#endif
