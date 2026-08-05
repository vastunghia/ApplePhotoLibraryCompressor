import Foundation

/// The PhotoKit-side facts about an asset, lifted into a plain value type.
///
/// Keeping this free of `PHAsset` is what lets the gate be unit tested without a
/// photo library, and keeps the safety rules readable in one place.
public struct AssetTraits: Sendable, Equatable {
    public var localIdentifier: String
    public var originalFilename: String
    public var uniformTypeIdentifier: String?
    public var hasAdjustments: Bool
    public var isLivePhoto: Bool
    public var burstIdentifier: String?
    public var hasPairedVideoResource: Bool
    public var hasAdjustmentBaseResource: Bool
    public var isLocallyAvailable: Bool
    public var resourceByteCount: Int?
    /// Only used to pair a JPEG with the HEIC made from it, which inherits this
    /// value exactly. The gate itself never reads it.
    public var creationDate: Date?

    public init(
        localIdentifier: String,
        originalFilename: String,
        uniformTypeIdentifier: String? = nil,
        hasAdjustments: Bool = false,
        isLivePhoto: Bool = false,
        burstIdentifier: String? = nil,
        hasPairedVideoResource: Bool = false,
        hasAdjustmentBaseResource: Bool = false,
        isLocallyAvailable: Bool = true,
        resourceByteCount: Int? = nil,
        creationDate: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.hasAdjustments = hasAdjustments
        self.isLivePhoto = isLivePhoto
        self.burstIdentifier = burstIdentifier
        self.hasPairedVideoResource = hasPairedVideoResource
        self.hasAdjustmentBaseResource = hasAdjustmentBaseResource
        self.isLocallyAvailable = isLocallyAvailable
        self.resourceByteCount = resourceByteCount
        self.creationDate = creationDate
    }
}

/// Why an asset was not converted. Every skip is attributable to exactly one of
/// these, and every one of them is recorded in the ledger.
public enum SkipReason: String, Sendable, Codable, CaseIterable {
    case notAJPEG
    case hasAdjustments
    case livePhotoOrBurst
    case notLocallyAvailable
    case downloadBudgetExhausted
    case geometryChanged
    case gainMapLost
    case exifLost
    case gpsLost
    case tiffLost
    case orientationChanged
    case colorProfileLost
    case insufficientSaving
    case qualityBelowThreshold
    case alreadyApplied
    case transcodeFailed

    public var explanation: String {
        switch self {
        case .notAJPEG: return "original resource is not a JPEG"
        case .hasAdjustments: return "asset has edits that the create-new-asset path cannot carry over"
        case .livePhotoOrBurst: return "Live Photo or burst member; paired resources would be lost"
        case .notLocallyAvailable: return "original is not on disk and downloads are disabled"
        case .downloadBudgetExhausted: return "original is iCloud-only and the download budget is spent"
        case .geometryChanged: return "encoded image has different pixel dimensions"
        case .gainMapLost: return "source has an HDR gain map that the HEIC does not"
        case .exifLost: return "EXIF present in the source is missing from the HEIC"
        case .gpsLost: return "GPS present in the source is missing from the HEIC"
        case .tiffLost: return "TIFF metadata present in the source is missing from the HEIC"
        case .orientationChanged: return "orientation differs between source and HEIC"
        case .colorProfileLost: return "colour profile present in the source is missing from the HEIC"
        case .insufficientSaving: return "HEIC is not meaningfully smaller than the JPEG"
        case .qualityBelowThreshold: return "SSIM below the configured threshold"
        case .alreadyApplied: return "already converted in a previous run"
        case .transcodeFailed: return "encoder returned an error"
        }
    }
}

public enum GateOutcome: Sendable, Equatable {
    case eligible
    case skip(SkipReason)

    public var isEligible: Bool { self == .eligible }
    public var skipReason: SkipReason? {
        if case .skip(let r) = self { return r }
        return nil
    }
}

public struct GatePolicy: Sendable, Equatable {
    /// Minimum mean SSIM for a conversion to be accepted.
    public var minSSIM: Double
    /// The HEIC must be at most this fraction of the JPEG's size to be worth it.
    public var maxSizeRatio: Double
    /// Whether iCloud-only originals may be downloaded at all.
    public var allowDownloads: Bool
    /// Require the ICC profile name to match exactly, not merely be present.
    public var requireExactProfileMatch: Bool

    public init(
        minSSIM: Double = 0.97,
        maxSizeRatio: Double = 0.9,
        allowDownloads: Bool = true,
        requireExactProfileMatch: Bool = false
    ) {
        self.minSSIM = minSSIM
        self.maxSizeRatio = maxSizeRatio
        self.allowDownloads = allowDownloads
        self.requireExactProfileMatch = requireExactProfileMatch
    }

    public static let `default` = GatePolicy()
}

public enum EligibilityGate {
    /// Checks that can be answered before spending any time on transcoding.
    public static func evaluatePreConditions(_ t: AssetTraits, policy: GatePolicy = .default) -> GateOutcome {
        // 1. Must be a JPEG original.
        guard let uti = t.uniformTypeIdentifier, uti == "public.jpeg" else {
            return .skip(.notAJPEG)
        }
        // 2. No edits: the create-new-asset path cannot carry adjustment history.
        if t.hasAdjustments || t.hasAdjustmentBaseResource {
            return .skip(.hasAdjustments)
        }
        // 3. No Live Photos or bursts: their paired resources and grouping would
        //    not survive, and rebuilding them is too fragile to risk here.
        if t.isLivePhoto || t.burstIdentifier != nil || t.hasPairedVideoResource {
            return .skip(.livePhotoOrBurst)
        }
        // 4. Availability.
        if !t.isLocallyAvailable && !policy.allowDownloads {
            return .skip(.notLocallyAvailable)
        }
        return .eligible
    }

    /// Checks performed by re-reading the HEIC that was actually written.
    ///
    /// This is the half that matters: the encoder is never taken at its word.
    public static func evaluatePostConditions(
        source: ImageFacts,
        destination: ImageFacts,
        quality: QualityScore?,
        policy: GatePolicy = .default
    ) -> GateOutcome {
        // 6. Geometry must be untouched.
        guard source.width == destination.width, source.height == destination.height else {
            return .skip(.geometryChanged)
        }
        // 4. Gain map: only required if the source had one.
        if source.hasGainMap && !destination.hasGainMap {
            return .skip(.gainMapLost)
        }
        // 5. Metadata blocks present in the source must reappear.
        if source.hasEXIF && !destination.hasEXIF { return .skip(.exifLost) }
        if source.hasGPS && !destination.hasGPS { return .skip(.gpsLost) }
        if source.hasTIFF && !destination.hasTIFF { return .skip(.tiffLost) }

        if let so = source.orientation {
            // A missing orientation tag means "1" (up); treat it as such rather
            // than failing an image that simply had nothing to preserve.
            let dO = destination.orientation ?? 1
            if so != dO { return .skip(.orientationChanged) }
        }

        if source.profileName != nil {
            guard let dp = destination.profileName else { return .skip(.colorProfileLost) }
            if policy.requireExactProfileMatch && dp != source.profileName {
                return .skip(.colorProfileLost)
            }
        }

        // 7. Must actually save space.
        guard source.byteCount > 0 else { return .skip(.insufficientSaving) }
        let ratio = Double(destination.byteCount) / Double(source.byteCount)
        if ratio > policy.maxSizeRatio { return .skip(.insufficientSaving) }

        // 8. Must be visually faithful.
        if let q = quality, q.ssim < policy.minSSIM {
            return .skip(.qualityBelowThreshold)
        }

        return .eligible
    }
}
