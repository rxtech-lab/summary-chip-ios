import UIKit
import XCTest

/// Compares screenshots with reference PNGs kept next to the tests, in
/// `__Snapshots__/<test class>/<name>_<device>_iOS<version>.png`: fonts render differently across
/// devices and iOS versions, so each has its own references.
///
/// A missing reference is recorded there and the test skipped (the image is attached to the
/// result too); commit it to start comparing. To re-record after an intended style change, run
/// with `TEST_RUNNER_RECORD_SNAPSHOTS=1` in xcodebuild's environment.
///
/// Pixels may differ by a little in each channel (antialiasing), and a small share of them may
/// differ by more; on a mismatch the reference, the screenshot and a diff (changed pixels in red)
/// are attached to the result.
@MainActor
enum SnapshotMatching {
    /// The largest per-channel difference that still counts as the same pixel.
    static let channelTolerance = 24
    /// The share of pixels allowed to differ by more.
    static let pixelTolerance = 0.003

    static func assertMatches(
        _ screenshot: XCUIScreenshot, named name: String, in test: XCTestCase,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let reference = referenceURL(named: name, test: test, file: file)
        let record = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
        guard !record, FileManager.default.fileExists(atPath: reference.path) else {
            try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: reference)
            attach(screenshot.image, "\(name) (recorded)", to: test)
            throw XCTSkip("Recorded the reference \(reference.lastPathComponent); commit it to compare against it.")
        }
        guard let expected = UIImage(contentsOfFile: reference.path).flatMap(Bitmap.init), let actual = Bitmap(screenshot.image) else {
            XCTFail("Couldn't read the screenshot or the reference \(reference.lastPathComponent).", file: file, line: line)
            return
        }
        guard expected.width == actual.width, expected.height == actual.height else {
            attach(screenshot.image, "\(name) (actual)", to: test)
            XCTFail("\(name) is \(actual.width)×\(actual.height) px; the reference is \(expected.width)×\(expected.height) px.", file: file, line: line)
            return
        }
        let (changed, diff) = actual.difference(from: expected, tolerance: channelTolerance)
        let share = Double(changed) / Double(actual.width * actual.height)
        guard share > pixelTolerance else { return }
        attach(UIImage(contentsOfFile: reference.path) ?? UIImage(), "\(name) (reference)", to: test)
        attach(screenshot.image, "\(name) (actual)", to: test)
        if let diff { attach(diff, "\(name) (diff)", to: test) }
        XCTFail(String(format: "%@ differs from its reference in %.2f%% of pixels.", name, share * 100), file: file, line: line)
    }

    private static func referenceURL(named name: String, test: XCTestCase, file: StaticString) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let device = (environment["SIMULATOR_DEVICE_NAME"] ?? UIDevice.current.model).replacingOccurrences(of: " ", with: "-")
        let version = UIDevice.current.systemVersion.split(separator: ".").prefix(2).joined(separator: ".")
        return URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appending(path: "__Snapshots__")
            .appending(path: String(describing: type(of: test)))
            .appending(path: "\(name)_\(device)_iOS\(version).png")
    }

    private static func attach(_ image: UIImage, _ name: String, to test: XCTestCase) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
    }
}

/// An image's pixels as 8-bit sRGB RGBA.
private struct Bitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        width = cgImage.width
        height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
                bytesPerRow: cgImage.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    /// How many pixels differ by more than `tolerance` in a channel, and an image of them: the
    /// reference faded, changed pixels red.
    func difference(from other: Bitmap, tolerance: Int) -> (Int, UIImage?) {
        var changed = 0
        var diff = [UInt8](repeating: 255, count: bytes.count)
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            var delta = 0
            for channel in 0..<3 { delta = max(delta, abs(Int(bytes[pixel + channel]) - Int(other.bytes[pixel + channel]))) }
            if delta > tolerance {
                changed += 1
                diff[pixel] = 255; diff[pixel + 1] = 0; diff[pixel + 2] = 0
            } else {
                for channel in 0..<3 { diff[pixel + channel] = UInt8(155 + Int(other.bytes[pixel + channel]) * 100 / 255) }
            }
        }
        guard changed > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return (changed, nil) }
        let image = diff.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        return (changed, image.map { UIImage(cgImage: $0) })
    }
}
