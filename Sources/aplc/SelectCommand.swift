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

            Re-running is safe: photos already in the album are not added twice.

            This is the only command that reads outside a named album, which it
            must in order to build one. Every other command stays scoped to the
            album you point it at.
            """
    )

    @Option(help: "Year the photos were taken, e.g. 2019.")
    var year: Int

    @Option(help: "Month the photos were taken, 1 to 12.")
    var month: Int

    @Option(help: "Title of the album to fill. Created if it does not exist.")
    var album: String

    @Flag(help: "Print one line per photo instead of only the summary.")
    var verbose: Bool = false

    func validate() throws {
        guard (1...12).contains(month) else {
            throw ValidationError("--month must be between 1 and 12, not \(month).")
        }
        guard (1...9999).contains(year) else {
            throw ValidationError("--year must be a four-digit year, not \(year).")
        }
    }

    func run() async throws {
        let range = try MonthBounds.range(year: year, month: month)
        let label = MonthBounds.label(year: year, month: month)

        try await PhotoLibraryAccess.authorize()

        let assets = PhotoLibraryAccess.imageAssets(createdIn: range)
        guard !assets.isEmpty else {
            print("No photos were taken in \(label). Nothing to do.")
            return
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
            report(selection, label: label, alreadyInAlbum: 0, added: 0)
            print("\nNothing in \(label) is left to convert. The album was not created.")
            return
        }

        let destination = try await Importer.ensureAlbum(titled: album)
        let existing = PhotoLibraryAccess.identifiers(in: destination)
        let toAdd = selection.candidates
            .filter { !existing.contains($0.localIdentifier) }
            .compactMap { assetsByIdentifier[$0.localIdentifier] }

        try await Importer.add(toAdd, to: destination)

        report(selection,
               label: label,
               alreadyInAlbum: selection.candidates.count - toAdd.count,
               added: toAdd.count)

        print("""

            Your photos are untouched — an album holds references, not copies, and \
            nothing was deleted.

            Next: aplc convert --album "\(album)" --out ./staging --dest-album "\(album) HEIC"
            """)
    }

    private func report(
        _ selection: CandidateSelection.Selection,
        label: String,
        alreadyInAlbum: Int,
        added: Int
    ) {
        print("\n\(label)")
        print(Format.table([
            ("photos in the month", "\(selection.considered)"),
            ("already HEIC", "\(selection.heicPresent)"),
            ("JPEGs already converted", "\(selection.alreadyConverted)"),
            ("JPEGs still to convert", "\(selection.candidates.count)"),
            ("already in \"\(album)\"", "\(alreadyInAlbum)"),
            ("added to \"\(album)\"", "\(added)"),
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
