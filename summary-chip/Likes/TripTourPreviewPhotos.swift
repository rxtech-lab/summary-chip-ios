#if DEBUG
import Foundation
import SummaryKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Opt-in, offline photos for tour interaction screenshots. Artwork is labelled as preview data.
nonisolated final class TripTourPreviewPhotos: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String: Data] = [:]
    private static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("--preview-tour-photos") }

    @MainActor static func registerIfEnabled() {
        guard isEnabled else { return }
        var loaded: [String: Data] = [:]
        for name in ["FeatureTripDiary", "WelcomeSafari"] {
            #if os(iOS)
            loaded[name] = UIImage(named: name)?.pngData()
            #else
            loaded[name] = NSImage(named: name)?.tiffRepresentation.flatMap {
                NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
            }
            #endif
        }
        lock.withLock { images = loaded }
        SummaryAssetLoader.usePreviewImageProtocols([Self.self])
    }

    static func document(_ data: Data) -> [String: Any] {
        var document = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard isEnabled, var places = document["places"] as? [[String: Any]],
              let index = places.firstIndex(where: { $0["id"] as? String == "tokyo" }) else { return document }
        // Reproduce a trip whose photos exist only in its rendered JSON gallery.
        places[index]["photos"] = []
        document["places"] = places
        var views = document["views"] as? [[String: Any]] ?? []
        views.append(["id": "preview-gallery", "title": "Museum photos", "dayId": "d1", "spec": [
            "root": "gallery", "elements": ["gallery": ["type": "Gallery", "props": ["images": photos]]],
        ]])
        document["views"] = views
        return document
    }

    private static var photos: [[String: String]] {
        ["FeatureTripDiary", "WelcomeSafari"].enumerated().map { index, name in
            ["url": "https://tour-preview.invalid/\(name)", "caption": "Preview photo \(index + 1)"]
        }
    }

    static func tour(_ data: Data) -> [String: Any] {
        var response = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard isEnabled, var tour = response["tour"] as? [String: Any], var scenes = tour["scenes"] as? [[String: Any]] else { return response }
        scenes[1]["imageGroups"] = [["id": "preview-gallery:gallery", "title": "Museum photos", "dayId": "d1", "photos": photos]]
        var cue: [String: Any] = ["textOffset": 71, "placeId": "tokyo", "imageGroupId": "preview-gallery:gallery"]
        if ProcessInfo.processInfo.arguments.contains("--preview-tour-landmarks") {
            scenes[1]["landmarks"] = [["id": "landmark-1", "name": "Nezu Museum", "nearPlaceId": "tokyo"]]
            cue.removeValue(forKey: "placeId")
            cue["landmarkId"] = "landmark-1"
        }
        scenes[1]["visuals"] = [cue]
        tour["scenes"] = scenes
        response["tour"] = tour
        return response
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tour-preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let data = Self.lock.withLock({ Self.images[url.lastPathComponent] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
