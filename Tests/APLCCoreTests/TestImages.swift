import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Builds synthetic JPEGs on disk so the transcode path can be exercised
/// without a photo library, and therefore in CI.
enum TestImages {
    /// A deterministic, photograph-like image.
    ///
    /// The content is chosen carefully, because a fixture that is unlike a
    /// photograph makes SSIM thresholds calibrated on real photographs look
    /// broken. Two failure modes to avoid:
    ///
    /// - Broadband noise is pathological for any lossy codec and scores far
    ///   worse than real images.
    /// - Uniform fine grain over flat areas is just as bad in the other
    ///   direction: the encoder erases it completely, and SSIM's variance term
    ///   punishes that hard even though the picture looks identical.
    ///
    /// So: smooth gradients for bulk, plus genuine structure — bands and hard
    /// edges — which is what an encoder actually has to preserve in a photo.
    static func makeCGImage(width: Int = 640, height: Int = 480) -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        func clampByte(_ value: Double) -> UInt8 {
            UInt8(min(max(value, 0), 255))
        }

        for y in 0..<height {
            let fy = Double(y) / Double(max(height - 1, 1))
            for x in 0..<width {
                let fx = Double(x) / Double(max(width - 1, 1))

                let bands = 18.0 * sin(fx * 6.0) * cos(fy * 4.5)
                let vignette = 40.0 * ((fx - 0.5) * (fx - 0.5) + (fy - 0.5) * (fy - 0.5))

                // Two solid shapes give the encoder real edges to reproduce,
                // so the image is not so smooth that structure disappears.
                let dx = fx - 0.35, dy = fy - 0.45
                let inDisc = (dx * dx + dy * dy) < 0.02
                let inBar = fx > 0.62 && fx < 0.78 && fy > 0.2 && fy < 0.8

                var r = 60 + 150 * fx + bands - vignette
                var g = 80 + 120 * fy - bands - vignette
                var b = 150 - 70 * fx + 50 * fy + bands - vignette
                if inDisc { r += 70; g -= 45; b -= 30 }
                if inBar { r -= 50; g += 60; b -= 55 }

                let i = y * bytesPerRow + x * 4
                pixels[i + 0] = clampByte(r)
                pixels[i + 1] = clampByte(g)
                pixels[i + 2] = clampByte(b)
                pixels[i + 3] = 255
            }
        }

        let ctx = pixels.withUnsafeMutableBytes { buf in
            CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        return ctx!.makeImage()!
    }

    /// Writes a JPEG carrying EXIF, GPS and TIFF blocks plus an orientation tag.
    @discardableResult
    static func writeJPEG(
        at url: URL,
        width: Int = 640, height: Int = 480,
        includeGPS: Bool = true,
        orientation: Int = 1,
        keywords: [String] = []
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:15 10:30:00",
                kCGImagePropertyExifLensModel: "aplc test lens",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "aplc",
                kCGImagePropertyTIFFModel: "synthetic",
            ] as [CFString: Any],
        ]
        if !keywords.isEmpty {
            properties[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCKeywords: keywords
            ] as [CFString: Any]
        }
        if includeGPS {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 45.4642,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 9.1900,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any]
        }

        CGImageDestinationAddImage(dst, makeCGImage(width: width, height: height),
                                   properties as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }
}

/// A temporary directory that cleans itself up.
final class TempDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aplc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
