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

    /// The twelve months of a year, in order.
    ///
    /// A year of work is a loop over these, never a wider fetch: the unit of
    /// work stays the month, so every folder, every staging directory and every
    /// answer to "already converted" is the same as if the month had been asked
    /// for on its own.
    public static func months(inYear year: Int) -> [MonthKey] {
        (1...12).map { MonthKey(year: year, month: $0) }
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

    /// The JPEGs whose copy `apply` created — the ones the user may now delete.
    ///
    /// Only ever filled by `apply`, and only for a copy it created itself in a
    /// run it watched. A photo skipped because a copy already existed does *not*
    /// go in, even though its copy is right there: this album is an invitation to
    /// delete, so the standard for entering it is having made and verified the
    /// replacement, not having found one.
    public static let convertedOriginalsAlbum = "Compressed Originals"

    /// The copies whose original was in an iCloud Shared Photo Library.
    ///
    /// A copy is always created in the personal library — no supported route can
    /// put it in a shared scope — so re-sharing is a manual step, and this album
    /// is what turns it into one gesture instead of a re-selection.
    ///
    /// Same narrow rule as `convertedOriginalsAlbum`: only a copy `apply` created
    /// in a run it watched, and only when the original's membership could
    /// actually be read. An original whose scope is unknown stays out, and the
    /// asymmetry is deliberate — failing to re-share a photo is a step the user
    /// repeats by hand, whereas moving a personal photo into a shared library
    /// publishes it to other people.
    public static let sharedCopiesAlbum = "Compressed Copies - to Share"

    /// The order the albums appear in inside a month folder.
    ///
    /// It follows the workflow rather than the alphabet: what was selected, what
    /// may now be deleted, what replaced it, and what still has to be re-shared.
    ///
    /// **Measured, not assumed: Photos shows a folder's albums in the order the
    /// collection holds them, and takes no notice of their titles.** Verified on
    /// 2026-08-09 against a real month, which is what makes this array worth
    /// having — an alphabetical sidebar would have ignored it entirely. The
    /// consequence is that the order is only reachable at creation time, since a
    /// new album otherwise lands at the end: see `insertionIndex`. A folder built
    /// before this array existed keeps the order it was built in, because the
    /// call that would reorder it (`PHCollectionListChangeRequest`'s move) is on
    /// the forbidden list in `SafetyInvariantTests` and stays there.
    public static let albumOrder = [
        originalsAlbum, convertedOriginalsAlbum, copiesAlbum, sharedCopiesAlbum,
    ]

    /// Where a new album goes among the ones already in its folder.
    ///
    /// An album the user made himself is not in `albumOrder`, so it ranks last
    /// and keeps its place: a workspace album is inserted above it rather than
    /// shuffling anything he arranged. The result is always a valid insertion
    /// point for `existingTitles`.
    public static func insertionIndex(for title: String, among existingTitles: [String]) -> Int {
        func rank(_ title: String) -> Int {
            albumOrder.firstIndex(of: title) ?? albumOrder.count
        }
        let mine = rank(title)
        return existingTitles.filter { rank($0) < mine }.count
    }

    /// "2026-02", zero-padded so that any text sort of these names is also
    /// chronological — October after February rather than before it.
    ///
    /// That is a property of the names, and it is all this comment claims now.
    /// It used to say "because Photos orders folders as text" — **measured on
    /// 2026-08-09 and false**: Photos shows month folders in collection order and
    /// ignores their names, exactly as it does the albums inside them (see
    /// `albumOrder`). The padding still earns its place, because it makes the
    /// names sort correctly everywhere *else* they are read — the CLI's own
    /// output, a shell, a report — and because `2026-2` beside `2026-11` is worse
    /// to read. It just is not what puts them in order in the sidebar.
    ///
    /// The consequence, unfixed: a month converted out of sequence lands at the
    /// **end** of `aplc workspace`, not in its chronological place, and nothing
    /// here can move it afterwards. Applying `insertionIndex`'s trick to
    /// `Importer.ensureFolder` would fix it for folders made from then on.
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
