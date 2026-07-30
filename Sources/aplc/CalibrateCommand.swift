import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibrate",
        abstract: "Sweep HEIC quality over a sample to choose a setting from your own photos.",
        discussion: """
            Writes nothing to the library. For each quality step it reports the mean
            size saving and the mean SSIM against the original, and leaves the
            encoded files under <out>/calibrate/q<quality>/ so you can look at them.

            Numbers alone should not decide this. A very high saving usually means
            visible quality loss somewhere in the set — open the files and judge.
            """
    )

    @OptionGroup var staging: StagingOptions

    @Option(help: "Title of the album to sample from. Omit when using --files.")
    var album: String?

    @Option(parsing: .upToNextOption,
            help: "Image files to sample instead of an album. Needs no library access.")
    var files: [String] = []

    @Option(help: "How many assets to sample from the album.")
    var samples: Int = 30

    @Option(parsing: .upToNextOption, help: "Quality steps to try.")
    var steps: [Double] = [0.6, 0.7, 0.75, 0.8, 0.85, 0.9]

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads.")
    var maxDownloadGB: Double = 2.0

    func validate() throws {
        guard album != nil || !files.isEmpty else {
            throw ValidationError("provide either --album or --files")
        }
    }

    func run() async throws {
        let sources = try await gatherSources()
        guard !sources.isEmpty else {
            print("No convertible images found to calibrate on.")
            return
        }
        print("Calibrating on \(sources.count) image(s).\n")

        var results: [(quality: Double, saved: Double, ssim: Double, worstSSIM: Double, n: Int)] = []

        for quality in steps.sorted() {
            let directory = staging.stagingRoot
                .appendingPathComponent("calibrate")
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

            Encoded samples are under \(staging.stagingRoot.appendingPathComponent("calibrate").path)
            Compare a few against the originals, then pass your choice as --quality to `transcode`.
            """)
    }

    /// Either the given files, or originals exported from a sample of the album.
    private func gatherSources() async throws -> [URL] {
        if !files.isEmpty {
            return files.map { URL(fileURLWithPath: $0).standardizedFileURL }
        }

        guard let album else { return [] }
        try await PhotoLibraryAccess.authorize()
        let collection = try PhotoLibraryAccess.findAlbum(titled: album)

        let eligible = PhotoLibraryAccess.imageAssets(in: collection).filter {
            EligibilityGate.evaluatePreConditions(PhotoLibraryAccess.traits(for: $0)).isEligible
        }
        // A random sample rather than the first N: the head of an album is often
        // all from one shoot, which would calibrate against a single subject.
        let sample = eligible.shuffled().prefix(samples)

        let budget = maxDownloadGB > 0 ? Int(maxDownloadGB * 1_073_741_824) : nil
        let exporter = OriginalExporter(downloadBudgetBytes: budget)
        let directory = staging.stagingRoot.appendingPathComponent("calibrate/originals")

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
