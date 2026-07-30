import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Transcode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode",
        abstract: "Encode eligible JPEGs to HEIC in a staging folder. Never touches the library.",
        discussion: """
            For each eligible asset this exports the original, encodes it to HEIC,
            re-reads the HEIC and checks it against the original, then records the
            outcome in <out>/ledger.jsonl. The exported JPEG is deleted afterwards —
            the library still holds it, so keeping a second copy only wastes space.

            Interrupted runs resume: assets already recorded as transcoded, whose
            staged file is still present, are left alone.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var gate: GateOptions

    @Option(help: "Title of the album to convert.")
    var album: String

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads entirely.")
    var maxDownloadGB: Double = 5.0

    @Option(help: "Stop after this many assets.")
    var limit: Int?

    func run() async throws {
        guard Transcoder.canWriteHEIC else {
            throw ValidationError("this system's ImageIO cannot write HEIC")
        }
        try await PhotoLibraryAccess.authorize()
        let collection = try PhotoLibraryAccess.findAlbum(titled: album)
        let assets = PhotoLibraryAccess.imageAssets(in: collection)

        let ledger = try Ledger(url: staging.ledgerURL)
        let alreadyDone = try Self.completedIdentifiers(
            ledgerURL: staging.ledgerURL, heicDirectory: staging.heicDirectory
        )

        // One Apple Event for the whole album. PhotoKit cannot read keywords,
        // title or caption, so this is the only way to capture them — but the
        // conversion must not depend on it, hence the graceful degradation.
        var textMetadata: [String: AssetTextMetadata] = [:]
        var textMetadataAvailable = true
        do {
            // Announced because it is not instant: Photos answers roughly one
            // asset per 20 ms, so a few thousand assets means minutes of silence
            // before the first conversion line appears.
            print("Reading keywords/title/caption for \(assets.count) assets from Photos...")
            textMetadata = try await PhotosScripting.readTextMetadata(inAlbumTitled: album)
        } catch let error as PhotosScriptingError {
            textMetadataAvailable = false
            print("""
                Note: could not read keywords/title/caption from Photos — \(error)
                Continuing; the converted files will not carry them.
                """)
        }

        let allowDownloads = maxDownloadGB > 0
        let budget = allowDownloads ? Int(maxDownloadGB * 1_073_741_824) : nil
        let exporter = OriginalExporter(downloadBudgetBytes: budget)
        let policy = gate.policy(allowDownloads: allowDownloads)
        let transcoder = Transcoder(quality: gate.quality)

        var processed = 0
        var converted = 0
        var withText = 0
        var sourceBytes = 0
        var heicBytes = 0
        var skips: [SkipReason: Int] = [:]

        for asset in assets {
            if let limit, processed >= limit { break }
            if alreadyDone.contains(asset.localIdentifier) { continue }

            let traits = PhotoLibraryAccess.traits(for: asset)
            processed += 1

            if case .skip(let reason) = EligibilityGate.evaluatePreConditions(traits, policy: policy) {
                skips[reason, default: 0] += 1
                try ledger.append(LedgerEntry(
                    outcome: .skipped,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    skipReason: reason
                ))
                continue
            }

            guard let resource = PhotoLibraryAccess.originalPhotoResource(for: asset) else {
                skips[.notAJPEG, default: 0] += 1
                try ledger.append(LedgerEntry(
                    outcome: .skipped,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    skipReason: .notAJPEG
                ))
                continue
            }

            let stem = Format.safeFilename(for: asset.localIdentifier)
            let exportedURL = staging.originalsDirectory
                .appendingPathComponent(stem).appendingPathExtension("jpg")
            let heicURL = staging.heicDirectory
                .appendingPathComponent(stem).appendingPathExtension("heic")

            // The exported original is scratch space; the library keeps the real one.
            defer { try? FileManager.default.removeItem(at: exportedURL) }

            do {
                _ = try await exporter.export(resource: resource, to: exportedURL)
            } catch {
                let reason: SkipReason = allowDownloads ? .downloadBudgetExhausted : .notLocallyAvailable
                skips[reason, default: 0] += 1
                try ledger.append(LedgerEntry(
                    outcome: .skipped,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    skipReason: reason
                ))
                continue
            }

            do {
                // nil when Photos was unreachable: leave the file's own metadata
                // alone rather than guess. Otherwise the set from Photos wins,
                // even when empty, so stale embedded keywords get cleared.
                let assetText = textMetadata[asset.localIdentifier]
                let keywordsToEmbed = textMetadataAvailable ? (assetText?.keywords ?? []) : nil

                let result = try transcoder.transcode(
                    source: exportedURL, destination: heicURL, keywords: keywordsToEmbed
                )
                let score = try QualityMetrics.compare(exportedURL, heicURL)
                let outcome = EligibilityGate.evaluatePostConditions(
                    source: result.sourceFacts,
                    destination: result.destinationFacts,
                    quality: score,
                    policy: policy
                )

                if case .skip(let reason) = outcome {
                    skips[reason, default: 0] += 1
                    // A rejected encode must not linger where `apply` might find it.
                    try? FileManager.default.removeItem(at: heicURL)
                    try ledger.append(LedgerEntry(
                        outcome: .skipped,
                        sourceLocalIdentifier: traits.localIdentifier,
                        originalFilename: traits.originalFilename,
                        skipReason: reason,
                        sourceBytes: result.sourceBytes,
                        stagedBytes: result.destinationBytes,
                        quality: gate.quality,
                        ssim: score.ssim,
                        psnr: score.psnr.isFinite ? score.psnr : nil
                    ))
                    continue
                }

                converted += 1
                if assetText?.isEmpty == false { withText += 1 }
                sourceBytes += result.sourceBytes
                heicBytes += result.destinationBytes

                try ledger.append(LedgerEntry(
                    outcome: .transcoded,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    stagedPath: heicURL.path,
                    sourceSHA256: try? Digest.sha256(of: exportedURL),
                    stagedSHA256: try? Digest.sha256(of: heicURL),
                    sourceBytes: result.sourceBytes,
                    stagedBytes: result.destinationBytes,
                    quality: gate.quality,
                    ssim: score.ssim,
                    psnr: score.psnr.isFinite ? score.psnr : nil,
                    sourceFacts: result.sourceFacts,
                    stagedFacts: result.destinationFacts,
                    sourceTextMetadata: assetText
                ))

                print(String(format: "  %@  %@ -> %@  (%@ saved, SSIM %.4f)",
                             traits.originalFilename,
                             Format.bytes(result.sourceBytes),
                             Format.bytes(result.destinationBytes),
                             Format.percent(result.savedFraction),
                             score.ssim))
            } catch {
                try? FileManager.default.removeItem(at: heicURL)
                skips[.transcodeFailed, default: 0] += 1
                try ledger.append(LedgerEntry(
                    outcome: .failed,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    error: "\(error)"
                ))
            }
        }

        let downloaded = await exporter.downloadedBytes
        print("\nTranscode summary")
        print(Format.table([
            ("examined", "\(processed)"),
            ("staged for conversion", "\(converted)"),
            ("carrying keywords/title/caption", textMetadataAvailable
                ? "\(withText)"
                : "unknown — Photos was unreachable"),
            ("skipped", "\(skips.values.reduce(0, +))"),
            ("JPEG bytes", Format.bytes(sourceBytes)),
            ("HEIC bytes", Format.bytes(heicBytes)),
            ("would save", sourceBytes > 0
                ? "\(Format.bytes(sourceBytes - heicBytes))  (\(Format.percent(1 - Double(heicBytes) / Double(sourceBytes))))"
                : "n/a"),
            ("downloaded from iCloud", Format.bytes(downloaded)),
        ]))

        if !skips.isEmpty {
            print("\nSkipped")
            print(Format.table(skips.sorted { $0.value > $1.value }
                .map { ("\($0.key.rawValue)", "\($0.value)  — \($0.key.explanation)") }))
        }

        print("""

            Nothing has been written to your photo library.
            Next: aplc verify --out \(staging.out)
            """)
    }

    /// Assets already transcoded in an earlier run whose staged file survives.
    static func completedIdentifiers(ledgerURL: URL, heicDirectory: URL) throws -> Set<String> {
        let entries = try Ledger.readAll(at: ledgerURL)
        var done: Set<String> = []
        for entry in entries where entry.outcome == .transcoded || entry.outcome == .applied {
            guard let path = entry.stagedPath else { continue }
            if FileManager.default.fileExists(atPath: path) {
                done.insert(entry.sourceLocalIdentifier)
            }
        }
        return done
    }
}
