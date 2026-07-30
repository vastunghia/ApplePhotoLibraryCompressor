import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything the eligibility gate needs to know about an image file on disk.
///
/// Deliberately a plain value type read straight off the file: the gate compares
/// the facts of the source against the facts of the freshly written HEIC, rather
/// than trusting whatever the encoder claimed to have done.
public struct ImageFacts: Equatable, Sendable, Codable {
    public var width: Int
    public var height: Int
    public var byteCount: Int
    public var typeIdentifier: String?

    public var hasGainMap: Bool
    public var hasEXIF: Bool
    public var hasGPS: Bool
    public var hasTIFF: Bool
    public var orientation: Int?
    public var profileName: String?

    /// IPTC keywords embedded in the file. Defaulted so existing call sites and
    /// previously written ledgers keep working.
    public var keywords: [String] = []

    /// Pixel count, used to reject anything that changed geometry.
    public var pixelSize: (width: Int, height: Int) { (width, height) }
}

public enum ImageProbeError: Error, CustomStringConvertible {
    case unreadable(URL)
    case noProperties(URL)

    public var description: String {
        switch self {
        case .unreadable(let u): return "cannot open image: \(u.path)"
        case .noProperties(let u): return "image has no readable properties: \(u.path)"
        }
    }
}

public enum ImageProbe {
    /// Reads structural + metadata facts without decoding the pixels.
    public static func probe(_ url: URL) throws -> ImageFacts {
        // kCGImageSourceShouldCache = false: we only want headers here, and these
        // files can be 14 MB each across tens of thousands of assets.
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            throw ImageProbeError.unreadable(url)
        }
        return try probe(source: src, url: url)
    }

    static func probe(source src: CGImageSource, url: URL) throws -> ImageFacts {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ImageProbeError.noProperties(url)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil

        return ImageFacts(
            width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
            byteCount: size ?? 0,
            typeIdentifier: CGImageSourceGetType(src) as String?,
            hasGainMap: hasGainMap(src),
            hasEXIF: props[kCGImagePropertyExifDictionary] != nil,
            hasGPS: props[kCGImagePropertyGPSDictionary] != nil,
            hasTIFF: props[kCGImagePropertyTIFFDictionary] != nil,
            orientation: props[kCGImagePropertyOrientation] as? Int,
            profileName: props[kCGImagePropertyProfileName] as? String,
            keywords: keywords(from: props)
        )
    }

    static func keywords(from props: [CFString: Any]) -> [String] {
        guard let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else { return [] }
        // ImageIO returns a single string rather than an array for one keyword.
        if let list = iptc[kCGImagePropertyIPTCKeywords] as? [String] { return list }
        if let single = iptc[kCGImagePropertyIPTCKeywords] as? String { return [single] }
        return []
    }

    /// True if the file carries an HDR gain map in either the Apple-specific or
    /// the ISO 21496-1 form. Modern iPhone photos rely on this for their HDR
    /// look; dropping it silently changes how the picture appears.
    public static func hasGainMap(_ src: CGImageSource) -> Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil {
            return true
        }
        if #available(macOS 15.0, *) {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
                return true
            }
        }
        return false
    }

    /// True when the file is a JPEG according to ImageIO itself, not its extension.
    public static func isJPEG(_ facts: ImageFacts) -> Bool {
        guard let t = facts.typeIdentifier else { return false }
        return UTType(t) == .jpeg
    }
}
