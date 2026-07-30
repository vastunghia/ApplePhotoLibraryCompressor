import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Census an album: how many photos are convertible, and why the rest are not.",
        discussion: """
            Strictly read-only. Nothing is written to the library or to disk.

            Byte totals are deliberately absent: PhotoKit exposes no public API for
            a resource's file size, so the only honest way to measure the saving is
            to run `transcode`, which reports it from files it actually wrote.
            """
    )

    @Option(help: "Title of the album to examine.")
    var album: String

    @Flag(help: "Print one line per asset instead of only the summary.")
    var verbose: Bool = false

    func run() async throws {
        try await PhotoLibraryAccess.authorize()
        let collection = try PhotoLibraryAccess.findAlbum(titled: album)
        let assets = PhotoLibraryAccess.imageAssets(in: collection)

        var eligible = 0
        var skips: [SkipReason: Int] = [:]

        for asset in assets {
            let traits = PhotoLibraryAccess.traits(for: asset)
            // Downloads are assumed allowed here so that iCloud-only originals
            // are counted as convertible rather than as a failure of the asset.
            let outcome = EligibilityGate.evaluatePreConditions(
                traits, policy: GatePolicy(allowDownloads: true)
            )
            switch outcome {
            case .eligible:
                eligible += 1
                if verbose { print("  eligible  \(traits.originalFilename)") }
            case .skip(let reason):
                skips[reason, default: 0] += 1
                if verbose { print("  skip      \(traits.originalFilename)  (\(reason.rawValue))") }
            }
        }

        print("\nAlbum \"\(album)\"")
        print(Format.table([
            ("images in album", "\(assets.count)"),
            ("convertible", "\(eligible)"),
            ("not convertible", "\(assets.count - eligible)"),
        ]))

        if !skips.isEmpty {
            print("\nWhy the rest are excluded")
            let rows = skips
                .sorted { $0.value > $1.value }
                .map { ("\($0.key.rawValue)", "\($0.value)  — \($0.key.explanation)") }
            print(Format.table(rows))
        }

        if eligible > 0 {
            print("""

                Next: aplc calibrate --album "\(album)" --out ./staging
                """)
        }
    }
}
