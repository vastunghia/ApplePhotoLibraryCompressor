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

            Several photos are converted at once — see --jobs — because the encoder
            and the fidelity check use the machine very differently: one spreads
            itself over most of the cores, the other is one core for the whole of
            its run. Results are still reported and journalled in album order.

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

    @Option(help: "How many photos to convert at once. Defaults to half the CPU cores; more is barely faster.")
    var jobs: Int = Self.defaultJobs

    // Set by `convert`, which runs the next step itself. Hidden because it says
    // nothing about what the command does — only about who is calling it.
    @Flag(name: .customLong("chained"), help: .hidden)
    var chained: Bool = false

    /// Half the cores, on a curve that is flat above it. Measured on twelve real
    /// photographs on six cores, alternating settings: 56.2 / 55.9 / 55.3 s at
    /// three, four and six workers — a spread of about 3%, which is noise on a
    /// machine doing anything else at all.
    ///
    /// It is flat because ImageIO's encode is a process-wide serial resource, so
    /// past the point where there is always one photo encoding, extra workers
    /// have nothing left to overlap. Half the cores reaches that point and leaves
    /// the machine usable, which is the whole reason to prefer it.
    ///
    /// It has not always been flat: before the search interpolated, more workers
    /// meant more of them starting with a cold seed — 4.4 encodes per photo at
    /// six against 3.2 at one — which made `--jobs 6` genuinely *slower*. That
    /// penalty is gone (2.9 against 2.8), so do not reintroduce the old advice.
    static var defaultJobs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    func validate() throws {
        try source.requireSelection()
        guard jobs >= 1 else {
            throw ValidationError("--jobs must be at least 1, not \(jobs).")
        }
    }

    /// One photo's worth of work, with every library read already done.
    ///
    /// That is the point of the type: `PHAsset` and `PHAssetResource` are read on
    /// the way in, in album order, so nothing running in parallel afterwards has
    /// to touch PhotoKit. `@unchecked Sendable` says exactly that — the resource
    /// is a value read out of the library and never written to.
    private struct Job: @unchecked Sendable {
        let traits: AssetTraits
        let resource: PHAssetResource
        let exportedURL: URL
        let heicURL: URL
        let text: AssetTextMetadata?
    }

    func run() async throws {
        guard Transcoder.canWriteHEIC else {
            throw ValidationError("this system's ImageIO cannot write HEIC")
        }
        try await PhotoLibraryAccess.authorize()

        // One scope unless a bare --year was given. The months are gathered into
        // a single queue rather than transcoded a month at a time: encoding is
        // per asset and knows nothing about months, so a year is one long list
        // and one honest summary at the end.
        //
        // Each asset is kept with the month it came from, because that is the
        // one case where the month varies line by line: `convert --year` runs a
        // separate `transcode` per month, but a bare `transcode --year` is one
        // queue spanning twelve. A label taken from the command's own scope
        // would be right everywhere except there.
        var assets: [(asset: PHAsset, label: String)] = []
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
            // Empty in --album mode: there is one album, the user named it
            // himself, and repeating it on every line would say nothing.
            let label = scope.monthKey.map { MonthBounds.label(year: $0.year, month: $0.month) } ?? ""
            assets += PhotoLibraryAccess.imageAssets(in: collection).map { ($0, label) }
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
                forIdentifiers: assets.map(\.asset.localIdentifier)
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
        let fixedQuality = gate.quality
        if fixedQuality == nil {
            print("Choosing quality per photo to reach SSIM \(gate.minSSIM).")
        }

        // ---------------------------------------------------------------
        // 1. Plan. Every PhotoKit read happens here, in album order, before
        //    anything runs alongside anything else. Each photo comes out of this
        //    as one of two things: a journal line already decided, or a job.
        // ---------------------------------------------------------------
        // The two halves of the plan, both carrying the index that puts a photo
        // back in album order. Kept apart rather than as an array of optionals so
        // that dispatching cannot reach for a job that is not there — a slot
        // missed there would leave the recorder waiting for it forever.
        var queued: [(index: Int, job: Job)] = []
        var decided: [(index: Int, outcome: AssetConversion.Outcome)] = []
        /// The month each slot's photo came from, for the progress prefix.
        var labels: [String] = []
        var slots = 0
        var examined = 0

        for (asset, label) in assets {
            if let limit, examined >= limit { break }
            // Checked before counting, exactly as when this was one loop: --limit
            // means "examine this many", and a photo an earlier run already
            // staged was never examined.
            if alreadyDone.contains(asset.localIdentifier) { continue }
            examined += 1

            let traits = PhotoLibraryAccess.traits(for: asset)
            let index = slots
            slots += 1
            // Parallel to the slots, so a released result can be labelled with
            // the month its photo came from.
            labels.append(label)

            if case .skip(let reason) = EligibilityGate.evaluatePreConditions(traits, policy: policy) {
                decided.append((index, Self.skipOutcome(traits, reason)))
                continue
            }
            guard let resource = PhotoLibraryAccess.originalPhotoResource(for: asset) else {
                decided.append((index, Self.skipOutcome(traits, .notAJPEG)))
                continue
            }

            let stem = Format.safeFilename(for: asset.localIdentifier)
            queued.append((index, Job(
                traits: traits,
                resource: resource,
                exportedURL: area.originalsDirectory
                    .appendingPathComponent(stem).appendingPathExtension("jpg"),
                heicURL: area.heicDirectory
                    .appendingPathComponent(stem).appendingPathExtension("heic"),
                text: textMetadata[asset.localIdentifier]
            )))
        }

        let workers = min(jobs, max(1, queued.count))
        if workers > 1 {
            // Said out loud because it changes how the output behaves: lines
            // appear in bursts rather than one at a steady pace, and the machine
            // is busy for the whole run.
            print("Converting \(workers) photos at once.")
        }

        // ---------------------------------------------------------------
        // 2 & 3. Convert in parallel, record in album order.
        //
        // The workers only compute; every journal write, every printed line and
        // every counter belongs to this task alone. That is what makes the totals
        // safe without a single lock, and what keeps the journal in the order the
        // photos are in — so two runs of the same month stay comparable line by
        // line, and `apply --limit` still picks the same photos.
        // ---------------------------------------------------------------
        var sink = OrderedSink<AssetConversion.Outcome>()
        // Which slots the gate already refused, so the estimate can tell the
        // photos that cost an encode from the ones that cost nothing.
        let decidedIndexes = Set(decided.map(\.0))
        var progress = TranscodeProgress(total: decided.count + queued.count,
                                         encodable: queued.count)
        // Padded to the widest month in this run, so the prefixes line up when a
        // bare `transcode --year` walks from May into September. One month wide
        // is no padding at all, which is the usual case.
        let labelWidth = Set(labels).filter { !$0.isEmpty }.map(\.count).max() ?? 0
        let startedAt = Date()
        var converted = 0
        var withText = 0
        var sourceBytes = 0
        var heicBytes = 0
        var skips: [SkipReason: Int] = [:]
        // Rungs already chosen in this album, used to seed the next search.
        var chosenRungs: [Int] = []
        var probes = 0
        var searched = 0

        func record(_ outcome: AssetConversion.Outcome, at index: Int) throws {
            try ledger.append(outcome.entry)
            probes += outcome.probes
            if outcome.searched { searched += 1 }
            progress.advance(costAnEncode: !decidedIndexes.contains(index), at: Date())

            switch outcome.kind {
            case .converted(let result):
                converted += 1
                if outcome.entry.sourceTextMetadata?.isEmpty == false { withText += 1 }
                sourceBytes += result.result.sourceBytes
                heicBytes += result.result.destinationBytes
                let label = labels[index].padding(toLength: labelWidth,
                                                  withPad: " ", startingAt: 0)
                print(String(format: "  %@  %@  %@ -> %@  (%@ saved, q=%.2f, SSIM %.4f)",
                             progress.prefix(label: label),
                             outcome.entry.originalFilename,
                             Format.bytes(result.result.sourceBytes),
                             Format.bytes(result.result.destinationBytes),
                             Format.percent(result.result.savedFraction),
                             result.result.quality,
                             result.score.ssim))
            case .notConverted(let reason):
                skips[reason, default: 0] += 1
            }
        }

        /// Records everything the sink just released, which arrives without its
        /// indexes — but `nextIndex` has advanced past exactly those slots, so
        /// they are the ones ending there.
        func recordReleased(_ released: [AssetConversion.Outcome]) throws {
            let firstIndex = sink.nextIndex - released.count
            for (offset, ready) in released.enumerated() {
                try record(ready, at: firstIndex + offset)
            }
        }

        // Photos the gate refused without reading a byte. Parked at their own
        // index so they still print between the conversions they sit between.
        for (index, outcome) in decided {
            try recordReleased(sink.insert(outcome, at: index))
        }

        var cursor = 0

        func dispatch(_ group: inout ThrowingTaskGroup<(Int, AssetConversion.Outcome), any Error>) {
            guard cursor < queued.count else { return }
            let (index, job) = queued[cursor]
            cursor += 1
            // Read at dispatch, not inside the worker: the seed is this task's
            // to decide, so the workers share no state at all.
            let seed = Self.median(of: chosenRungs)
            group.addTask {
                (index, await Self.convert(
                    job,
                    seedIndex: seed,
                    exporter: exporter,
                    policy: policy,
                    search: search,
                    fixedQuality: fixedQuality,
                    textIsAuthoritative: textMetadataAvailable,
                    allowDownloads: allowDownloads
                ))
            }
        }

        try await withThrowingTaskGroup(of: (Int, AssetConversion.Outcome).self) { group in
            for _ in 0..<workers { dispatch(&group) }

            while let (index, outcome) = try await group.next() {
                // Fed as soon as a photo finishes rather than when it is recorded:
                // a slow photo must not freeze what every later search starts
                // from. The cost is that the seed depends on timing, so the probe
                // count varies between runs — never the guarantee, since the rung
                // finally returned has always been measured against the target.
                if case .converted(let result) = outcome.kind, let rung = result.rungIndex {
                    chosenRungs.append(rung)
                }
                dispatch(&group)
                try recordReleased(sink.insert(outcome, at: index))
            }
        }

        let downloaded = await exporter.downloadedBytes
        print("\nTranscode summary")
        print(Format.table([
            ("examined", "\(examined)"),
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
            // Wall time was only ever recoverable by reading timestamps back out
            // of the journal, which is a strange thing to make someone do for the
            // number they most want after a long run.
            ("elapsed", Self.elapsedSummary(since: startedAt, converted: converted)),
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

    /// Exports one original and converts it. The only part of a run that several
    /// photos are in at once, and it shares nothing: every argument is a value,
    /// and the exporter is an actor that meters the iCloud budget for all of them.
    private static func convert(
        _ job: Job,
        seedIndex: Int?,
        exporter: OriginalExporter,
        policy: GatePolicy,
        search: QualitySearch,
        fixedQuality: Double?,
        textIsAuthoritative: Bool,
        allowDownloads: Bool
    ) async -> AssetConversion.Outcome {
        // The exported original is scratch space; the library keeps the real one.
        defer { try? FileManager.default.removeItem(at: job.exportedURL) }

        do {
            _ = try await exporter.export(resource: job.resource, to: job.exportedURL)
        } catch {
            let reason: SkipReason = allowDownloads ? .downloadBudgetExhausted : .notLocallyAvailable
            return skipOutcome(job.traits, reason)
        }

        // The encoding and the fidelity check are the blocking part, so they go
        // to an ordinary thread; this task suspends until they are done. Putting
        // them on a cooperative thread instead deadlocks the run — see
        // `BlockingWork`, where the measurement is.
        return await BlockingWork.run {
            AssetConversion.run(
                source: job.exportedURL,
                destination: job.heicURL,
                traits: job.traits,
                text: job.text,
                textIsAuthoritative: textIsAuthoritative,
                policy: policy,
                fixedQuality: fixedQuality,
                search: search,
                seedIndex: seedIndex
            )
        }
    }

    /// A skip decided before any encoding — by the gate, by there being no JPEG
    /// original, or by the original not being on disk.
    private static func skipOutcome(_ traits: AssetTraits, _ reason: SkipReason) -> AssetConversion.Outcome {
        AssetConversion.Outcome(
            entry: LedgerEntry(
                outcome: .skipped,
                sourceLocalIdentifier: traits.localIdentifier,
                originalFilename: traits.originalFilename,
                skipReason: reason
            ),
            kind: .notConverted(reason),
            probes: 0,
            searched: false
        )
    }

    /// Where the next search should start: the middle of what this album has
    /// needed so far. `nil` for the first asset, which has nothing to learn from.
    static func median(of rungs: [Int]) -> Int? {
        guard !rungs.isEmpty else { return nil }
        return rungs.sorted()[rungs.count / 2]
    }

    /// "1h 12m  (4.9 s/photo)", or just the time when nothing was converted.
    ///
    /// Per *converted* photo rather than per examined one, so the figure means
    /// the same thing in a month full of skips as in one without — and so it is
    /// comparable with the seconds-per-photo quoted in the docs.
    static func elapsedSummary(since start: Date, converted: Int) -> String {
        let seconds = Date().timeIntervalSince(start)
        let time = TranscodeProgress.duration(seconds)
        guard converted > 0 else { return time }
        return String(format: "%@  (%.1f s/photo)", time, seconds / Double(converted))
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
