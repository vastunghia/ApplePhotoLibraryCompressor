import Foundation

public enum MonthBoundsError: Error, CustomStringConvertible {
    case invalidMonth(Int)
    case unrepresentable(year: Int, month: Int)

    public var description: String {
        switch self {
        case .invalidMonth(let m): return "month must be between 1 and 12, not \(m)"
        case .unrepresentable(let y, let m): return "\(y)-\(m) is not a date this calendar can express"
        }
    }
}

public enum MonthBounds {
    /// The half-open interval covering one calendar month.
    ///
    /// Half-open on purpose: a closed range would need the last representable
    /// instant of the month, and "before the first of next month" has no such
    /// edge to get wrong.
    ///
    /// The calendar is the machine's, so a photo taken at 23:00 on the 31st in
    /// another timezone can land in the neighbouring month. Photos itself shows
    /// capture-local time, so the two can disagree at the boundary; solving it
    /// would need per-asset timezone data that PhotoKit does not expose.
    public static func range(year: Int, month: Int, calendar: Calendar = .current) throws -> Range<Date> {
        guard (1...12).contains(month) else { throw MonthBoundsError.invalidMonth(month) }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1

        guard let start = calendar.date(from: components),
              let end = calendar.date(byAdding: .month, value: 1, to: start)
        else {
            throw MonthBoundsError.unrepresentable(year: year, month: month)
        }
        return start..<end
    }

    /// "July 2019", in English regardless of locale — this is a program's output,
    /// not a date shown to a reader in their own language.
    public static func label(year: Int, month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let date = Calendar.current.date(from: components) else { return "\(year)-\(month)" }
        return formatter.string(from: date)
    }
}

/// Identity of a converted pair: a JPEG and the HEIC made from it.
///
/// Both halves come from `Importer.createAsset`, which gives the new asset the
/// original's creation date and the original's filename stem. Nothing else about
/// a copy is distinguishable from a photo that was always HEIC.
public struct TwinKey: Hashable, Sendable {
    public let stem: String
    /// Whole seconds since the reference date. The date is copied across
    /// verbatim, so exact equality would very likely hold; rounding means a
    /// round trip through storage that perturbs the last bits cannot silently
    /// turn a converted photo back into a candidate.
    public let second: Int

    /// Fails when there is nothing to match on. An asset with no creation date
    /// is left unpaired rather than guessed at — the cost is offering a photo
    /// that was already converted, which is recoverable; the opposite is not.
    public init?(filename: String, creationDate: Date?) {
        guard let creationDate else { return nil }
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        guard !stem.isEmpty else { return nil }
        self.stem = stem
        self.second = Int(creationDate.timeIntervalSinceReferenceDate.rounded())
    }
}

/// Works out which JPEGs in a set are worth converting and have not been already.
///
/// PhotoKit has no concept of "already converted": no asset knows a copy of it
/// exists. What makes the question answerable is the pairing above, plus the
/// fact that a copy inherits its original's creation date — so both halves of
/// every pair fall in the same month, and one month's fetch sees both.
///
/// Deliberately not the ledger, which only knows about staging directories that
/// still exist; and deliberately not the destination album, which would tie the
/// answer to those copies staying where `apply` put them.
public enum CandidateSelection {
    public struct Selection: Sendable {
        public var considered: Int = 0
        /// Assets already in HEIC — conversions and camera-native alike.
        public var heicPresent: Int = 0
        public var candidates: [AssetTraits] = []
        public var skips: [SkipReason: Int] = [:]

        public var alreadyConverted: Int { skips[.alreadyApplied] ?? 0 }

        public init() {}
    }

    public static func select(among assets: [AssetTraits], policy: GatePolicy = .default) -> Selection {
        var twins: Set<TwinKey> = []
        for asset in assets where asset.uniformTypeIdentifier == "public.heic" {
            if let key = TwinKey(filename: asset.originalFilename, creationDate: asset.creationDate) {
                twins.insert(key)
            }
        }

        var selection = Selection()
        selection.considered = assets.count

        for asset in assets {
            if asset.uniformTypeIdentifier == "public.heic" { selection.heicPresent += 1 }

            // The twin check runs before the gate so an already-converted photo
            // is reported as converted, rather than as whatever else it also is.
            if asset.uniformTypeIdentifier == "public.jpeg",
               let key = TwinKey(filename: asset.originalFilename, creationDate: asset.creationDate),
               twins.contains(key) {
                selection.skips[.alreadyApplied, default: 0] += 1
                continue
            }

            switch EligibilityGate.evaluatePreConditions(asset, policy: policy) {
            case .eligible:
                selection.candidates.append(asset)
            case .skip(let reason):
                selection.skips[reason, default: 0] += 1
            }
        }
        return selection
    }
}
