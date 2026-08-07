import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Sweep HEIC quality over a sample to choose a setting from your own photos.",
        discussion: """
            Creates no asset. For each quality step it reports the mean size saving
            and the mean SSIM against the original, and leaves the encoded files in
            a directory it names at the end, so you can look at them.

            With --year and --month it brings that month's "Selected Originals" up
            to date first, the same work `select` does. Given --year alone it does
            so for all twelve months and draws the --samples from the year as a
            whole, not that many from each month. --files needs no library access
            at all.

            Numbers alone should not decide this. A very high saving usually means
            visible quality loss somewhere in the set — open the files and judge.
            """
    )

    @OptionGroup var source: SourceAlbumOptions

    @Option(parsing: .upToNextOption,
            help: "Image files to sample instead of an album. Needs no library access.")
    var files: [String] = []

    @Option(help: "How many assets to sample from the album.")
    var samples: Int = 30

    // Every step is a distinct encoder bucket. The old default included both
    // 0.80 and 0.85, which produce byte-identical files — a wasted column.
    @Option(parsing: .upToNextOption, help: "Quality steps to try.")
    var steps: [Double] = [0.57, 0.65, 0.71, 0.76, 0.79, 0.86, 0.90]

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads.")
    var maxDownloadGB: Double = 2.0

    func validate() throws {
        guard files.isEmpty else { return }
        try source.requireSelection()
    }

    func run() async throws {
        // The one command whose staging outlives it, and on purpose: its whole
        // product is files to judge by eye, so cleaning up would throw away the
        // answer. A temporary directory still means no permanent residue —
        // macOS clears /var/folders itself — and the path is printed at the end.
        let area = try StagingArea()

        let sources = try await gatherSources(in: area)
        guard !sources.isEmpty else {
            print("No convertible images found to calibrate on.")
            return
        }
        print("Calibrating on \(sources.count) image(s).\n")

        var results: [(quality: Double, saved: Double, ssim: Double, worstSSIM: Double, n: Int)] = []

        for quality in steps.sorted() {
            let directory = area.root
                .appendingPathComponent("q\(Int(quality * 100))")
            let transcoder = Transcoder(quality: quality)

            var savedTotal = 0.0
            var ssimTotal = 0.0
            var worst = 1.0
            var counted = 0

            for source in sources {
                let destination = directory
                    .appendingPathComponent(source.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension("heic")
                do {
                    let result = try transcoder.transcode(source: source, destination: destination)
                    let score = try QualityMetrics.compare(source, destination)
                    savedTotal += result.savedFraction
                    ssimTotal += score.ssim
                    worst = min(worst, score.ssim)
                    counted += 1
                } catch {
                    FileHandle.standardError.write(
                        Data("  warning: \(source.lastPathComponent): \(error)\n".utf8)
                    )
                }
            }

            guard counted > 0 else { continue }
            let row = (quality, savedTotal / Double(counted), ssimTotal / Double(counted), worst, counted)
            results.append(row)
            print(String(format: "  q=%.2f   saved %5.1f%%   mean SSIM %.4f   worst SSIM %.4f   (%d files)",
                         row.0, row.1 * 100, row.2, row.3, row.4))
        }

        print("""

            Encoded samples are under \(area.root.path)
              open \(area.root.path)
            Compare a few against the originals, then pass your choice as --quality
            to `convert`. They are not deleted, but they are in a temporary place —
            copy anything you want to keep.
            """)
    }

    /// Either the given files, or originals exported from a sample of the album.
    private func gatherSources(in area: StagingArea) async throws -> [URL] {
        if !files.isEmpty {
            return files.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        guard !source.isEmpty else { return [] }
        try await PhotoLibraryAccess.authorize()

        // A whole year is pooled before sampling, not sampled month by month:
        // --samples means that many files to look at, and twelve times that
        // many is a different thing than the one that was asked for.
        var eligible: [PHAsset] = []
        for scope in source.scopes {
            let collection: PHAssetCollection
            if scope.shouldRefreshSelection {
                guard let refreshed = try await scope.resolveRefreshingSelection() else { continue }
                collection = refreshed
            } else {
                collection = try scope.resolve()
            }
            eligible += PhotoLibraryAccess.imageAssets(in: collection).filter {
                EligibilityGate.evaluatePreConditions(PhotoLibraryAccess.traits(for: $0)).isEligible
            }
        }
        guard !eligible.isEmpty else {
            print(source.nothingLeftMessage)
            return []
        }
        // A random sample rather than the first N: the head of an album is often
        // all from one shoot, which would calibrate against a single subject.
        let sample = eligible.shuffled().prefix(samples)

        let budget = maxDownloadGB > 0 ? Int(maxDownloadGB * 1_073_741_824) : nil
        let exporter = OriginalExporter(downloadBudgetBytes: budget)
        let directory = area.originalsDirectory

        var urls: [URL] = []
        for asset in sample {
            guard let resource = PhotoLibraryAccess.originalPhotoResource(for: asset) else { continue }
            let destination = directory
                .appendingPathComponent(Format.safeFilename(for: asset.localIdentifier))
                .appendingPathExtension("jpg")
            do {
                let export = try await exporter.export(resource: resource, to: destination)
                urls.append(export.url)
            } catch {
                FileHandle.standardError.write(
                    Data("  warning: could not export \(resource.originalFilename): \(error)\n".utf8)
                )
            }
        }
        return urls
    }
}
