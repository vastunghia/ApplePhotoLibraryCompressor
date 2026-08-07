import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Transcode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcode",
        abstract: "Encode eligible JPEGs to HEIC in a staging folder. Creates no asset.",
        discussion: """
            For each eligible asset this exports the original, encodes it to HEIC,
            re-reads the HEIC and checks it against the original, then records the
            outcome in the journal. The exported JPEG is deleted afterwards — the
            library still holds it, so keeping a second copy only wastes space.

            Staging is a temporary directory that goes away when the run ends, so
            on its own this command leaves you nothing to apply. `convert` is the
            way to carry a conversion through in one piece.

            With --year and --month it first brings that month's "Selected
            Originals" up to date, the same work `select` does. Given --year
            alone it does that for all twelve months and encodes them as one
            queue, so --limit counts across the year rather than per month.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var ledgerOptions: LedgerOptions
    @OptionGroup var gate: GateOptions

    @OptionGroup var source: SourceAlbumOptions

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads entirely.")
    var maxDownloadGB: Double = 5.0

    @Option(help: "Stop after this many assets.")
    var limit: Int?

    // Set by `convert`, which runs the next step itself. Hidden because it says
    // nothing about what the command does — only about who is calling it.
    @Flag(name: .customLong("chained"), help: .hidden)
    var chained: Bool = false

    func validate() throws { try source.requireSelection() }

    func run() async throws {
        guard Transcoder.canWriteHEIC else {
            throw ValidationError("this system's ImageIO cannot write HEIC")
        }
        try await PhotoLibraryAccess.authorize()

        // One scope unless a bare --year was given. The months are gathered into
        // a single queue rather than transcoded a month at a time: encoding is
        // per asset and knows nothing about months, so a year is one long list
        // and one honest summary at the end.
        var assets: [PHAsset] = []
        for scope in source.scopes {
            // Chained means `convert` has already selected for the whole run;
            // doing it again here would be a second pass over the month for
            // nothing.
            let collection: PHAssetCollection
            if !chained, scope.shouldRefreshSelection {
                guard let refreshed = try await scope.resolveRefreshingSelection() else {
                    print(scope.nothingLeftMessage)
                    continue
                }
                collection = refreshed
            } else {
                collection = try scope.resolve()
            }
            assets += PhotoLibraryAccess.imageAssets(in: collection)
        }
        guard !assets.isEmpty else {
            print(source.nothingLeftMessage)
            return
        }

        let area = try staging.makeArea()
        defer { area.cleanUp() }
        let ledgerURL = try ledgerOptions.url()

        let ledger = try Ledger(url: ledgerURL)
        let read = try Ledger.read(at: ledgerURL)
        ledgerOptions.warnIfDamaged(read)
        let alreadyDone = Self.completedIdentifiers(
            in: Ledger.entries(read.entries, stagedUnder: area.root)
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
            textMetadata = try await PhotosScripting.readTextMetadata(
                forIdentifiers: assets.map(\.localIdentifier)
            )
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
        let search = QualitySearch(targetSSIM: gate.minSSIM)
        if gate.quality == nil {
            print("Choosing quality per photo to reach SSIM \(gate.minSSIM).")
        }

        var processed = 0
        var converted = 0
        var withText = 0
        var sourceBytes = 0
        var heicBytes = 0
        var skips: [SkipReason: Int] = [:]
        // Rungs already chosen in this album, used to seed the next search.
        var chosenRungs: [Int] = []
        var probes = 0
        var searched = 0

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
            let exportedURL = area.originalsDirectory
                .appendingPathComponent(stem).appendingPathExtension("jpg")
            let heicURL = area.heicDirectory
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

                let result: TranscodeResult
                let score: QualityScore

                if let fixedQuality = gate.quality {
                    result = try Transcoder(quality: fixedQuality).transcode(
                        source: exportedURL, destination: heicURL, keywords: keywordsToEmbed
                    )
                    score = try QualityMetrics.compare(exportedURL, heicURL)
                } else {
                    let found = try search.search(
                        source: exportedURL,
                        destination: heicURL,
                        keywords: keywordsToEmbed,
                        seedIndex: Self.median(of: chosenRungs)
                    )
                    probes += found.probes
                    searched += 1

                    guard let accepted = found.accepted else {
                        // Not even the top rung reached the target. Skipping is
                        // the same answer as before; the search only means we
                        // now know no quality would have worked.
                        skips[.qualityBelowThreshold, default: 0] += 1
                        try ledger.append(LedgerEntry(
                            outcome: .skipped,
                            sourceLocalIdentifier: traits.localIdentifier,
                            originalFilename: traits.originalFilename,
                            skipReason: .qualityBelowThreshold,
                            quality: QualityLadder.rungs.last,
                            ssim: found.bestSSIM
                        ))
                        continue
                    }
                    chosenRungs.append(accepted.rungIndex)
                    result = accepted.result
                    score = accepted.score
                }

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
                        quality: result.quality,
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
                    quality: result.quality,
                    ssim: score.ssim,
                    psnr: score.psnr.isFinite ? score.psnr : nil,
                    sourceFacts: result.sourceFacts,
                    stagedFacts: result.destinationFacts,
                    sourceTextMetadata: assetText
                ))

                print(String(format: "  %@  %@ -> %@  (%@ saved, q=%.2f, SSIM %.4f)",
                             traits.originalFilename,
                             Format.bytes(result.sourceBytes),
                             Format.bytes(result.destinationBytes),
                             Format.percent(result.savedFraction),
                             result.quality,
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
            ("quality", Self.qualitySummary(gate.quality, chosenRungs: chosenRungs,
                                            probes: probes, searched: searched)),
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

        print("\nNothing has been written to your photo library.")
        if !chained {
            // Only worth suggesting when the staged files will still be there.
            // Without --staging-dir they go with the temporary directory, which
            // is why `convert` is the ordinary way to run this.
            if staging.stagingDir != nil {
                print("Next: aplc apply \(source.forwardedArguments.joined(separator: " ")) --confirm")
            } else {
                print("""
                    Staging was temporary and has been discarded. Run `aplc convert` \
                    to carry a conversion through to your library in one go.
                    """)
            }
        }
    }

    /// Where the next search should start: the middle of what this album has
    /// needed so far. `nil` for the first asset, which has nothing to learn from.
    static func median(of rungs: [Int]) -> Int? {
        guard !rungs.isEmpty else { return nil }
        return rungs.sorted()[rungs.count / 2]
    }

    static func qualitySummary(
        _ fixed: Double?, chosenRungs: [Int], probes: Int, searched: Int
    ) -> String {
        if let fixed {
            // Say what was encoded, not what was typed: the two differ whenever
            // the value falls between rungs.
            let actual = QualityLadder.rung(containing: fixed)
            return actual == fixed
                ? String(format: "%.2f (fixed)", fixed)
                : String(format: "%.2f (fixed; %.2f rounds down to it)", actual, fixed)
        }
        guard !chosenRungs.isEmpty else { return "chosen per photo — none converted" }
        let qualities = chosenRungs.map { QualityLadder.rungs[$0] }
        let mean = qualities.reduce(0, +) / Double(qualities.count)
        return String(format: "%.2f–%.2f, mean %.2f  (%.1f encodes per photo)",
                      qualities.min()!, qualities.max()!, mean,
                      Double(probes) / Double(max(searched, 1)))
    }

    /// Assets already transcoded in an earlier run whose staged file survives.
    ///
    /// Takes entries rather than a URL because the journal is global now: the
    /// caller scopes it to this staging root first, so a resume cannot be
    /// confused by a run that staged somewhere else.
    static func completedIdentifiers(in entries: [LedgerEntry]) -> Set<String> {
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
