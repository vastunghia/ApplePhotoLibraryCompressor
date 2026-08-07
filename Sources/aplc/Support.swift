import APLCCore
import ArgumentParser
import Foundation
import Photos

/// Which photos a command works on: a month of the workspace, a whole year of
/// it, or a named album.
///
/// The two forms are exclusive. `--year`/`--month` is the normal way in, and
/// resolves to `aplc workspace` > `2026-02` > `Selected Originals`, the album
/// `select` fills. `--year` on its own means all twelve months of that year.
/// `--album` is the escape hatch for an album made by hand, and keeps the
/// behaviour every command had before the workspace existed.
struct SourceAlbumOptions: ParsableArguments {
    @Option(help: "Year the photos were taken, e.g. 2019.")
    var year: Int?

    @Option(help: "Month the photos were taken, 1 to 12. Omit to work the whole year.")
    var month: Int?

    @Option(help: "Work on this album by name instead of a month of the workspace.")
    var album: String?

    var isEmpty: Bool { year == nil && month == nil && album == nil }

    /// Checks that what was given makes sense together. Says nothing about
    /// whether *something* was given: `calibrate` can work from `--files` and
    /// needs no album at all, so that requirement belongs to each command.
    func validate() throws {
        if album != nil, year != nil || month != nil {
            throw ValidationError("--album and --year/--month are alternatives; give one or the other.")
        }
        guard album == nil, !isEmpty else { return }

        guard let year else {
            throw ValidationError("--month needs --year; give both, or --year alone for the whole year.")
        }
        if let month, !(1...12).contains(month) {
            throw ValidationError("--month must be between 1 and 12, not \(month).")
        }
        guard (1...9999).contains(year) else {
            throw ValidationError("--year must be a four-digit year, not \(year).")
        }
    }

    /// For the commands that cannot work without an album.
    func requireSelection() throws {
        if isEmpty { throw ValidationError("give either --year and --month, or --album.") }
    }

    /// Nil when the command was pointed at a named album instead, and nil for a
    /// whole year — a year has no single album, which is what `scopes` is for.
    var monthKey: MonthKey? {
        guard let year, let month, album == nil else { return nil }
        return MonthKey(year: year, month: month)
    }

    /// True when `--year` was given without `--month`.
    var isWholeYear: Bool { year != nil && month == nil && album == nil }

    /// The months this selection covers, in order. Empty in `--album` mode.
    var months: [MonthKey] {
        guard album == nil, let year else { return [] }
        if let month { return [MonthKey(year: year, month: month)] }
        return MonthKey.months(inYear: year)
    }

    /// The per-month selections this one expands to: exactly `[self]` unless a
    /// bare `--year` was given.
    ///
    /// This is the only place a year becomes twelve months. Everything
    /// downstream — `resolve`, `monthKey`, `displayName`, the arguments handed
    /// to a delegated command — still sees one month at a time and is unchanged
    /// by the year existing.
    var scopes: [SourceAlbumOptions] {
        guard isWholeYear else { return [self] }
        return months.map { key in
            var scope = self
            scope.year = key.year
            scope.month = key.month
            return scope
        }
    }

    /// Finds the album, and does not create one.
    ///
    /// Kept as the plain lookup for the `--album` path and for callers that have
    /// already refreshed the selection. `resolveRefreshingSelection` is the way
    /// in for everything else.
    func resolve() throws -> PHAssetCollection {
        if let album { return try PhotoLibraryAccess.findAlbum(titled: album) }
        // A whole year addresses twelve albums, so asking it for one is a caller
        // that forgot to loop over `scopes`. Said out loud rather than left to a
        // force-unwrap, which would end the run with a crash and no reason.
        guard let key = monthKey else {
            throw ValidationError("a whole year covers twelve albums; work through --year one month at a time.")
        }
        return try PhotoLibraryAccess.findWorkspaceAlbum(
            WorkspaceLayout.originalsAlbum,
            inFolderNamed: WorkspaceLayout.monthFolder(key)
        )
    }

    /// Whether this command should run `select` for itself first.
    ///
    /// Only in month mode. A `--album` that does not exist is a typo, and
    /// creating an empty album to then report nothing about is exactly the
    /// mistake the old "never creates one" rule existed to prevent — that rule
    /// survives here, narrowed to the case where it was right.
    var shouldRefreshSelection: Bool { monthKey != nil }

    /// Brings the month's selection up to date, then resolves the album.
    ///
    /// Returns nil when the month has nothing left to convert, which is an
    /// ordinary outcome and not an error: without this the caller would fail
    /// with `no folder named "aplc workspace"` on a month it had simply already
    /// finished.
    func resolveRefreshingSelection(verbose: Bool = false) async throws -> PHAssetCollection? {
        guard let key = monthKey else { return try resolve() }

        let outcome = try await Select.fill(year: key.year, month: key.month,
                                            into: nil, verbose: verbose)
        guard let destination = outcome.destination else {
            // Nothing was created, so there may be no album at all. If a previous
            // run left one, work on it: it can still hold photos this month's
            // fresh selection no longer offers.
            return try? resolve()
        }
        if outcome.added > 0 {
            print("Selected \(outcome.added) more photo(s) into \(displayName).")
        }
        return destination
    }

    /// How to name this album in output, spelled the way the user would find it.
    var displayName: String {
        if let album { return "\"\(album)\"" }
        if let key = monthKey {
            return "\(WorkspaceLayout.rootFolder) > \(WorkspaceLayout.monthFolder(key)) > \(WorkspaceLayout.originalsAlbum)"
        }
        if isWholeYear, let year { return "\(year), all twelve months" }
        return "the selected album"
    }

