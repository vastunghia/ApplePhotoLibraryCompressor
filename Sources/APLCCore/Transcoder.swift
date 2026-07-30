import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TranscodeError: Error, CustomStringConvertible {
    case unreadableSource(URL)
    case destinationUnavailable(URL)
    case encodeFailed(URL)
    case heicNotSupported

    public var description: String {
        switch self {
        case .unreadableSource(let u): return "cannot read source image: \(u.path)"
        case .destinationUnavailable(let u): return "cannot create destination: \(u.path)"
        case .encodeFailed(let u): return "HEIC encode failed: \(u.path)"
        case .heicNotSupported: return "this system cannot write public.heic"
        }
    }
}

public struct TranscodeResult: Sendable {
    public let source: URL
    public let destination: URL
    public let sourceFacts: ImageFacts
    public let destinationFacts: ImageFacts
    public let quality: Double

    public var sourceBytes: Int { sourceFacts.byteCount }
    public var destinationBytes: Int { destinationFacts.byteCount }

    /// Fraction of the original size saved, e.g. 0.78 for a 78% reduction.
    public var savedFraction: Double {
        guard sourceBytes > 0 else { return 0 }
        return 1.0 - (Double(destinationBytes) / Double(sourceBytes))
    }
}

public struct Transcoder {
    public let quality: Double

    public init(quality: Double) {
        self.quality = min(max(quality, 0.0), 1.0)
    }

    /// True if ImageIO on this machine can actually write HEIC.
    ///
    /// Worth checking rather than assuming: the same query is what rules AVIF
    /// out — macOS reads `public.avif` but does not list it as a destination type.
    public static var canWriteHEIC: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }

    /// Transcodes a JPEG to HEIC, carrying metadata and gain map across.
    ///
    /// Nothing here is trusted: the caller is expected to run the result through
    /// `EligibilityGate.evaluatePostConditions` which re-reads the written file.
    /// - Parameter keywords: the authoritative keyword set to embed, or `nil` to
    ///   leave whatever the source file carried.
    ///
    ///   Passing a value — **including an empty array** — matters. Source files
    ///   in a real library carry stale XMP `dc:subject` from old export cycles
    ///   that disagrees with what Photos actually holds, and
    ///   `kCGImageDestinationMergeMetadata` would drag it across. Setting the
    ///   IPTC keywords explicitly replaces it; setting it to empty clears it.
    ///   `nil` is for when Photos could not be reached, where guessing would be
    ///   worse than leaving the file as it was.
    public func transcode(
        source: URL,
        destination: URL,
        keywords: [String]? = nil
    ) throws -> TranscodeResult {
        guard Self.canWriteHEIC else { throw TranscodeError.heicNotSupported }

        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw TranscodeError.unreadableSource(source)
        }
        let sourceFacts = try ImageProbe.probe(source: src, url: source)

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // A stale file from an interrupted run must not be mistaken for output.
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        guard let dst = CGImageDestinationCreateWithURL(
            destination as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            throw TranscodeError.destinationUnavailable(destination)
        }

        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Carries the HDR gain map through the re-encode.
            kCGImageDestinationPreserveGainMap: true,
            // Merges the source's EXIF/GPS/TIFF/IPTC rather than starting fresh.
            kCGImageDestinationMergeMetadata: true,
            // Keeps the embedded ICC profile instead of converting to sRGB.
            kCGImageDestinationOptimizeColorForSharing: false,
        ]
        if let keywords {
            // ImageIO keeps XMP dc:subject in step with the IPTC keywords, so
            // setting these also overwrites any stale subject the source carried.
            options[kCGImagePropertyIPTCDictionary] = [
                kCGImagePropertyIPTCKeywords: keywords
            ] as [CFString: Any]
        }

        // AddImageFromSource (rather than AddImage) is what lets ImageIO carry
        // the auxiliary data and metadata blocks over; handing it a bare CGImage
        // would silently drop the gain map.
        CGImageDestinationAddImageFromSource(dst, src, 0, options as CFDictionary)

        guard CGImageDestinationFinalize(dst) else {
            try? FileManager.default.removeItem(at: destination)
            throw TranscodeError.encodeFailed(destination)
        }

        let destinationFacts = try ImageProbe.probe(destination)

        return TranscodeResult(
            source: source,
            destination: destination,
            sourceFacts: sourceFacts,
            destinationFacts: destinationFacts,
            quality: quality
        )
    }
}
