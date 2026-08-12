import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Repair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Rebuild a month's workspace albums from the journal. Converts nothing.",
        discussion: """
            For the case where a conversion worked and its albums did not fill.
            Adding photos to an album is a change the library can accept without
            making — `apply` now notices and says so, but a run from before that
            could leave a month whose copies are all present and whose
            "Compressed Originals" and "Compressed Copies - to Share" are empty.

            Nothing was lost when that happens and nothing needs converting again,
            so this rebuilds the three albums the journal can account for:
            "Compressed Copies", "Compressed Originals" and "Compressed Copies -
            to Share". "Selected Originals" is left alone — that one is `select`'s,
            and re-running it rebuilds it.

            It needs no staging directory, which is what makes it usable on a
            month converted months ago. It reads the journal for what was
            converted and asks the library which of it is still there: a copy you
            have since deleted is not put back, and an original you have deleted
            is not gathered for deletion a second time.

            Safe to run on a month that is already right — it adds only what is
            missing, and says so.
            """
    )

    @OptionGroup var ledgerOptions: LedgerOptions

    // Declared here rather than taken from `SourceAlbumOptions`, which every
    // other command uses: that group carries `--album`, and this command has no
    // meaning for it. The workspace albums are addressed by month — there is one
    // "Compressed Copies" per month, and a title has not identified an album
    // since the workspace gained folders. An option that can only ever be
    // refused does not belong in the help.
    @Option(help: "Year the photos were taken, e.g. 2019.")
    var year: Int

    @Option(help: "Month the photos were taken, 1 to 12. Omit to work the whole year.")
    var month: Int?

    func validate() throws {
        if let month, !(1...12).contains(month) {
            throw ValidationError("--month must be between 1 and 12, not \(month).")
        }
        guard (1...9999).contains(year) else {
            throw ValidationError("--year must be a four-digit year, not \(year).")
        }
    }

    /// The months asked for: one, or all twelve of a year.
    private var months: [MonthKey] {
        guard let month else { return MonthKey.months(inYear: year) }
        return [MonthKey(year: year, month: month)]
    }

    /// How the scope reads in output, the way the other commands spell theirs.
    private var displayName: String {
        guard let month else { return "\(year)" }
        return MonthBounds.label(year: year, month: month)
    }

    func run() async throws {
        let read = try Ledger.read(at: try ledgerOptions.url())
        ledgerOptions.warnIfDamaged(read)

        let conversions = RepairPlan.conversions(in: read.entries)
        guard !conversions.isEmpty else {
            print("""
                The journal records no conversions yet, so there is nothing to \
                rebuild from. Nothing was changed.
                """)
            return
        }

        try await PhotoLibraryAccess.authorize()

        let wanted = Set(months.map(WorkspaceLayout.monthFolder))

        // The journal records; the library decides — the same rule `apply`
        // follows, and for the same reason: the journal is permanent and goes on
        // naming copies long after they have been deleted. Fetching by identifier
        // answers "does it still exist" and "when was it taken" in one pass,
        // which is also what gives each pair its month.
        var copiesByIdentifier: [String: PHAsset] = [:]
        for asset in PhotoLibraryAccess.assets(withIdentifiers: conversions.map(\.copy)) {
            copiesByIdentifier[asset.localIdentifier] = asset
        }

        var wantedConversions: [(conversion: RepairPlan.Conversion, folder: String)] = []
        for conversion in conversions {
            guard let copy = copiesByIdentifier[conversion.copy] else { continue }
            let folder = WorkspaceLayout.folder(for: copy.creationDate)
            guard wanted.contains(folder) else { continue }
            wantedConversions.append((conversion, folder))
        }

        guard !wantedConversions.isEmpty else {
            print("""
                The journal records nothing converted in \(displayName) that \
                is still in your library. Nothing was changed.
                """)
            return
        }

        // Only now, and only for the months asked about: the second fetch is the
        // one that can be kept small.
        var sourcesByIdentifier: [String: PHAsset] = [:]
        for asset in PhotoLibraryAccess.assets(
            withIdentifiers: wantedConversions.map(\.conversion.source)
        ) {
            sourcesByIdentifier[asset.localIdentifier] = asset
        }

        let pairs = wantedConversions.map { item in
            let original = sourcesByIdentifier[item.conversion.source]
            return RepairPlan.Pair(
                source: item.conversion.source,
                copy: item.conversion.copy,
                folder: item.folder,
                sourceExists: original != nil,
                // Asked of the original, because the copy cannot answer: it is
                // created personal whatever its original was. A missing original
                // leaves the question unanswered rather than answered "no".
                sourceIsShared: original.flatMap(LibraryScope.isShared)
            )
        }

        var problems: [String] = []
        var totalAdded = 0

        for month in RepairPlan.months(pairs, limitedTo: wanted) {
            print("\n\(WorkspaceLayout.displayPath(folderNamed: month.folder))")

            var rows: [(String, String)] = []
            /// Files one album and reports it, or records why it could not.
            ///
            /// An album with nothing to file gets a line saying so rather than
            /// no line at all. Silence would make "already complete" and "there
            /// is nothing this command can put here" look identical, and on a
            /// month whose JPEGs have been deleted the second is the ordinary
            /// answer for two of the three albums.
            func file(_ identifiers: [String], into title: String, whenEmpty: String) async {
                guard !identifiers.isEmpty else {
                    rows.append((title, whenEmpty))
                    return
                }
                let assets = PhotoLibraryAccess.assets(withIdentifiers: identifiers)
                do {
                    let album = try await Importer.ensureWorkspaceAlbum(
                        title, inFolderNamed: month.folder
                    )
                    let existing = PhotoLibraryAccess.identifiers(in: album)
                    let toAdd = assets.filter { !existing.contains($0.localIdentifier) }
                    let added = try await Importer.add(toAdd, to: album)
                    totalAdded += added
                    rows.append((title, "\(assets.count - toAdd.count) there, \(added) added"))
                } catch {
                    problems.append(
                        "\(WorkspaceLayout.displayPath(album: title, inFolderNamed: month.folder)): \(error)"
                    )
                    rows.append((title, "failed"))
                }
            }

            // In workflow order, so the report reads like the sidebar.
            let unanswerable = month.unknownScopeCopies.count
            await file(
                month.originals, into: WorkspaceLayout.convertedOriginalsAlbum,
                whenEmpty: "nothing to file — no original of these copies is in the library"
            )
            await file(month.copies, into: WorkspaceLayout.copiesAlbum,
                       whenEmpty: "nothing to file")
            await file(
                month.sharedCopies, into: WorkspaceLayout.sharedCopiesAlbum,
                whenEmpty: unanswerable > 0
                    ? "nothing to file — \(unanswerable) original(s) could not be asked"
                    : "nothing to file — no original was in a shared library"
            )
            print(Format.table(rows))

            // Counted against the album rather than in the abstract: on a month
            // whose JPEGs are long deleted every copy has an unanswerable scope,
            // and saying so about copies that are already in the album would be
            // noise on top of a finished month.
            if !month.unknownScopeCopies.isEmpty {
                let inAlbum = (try? PhotoLibraryAccess.findWorkspaceAlbum(
                    WorkspaceLayout.sharedCopiesAlbum, inFolderNamed: month.folder
                )).map(PhotoLibraryAccess.identifiers(in:)) ?? []
                let missing = month.unknownScopeCopies.filter { !inAlbum.contains($0) }
                if !missing.isEmpty {
                    print("""
                          \(missing.count) copy/copies were left out of \
                        "\(WorkspaceLayout.sharedCopiesAlbum)": their original is no longer \
                        in the library, or its shared-library membership could not be read, \
                        so the question could not be answered. Left out rather than guessed \
                        in — check them by hand if you share this month.
                        """)
                }
            }
        }

        if !problems.isEmpty {
            print("\nAlbums that did not take everything")
            for problem in problems { print("  \(problem)") }
            print("\nNothing was lost. Run this again, or add those photos by hand.")
            throw ExitCode.failure
        }

        print(totalAdded == 0
            ? "\nEverything the journal accounts for is already in its album. Nothing was changed."
            : "\nAdded \(totalAdded) photo(s). Your originals are untouched; nothing was deleted.")
    }
}