    /// What to say when there is nothing to work on. One wording, so a month
    /// already finished reads the same whichever command found that out.
    var nothingLeftMessage: String {
        if let key = monthKey {
            return "Nothing in \(MonthBounds.label(year: key.year, month: key.month)) "
                 + "is left to convert. Nothing was created."
        }
        if isWholeYear, let year {
            return "Nothing in \(year) is left to convert. Nothing was created."
        }
        return "Nothing in \(displayName) can be converted."
    }

    /// The same choice, as arguments — so `convert` can hand it to the commands
    /// it drives without deciding anything itself.
    var forwardedArguments: [String] {
        if let album { return ["--album", album] }
        guard let year else { return [] }
        guard let month else { return ["--year", "\(year)"] }
        return ["--year", "\(year)", "--month", "\(month)"]
    }
}

/// Where a command keeps its working files.
///
/// There is no visible option any more. Staged HEICs and exported originals are
/// scaffolding — the copy that matters ends up in the library, and the record of
/// it ends up in the ledger — so the default is a temporary directory that is
/// removed when the run ends and leaves nothing behind.
///
/// `--staging-dir` is the way to pin it somewhere durable, which is what makes
/// `transcode` and `apply` still composable as two separate invocations. Hidden
/// because it is for taking a pipeline apart, not for ordinary use.
struct StagingOptions: ParsableArguments {
    @Option(name: .customLong("staging-dir"), help: .hidden)
    var stagingDir: String?

    func makeArea() throws -> StagingArea { try StagingArea(pinnedTo: stagingDir) }

    /// A staging area of its own for one month of a longer run.
    ///
    /// A year is twelve runs, and they must not share a root: `verify` and
    /// `apply` scope themselves by staging path, so a shared root would have
    /// December re-checking January's files. Under a pinned root each month
    /// gets a subdirectory of it, which stays pinned — and so is still never
    /// deleted by this tool.
    func makeArea(named subdirectory: String) throws -> StagingArea {
        guard let stagingDir else { return try StagingArea() }
        let path = URL(fileURLWithPath: stagingDir, isDirectory: true)
            .appendingPathComponent(subdirectory, isDirectory: true).path
        return try StagingArea(pinnedTo: path)
    }
}

/// Where the journal lives. Persistent, and no longer part of staging.
struct LedgerOptions: ParsableArguments {
    @Option(name: .customLong("ledger"), help: .hidden)
    var ledger: String?

    func url() throws -> URL {
        if let ledger { return URL(fileURLWithPath: ledger).standardizedFileURL }
        return try LedgerLocation.standard()
    }

    var forwardedArguments: [String] {
        guard let ledger else { return [] }
        return ["--ledger", ledger]
    }

    /// Says so when the journal has damage, rather than passing over it. A line
    /// lost to a hard stop costs nothing; a line lost silently is a hole in the
    /// only record of what was done to the library.
    func warnIfDamaged(_ read: LedgerRead) {
        guard read.unreadableLines > 0 else { return }
        let url = (try? self.url())?.path ?? LedgerLocation.filename
        FileHandle.standardError.write(Data("""
            warning: \(read.unreadableLines) unreadable line(s) in \(url) were skipped.
            """.appending("\n").utf8))
    }
}

struct GateOptions: ParsableArguments {
    // Deliberately without a default: omitting it selects the automatic search,
    // which picks a quality per asset to meet --min-ssim. Giving this a default
    // would make the manual path the silent one, and a default that the search
    // then overrode would be worse still — an option that appears to control the
    // output while doing nothing.
    //
    // ImageIO quantises the value into buckets rather than honouring every one:
    // see QualityLadder for the measured rungs. Anything between them rounds
    // down, so 0.80 and 0.85 give byte-identical files.
    @Option(help: "HEIC quality, 0.0 to 1.0. Omit to choose it per photo from --min-ssim.")
    var quality: Double?

    // 0.97 rather than something stricter: on real library photos q=0.8 lands
    // around 0.984 mean SSIM with outliers near 0.97, so a higher bar rejects
    // perfectly good conversions. Use `calibrate` to set this from your own set.
    //
    // In automatic mode this stops being a veto and becomes the objective — the
    // search returns the cheapest rung reaching it. The gate still checks it,
    // which is then a tautology; that is intentional, since the gate is also
    // what `verify` re-runs later against files it did not encode.
    @Option(name: .customLong("min-ssim"),
            help: "Target SSIM: the fidelity every converted photo must reach.")
    var minSSIM: Double = 0.97

    @Option(name: .customLong("max-size-ratio"),
            help: "Reject conversions whose HEIC exceeds this fraction of the JPEG's size.")
    var maxSizeRatio: Double = 0.9

    @Flag(name: .customLong("strict-color-profile"),
          help: "Require the ICC profile name to match exactly, not just be present.")
    var strictColorProfile: Bool = false

    func policy(allowDownloads: Bool) -> GatePolicy {
        GatePolicy(
            minSSIM: minSSIM,
            maxSizeRatio: maxSizeRatio,
            allowDownloads: allowDownloads,
            requireExactProfileMatch: strictColorProfile
        )
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.2f %@", value, units[unit])
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// PHAsset local identifiers contain slashes ("UUID/L0/001"), which cannot
    /// go into a filename.
    static func safeFilename(for localIdentifier: String) -> String {
        localIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    static func table(_ rows: [(String, String)], indent: String = "  ") -> String {
        guard let widest = rows.map(\.0.count).max() else { return "" }
        return rows
            .map { "\(indent)\($0.0.padding(toLength: widest, withPad: " ", startingAt: 0))  \($0.1)" }
            .joined(separator: "\n")
    }
}

extension Double {
    var clampedToUnitInterval: Double { Swift.min(Swift.max(self, 0), 1) }
}
