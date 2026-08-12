import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Select: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Writes to your library: gathers one month's unconverted JPEGs into an album.",
        discussion: """
            The album is the only thing written. Photos are added to it, never
            copied, moved or altered — an album holds references — and nothing is
            deleted. But it is a one-way door: no command here can take a photo
            back out of an album, so a wrong month is undone by hand in Photos.app.

            "Not converted yet" is answered by looking for the copy. `apply` gives
            each new HEIC its original's filename stem and its exact creation date,
            so a converted JPEG always has a matching HEIC in the same month, and
            one month's fetch sees both halves. That is a property of the library
            itself, so the answer survives deleting a staging folder or moving the
            copies into your Shared Library.

            The album goes in "aplc workspace" > "YYYY" > "YYYY-MM" >
            "Selected Originals", so each month's work sits together and the rest
            of the pipeline can find it from --year and --month alone. --album
            overrides that with a flat album of your own naming.

            Leave --month out and it does the whole year, one month's album at a
            time, and prints a total for the year at the end.

            Re-running is safe: photos already in the album are not added twice.

            This is the only command that reads outside a named album, which it
            must in order to build one. Every other command stays scoped to the
            album you point it at.
            """
    )

    @Option(help: "Year the photos were taken, e.g. 2019.")
    var year: Int

    @Option(help: "Month the photos were taken, 1 to 12. Omit to select the whole year.")
    var month: Int?

    @Option(help: "Fill this flat album instead of the workspace's month folder.")
    var album: String?

    @Flag(help: "Print one line per photo instead of only the summary.")
    var verbose: Bool = false

    func validate() throws {
        if let month, !(1...12).contains(month) {
            throw ValidationError("--month must be between 1 and 12, not \(month).")
        }
        guard (1...9999).contains(year) else {
            throw ValidationError("--year must be a four-digit year, not \(year).")
        }
    }

    /// Where a month's photos will go, spelled as the user would find it in Photos.
    private func destinationName(for key: MonthKey) -> String {
        if let album { return "\"\(album)\"" }
        return WorkspaceLayout.displayPath(album: WorkspaceLayout.originalsAlbum,
                                           inFolderNamed: WorkspaceLayout.monthFolder(key))
    }

    /// The months to fill: the one asked for, or all twelve of the year.
    private var months: [MonthKey] {
        guard let month else { return MonthKey.months(inYear: year) }
        return [MonthKey(year: year, month: month)]
    }

    func run() async throws {
        let months = self.months
        var yearTotals = Totals()

        for key in months {
            let outcome = try await Self.fill(year: key.year, month: key.month,
                                              into: album, verbose: verbose)
            yearTotals.add(outcome)

            guard outcome.destination != nil else {
                if outcome.selection.considered == 0 {
                    print("No photos were taken in \(outcome.label). Nothing to do.")
                } else {
                    report(outcome, for: key, alreadyInAlbum: 0, added: 0)
                    print("\nNothing in \(outcome.label) is left to convert. Nothing was created.")
                }
                continue
            }

            report(outcome, for: key,
                   alreadyInAlbum: outcome.alreadyInAlbum, added: outcome.added)
        }

        if months.count > 1 {
            print("\n\(year)")
            print(Format.table([
                ("photos in the year", "\(yearTotals.considered)"),
                ("JPEGs already converted", "\(yearTotals.alreadyConverted)"),
                ("JPEGs still to convert", "\(yearTotals.candidates)"),
                ("added to the workspace", "\(yearTotals.added)"),
            ]))
        }

        let next: String
        if let album {
            next = "--album \"\(album)\""
        } else if let month {
            next = "--year \(year) --month \(month)"
        } else {
            next = "--year \(year)"
        }
        print("""

            Your photos are untouched — an album holds references, not copies, and \
            nothing was deleted.

            Next: aplc convert \(next)
            """)
    }

    /// What a year came to, summed as the months go by.
    private struct Totals {
        var considered = 0
        var alreadyConverted = 0
        var candidates = 0
        var added = 0

        mutating func add(_ outcome: Outcome) {
            considered += outcome.selection.considered
            alreadyConverted += outcome.selection.alreadyConverted
            candidates += outcome.selection.candidates.count
            added += outcome.added
        }
    }

    private func report(
        _ outcome: Outcome,
        for key: MonthKey,
        alreadyInAlbum: Int,
        added: Int
    ) {
        let selection = outcome.selection
        let label = outcome.label
        print("\n\(label)")
        print(Format.table([
            ("photos in the month", "\(selection.considered)"),
            ("already HEIC", "\(selection.heicPresent)"),
            ("JPEGs already converted", "\(selection.alreadyConverted)"),
            ("JPEGs still to convert", "\(selection.candidates.count)"),
            ("already in the album", "\(alreadyInAlbum)"),
            ("added to \(destinationName(for: key))", "\(added)"),
        ]))

        let excluded = selection.skips.filter { $0.key != .alreadyApplied }
        if !excluded.isEmpty {
            print("\nWhy the rest are excluded")
            let rows = excluded
                .sorted { $0.value > $1.value }
                .map { ("\($0.key.rawValue)", "\($0.value)  — \($0.key.explanation)") }
            print(Format.table(rows))
        }
    }
}

