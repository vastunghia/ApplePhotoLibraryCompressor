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
    /// A month converted out of sequence would therefore land at the end of its
    /// year rather than in date order, which is what `folderInsertionIndex`
    /// exists to prevent — for folders created from then on, since an existing
    /// one cannot be moved.
    public static func monthFolder(_ key: MonthKey) -> String {
        String(format: "%04d-%02d", key.year, key.month)
    }

    /// "2019". The folder a year's months live in.
    public static func yearFolder(_ year: Int) -> String {
        String(format: "%04d", year)
    }

    /// The folders enclosing a month's albums, outermost first: `"2019-07"` lives
    /// at `["2019", "2019-07"]`, below `rootFolder`.
    ///
    /// The month name stays the identifier every command passes around — it is
    /// unique on its own, and recovering the year from it is total — so the year
    /// layer was added without touching a single caller.
    ///
    /// `undated` has no year and gets none: inventing one is exactly what
    /// `undatedFolder` exists to refuse. A name shaped like neither degrades to
    /// itself rather than to a folder called `"undat"`.
    public static func folderPath(forFolderNamed name: String) -> [String] {
        guard let year = yearPrefix(of: name) else { return [name] }
        return [year, name]
    }

    /// The `YYYY` of a `YYYY-MM` name, or nil if it is not one.
    private static func yearPrefix(of name: String) -> String? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 4, parts[0].allSatisfy(\.isNumber),
              parts[1].count == 2, parts[1].allSatisfy(\.isNumber)
        else { return nil }
        return String(parts[0])
    }

    /// Where a new folder goes among the ones already beside it.
    ///
    /// The folder counterpart to `insertionIndex`, and the same "count of those
    /// that should precede it" rule — but ranked by date rather than by workflow,
    /// so a month converted late still lands in its chronological place. The
    /// names are zero-padded, so comparing them as text *is* comparing dates.
    ///
    /// Anything not shaped like `YYYY` or `YYYY-MM` — `undated`, a folder the
    /// user made himself — ranks after all of them and keeps its place, for the
    /// same reason an album we do not know about does.
    public static func folderInsertionIndex(for name: String, among existingNames: [String]) -> Int {
        func isDated(_ name: String) -> Bool {
            if yearPrefix(of: name) != nil { return true }
            return name.count == 4 && name.allSatisfy(\.isNumber)
        }
        // A dated name precedes an undated one; two dated ones compare as text.
        func precedes(_ a: String, _ b: String) -> Bool {
            switch (isDated(a), isDated(b)) {
            case (true, false): return true
            case (false, true): return false
            case (false, false): return false
            case (true, true): return a < b
            }
        }
        return existingNames.filter { precedes($0, name) }.count
    }

    /// How a month's album reads in output: `aplc workspace > 2019 > 2019-07 >
    /// Selected Originals`.
    ///
    /// Spelled the way the user would find it in the sidebar, and in one place so
    /// that a change to the tree cannot leave four hand-built strings behind.
    public static func displayPath(album: String, inFolderNamed folder: String) -> String {
        (([rootFolder] + folderPath(forFolderNamed: folder)) + [album])
            .joined(separator: " > ")
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
