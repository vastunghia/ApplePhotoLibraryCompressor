import Foundation

/// A month of work, as an address in the workspace.
public struct MonthKey: Hashable, Sendable, Comparable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public static func < (a: MonthKey, b: MonthKey) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }
}

/// Where the tool puts things in the photo library, and what it calls them.
///
/// The names live here and nowhere else: they appear in the user's sidebar, in
/// the CLI's own suggestions and in the album lookups, and three copies of a
/// string that must agree is three chances to disagree.
public enum WorkspaceLayout {
    /// Named after the tool rather than after the work, so it is obvious in the
    /// sidebar that something else maintains this folder.
    public static let rootFolder = "aplc workspace"

    /// The album `select` fills with the JPEGs still to convert.
    public static let originalsAlbum = "Selected Originals"

    /// The album `apply` puts the new HEICs in.
    public static let copiesAlbum = "Compressed Copies"

    /// "2026-02". Zero-padded so the folders sort chronologically in Photos,
    /// which orders them as text.
    public static func monthFolder(_ key: MonthKey) -> String {
        String(format: "%04d-%02d", key.year, key.month)
    }

    /// Where a copy of an undated photo goes.
    ///
    /// `select` offers a photo with no capture date rather than guessing about
    /// it, so `apply` can be handed one. Filing it under some month anyway would
    /// be inventing the fact the whole workspace is organised by; a folder that
    /// says "undated" is the honest place, and it sorts below the years.
    public static let undatedFolder = "undated"

    /// The folder a photo belongs in, by its capture date.
    public static func folder(for date: Date?, calendar: Calendar = .current) -> String {
        guard let date else { return undatedFolder }
        return monthFolder(month(of: date, calendar: calendar))
    }

    /// The month a photo belongs to, by its capture date.
    ///
    /// Same caveat as `MonthBounds.range`, and for the same reason: the machine's
    /// calendar decides, so a photo taken near midnight on the last of the month
    /// in a distant timezone can be filed next door. It is the one place a copy
    /// could land in a different folder than its original — which is harmless,
    /// because both are filed by the *original's* date, so the pair stays
    /// together whichever side of the boundary it falls.
    public static func month(of date: Date, calendar: Calendar = .current) -> MonthKey {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return MonthKey(year: parts.year ?? 0, month: parts.month ?? 0)
    }
}