// MARK: - The reusable half

extension Select {
    /// What one month's selection came to.
    struct Outcome {
        let label: String
        let selection: CandidateSelection.Selection

        /// nil when nothing was created, because there was nothing to put in it.
        /// That is an ordinary result, not a failure: it is what a month with no
        /// photos and a month already fully converted both look like, and the
        /// caller distinguishes them by `selection.considered`.
        let destination: PHAssetCollection?

        let added: Int
        let alreadyInAlbum: Int
    }

    /// Brings a month's `Selected Originals` up to date, creating the folder and
    /// album if they are not there yet.
    ///
    /// Split out of `run()` for the same reason as `Scan.census` and
    /// `Verify.verify`: every other command now calls it before doing its own
    /// work, and composing by calling the real thing beats a second
    /// implementation that can drift from it.
    static func fill(
        year: Int,
        month: Int,
        into album: String?,
        verbose: Bool = false
    ) async throws -> Outcome {
        let range = try MonthBounds.range(year: year, month: month)
        let label = MonthBounds.label(year: year, month: month)

        try await PhotoLibraryAccess.authorize()

        let assets = PhotoLibraryAccess.imageAssets(createdIn: range)
        guard !assets.isEmpty else {
            return Outcome(label: label,
                           selection: CandidateSelection.select(
                               among: [], policy: GatePolicy(allowDownloads: true)),
                           destination: nil, added: 0, alreadyInAlbum: 0)
        }
        // Reading each asset's resources is the slow part and it is linear, so
        // say how much there is before starting rather than appearing to hang.
        print("Examining \(assets.count) photo(s) from \(label).")

        var assetsByIdentifier: [String: PHAsset] = [:]
        var traits: [AssetTraits] = []
        traits.reserveCapacity(assets.count)
        for asset in assets {
            assetsByIdentifier[asset.localIdentifier] = asset
            traits.append(PhotoLibraryAccess.traits(for: asset))
        }

        // Downloads assumed allowed, as in `scan`: an iCloud-only original is a
        // candidate, and whether it can be fetched is `transcode`'s decision.
        let selection = CandidateSelection.select(
            among: traits, policy: GatePolicy(allowDownloads: true)
        )

        if verbose {
            for candidate in selection.candidates { print("  candidate  \(candidate.originalFilename)") }
        }

        guard !selection.candidates.isEmpty else {
            return Outcome(label: label, selection: selection,
                           destination: nil, added: 0, alreadyInAlbum: 0)
        }

        // Created only now that there is something to put in it: an empty
        // "2026-03" folder in the sidebar would be worse than no folder.
        let destination: PHAssetCollection
        if let album {
            destination = try await Importer.ensureAlbum(titled: album)
        } else {
            destination = try await Importer.ensureWorkspaceAlbum(
                WorkspaceLayout.originalsAlbum,
                inFolderNamed: WorkspaceLayout.monthFolder(MonthKey(year: year, month: month))
            )
        }
        let existing = PhotoLibraryAccess.identifiers(in: destination)
        let toAdd = selection.candidates
            .filter { !existing.contains($0.localIdentifier) }
            .compactMap { assetsByIdentifier[$0.localIdentifier] }

        // The count comes back from the album rather than from the request: an
        // add can be accepted and not made, so `toAdd.count` is what was asked
        // for and not what the user will see in the sidebar. See `Importer.add`.
        let added = try await Importer.add(toAdd, to: destination)

        return Outcome(label: label, selection: selection, destination: destination,
                       added: added,
                       alreadyInAlbum: selection.candidates.count - toAdd.count)
    }
}
