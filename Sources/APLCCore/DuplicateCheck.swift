import Foundation

/// An asset already in the library that a staged file might duplicate.
public struct LibraryCopy: Sendable, Equatable {
    public let localIdentifier: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(localIdentifier: String, pixelWidth: Int, pixelHeight: Int) {
        self.localIdentifier = localIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum DuplicateVerdict: Sendable, Equatable {
    /// Nothing in the library shares this pair identity.
    case none
    /// A copy exists and is the same image, byte for byte.
    case identical(LibraryCopy)
    /// A copy exists and is demonstrably a different file.
    case differs(LibraryCopy, reason: String)
    /// A copy exists and could not be compared.
    case unknown(LibraryCopy, reason: String)

    public var existing: LibraryCopy? {
        switch self {
        case .none: return nil
        case .identical(let c): return c
        case .differs(let c, _), .unknown(let c, _): return c
        }
    }
}

/// Whether a staged HEIC would be a second copy of something already imported.
///
/// The ledger cannot answer this. It makes `apply` idempotent within one staging
/// directory and knows nothing of any other, which is exactly how the library
/// came to hold three copies of some photos: a fresh staging folder pointed at
/// the same album converts and imports everything again. So the question is put
/// to the library, using the same pair identity `select` uses — same filename
/// stem, same capture second — because that is what `apply` gives every copy it
/// creates.
public enum DuplicateCheck {
    /// Groups existing copies by the identity a converted copy would carry.
    public static func index(
        _ copies: [(key: TwinKey, copy: LibraryCopy)]
    ) -> [TwinKey: [LibraryCopy]] {
        var index: [TwinKey: [LibraryCopy]] = [:]
        for entry in copies {
            index[entry.key, default: []].append(entry.copy)
        }
        return index
    }

    /// The verdict, given what is free to know and — only when that is not
    /// enough — whether the bytes matched.
    ///
    /// `bytesEqual` is `nil` for "could not tell": an original that is only in
    /// iCloud with the download budget spent, or a read that failed. The caller
    /// is asked rather than told, because refusing to import on a comparison
    /// that never happened would silently drop a conversion.
    public static func verdict(
        stagedWidth: Int,
        stagedHeight: Int,
        stagedSHA256: String?,
        existing: LibraryCopy,
        bytesEqual: Bool?
    ) -> DuplicateVerdict {
        // Geometry first because it costs nothing, and because two images of
        // different size are never the same file — no need to fetch anything.
        guard stagedWidth == existing.pixelWidth, stagedHeight == existing.pixelHeight else {
            return .differs(existing, reason: """
                \(stagedWidth)x\(stagedHeight) staged vs \
                \(existing.pixelWidth)x\(existing.pixelHeight) in the library
                """)
        }
        guard stagedSHA256 != nil else {
            return .unknown(existing, reason: "the staged file has no recorded digest")
        }
        switch bytesEqual {
        case .some(true):
            return .identical(existing)
        case .some(false):
            return .differs(existing, reason: "same dimensions, different content")
        case nil:
            return .unknown(existing, reason: "the existing copy could not be read to compare")
        }
    }

    /// What to do with a verdict, before asking anyone.
    public enum Resolution: Sendable, Equatable {
        case importIt
        case skip(SkipReason, detail: String, collidedWith: String)
        case ask(LibraryCopy, question: String)
    }

    /// An identical copy needs no question — there is nothing to decide, and a
    /// prompt per photo on a long run would be noise. Everything else is the
    /// user's call.
    public static func resolution(for verdict: DuplicateVerdict) -> Resolution {
        switch verdict {
        case .none:
            return .importIt
        case .identical(let copy):
            return .skip(.duplicateInLibrary,
                         detail: "an identical copy is already in the library",
                         collidedWith: copy.localIdentifier)
        case .differs(let copy, let reason):
            return .ask(copy, question: "a copy exists but differs — \(reason)")
        case .unknown(let copy, let reason):
            return .ask(copy, question: "a copy exists — \(reason)")
        }
    }
}
