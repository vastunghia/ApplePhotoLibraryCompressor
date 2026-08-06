import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Census an album: how many photos are convertible, and why the rest are not.",
        discussion: """
            Nothing is written to disk, and no asset is ever created or altered.

            With --year and --month it does bring the month's "Selected Originals"
            up to date first, which means adding photos to that album — the same
            work `select` does, so that a month you have never selected can be
            scanned without a preparatory command. Pass --album instead to report
            on an album exactly as it stands, writing nothing at all.

            Byte totals are deliberately absent: PhotoKit exposes no public API for
            a resource's file size, so the only honest way to measure the saving is
            to run `transcode`, which reports it from files it actually wrote.
            """
    )

    @OptionGroup var source: SourceAlbumOptions

    @Flag(help: "Print one line per asset instead of only the summary.")
    var verbose: Bool = false

    func validate() throws { try source.requireSelection() }

    func run() async throws {
        guard let census = try await Self.census(source: source, verbose: verbose) else {
            print(source.nothingLeftMessage)
            return
        }
        Self.report(census, album: source.displayName)

        if census.eligible > 0 {
            let next = source.forwardedArguments.joined(separator: " ")
            print("""

                Next: aplc convert \(next)
                """)
        }
    }

    struct Census {
        var total = 0
        var eligible = 0
        var skips: [SkipReason: Int] = [:]
    }

    /// Shared with `convert`, which needs the counts rather than the printout —
    /// the same split as `Verify.verify`, and for the same reason: one census,
    /// two callers, no second implementation to drift.
    ///
    /// nil means the month has nothing left to convert and no album to report on.
    /// - Parameter refreshingSelection: false when the caller has already run
    ///   `select` itself, which is what `convert` does once for the whole chain.
    static func census(
        source: SourceAlbumOptions,
        verbose: Bool = false,
        refreshingSelection: Bool = true
    ) async throws -> Census? {
        try await PhotoLibraryAccess.authorize()

        let collection: PHAssetCollection
        if refreshingSelection && source.shouldRefreshSelection {
            guard let refreshed = try await source.resolveRefreshingSelection() else { return nil }
            collection = refreshed
        } else {
            collection = try source.resolve()
        }
        let assets = PhotoLibraryAccess.imageAssets(in: collection)

        var census = Census(total: assets.count)
        for asset in assets {
            let traits = PhotoLibraryAccess.traits(for: asset)
            // Downloads are assumed allowed here so that iCloud-only originals
            // are counted as convertible rather than as a failure of the asset.
            let outcome = EligibilityGate.evaluatePreConditions(
                traits, policy: GatePolicy(allowDownloads: true)
            )
            switch outcome {
            case .eligible:
                census.eligible += 1
                if verbose { print("  eligible  \(traits.originalFilename)") }
            case .skip(let reason):
                census.skips[reason, default: 0] += 1
                if verbose { print("  skip      \(traits.originalFilename)  (\(reason.rawValue))") }
            }
        }
        return census
    }

    static func report(_ census: Census, album: String) {
        print("\nAlbum \(album)")
        print(Format.table([
            ("images in album", "\(census.total)"),
            ("convertible", "\(census.eligible)"),
            ("not convertible", "\(census.total - census.eligible)"),
        ]))

        if !census.skips.isEmpty {
            print("\nWhy the rest are excluded")
            let rows = census.skips
                .sorted { $0.value > $1.value }
                .map { ("\($0.key.rawValue)", "\($0.value)  — \($0.key.explanation)") }
            print(Format.table(rows))
        }
    }
}
