import APLCCore
import ArgumentParser
import Darwin
import Foundation
import Photos

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Add staged HEIC files to the library as new assets. Deletes nothing.",
        discussion: """
            The JPEG originals stay exactly where they are; your library will
            temporarily grow. Removing the originals is a manual step in
            Photos.app, once you are satisfied with the copies.

            Each copy is filed by the capture date of its original, in
            "aplc workspace" > "YYYY-MM" > "Compressed Copies", so an album that
            spans two months produces two destinations. The JPEGs it replaced go
            beside them in "Compressed Originals" — the album to delete from once
            you are satisfied. --dest-album overrides all of that with a single
            flat album.

            Runs as a dry run unless you pass --confirm. It refuses to start if
            `verify` reports any problem, and it skips assets already applied, so
            running it twice cannot create duplicates.

            It also asks the library, not just the ledger: a staged file whose
            copy is already there — same filename, same capture second — is
            skipped when the two are identical, and put to you when they differ.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var ledgerOptions: LedgerOptions
    @OptionGroup var gate: GateOptions
    @OptionGroup var source: SourceAlbumOptions

    @Option(name: .customLong("dest-album"),
            help: "Put every copy in this one album instead of the workspace's month folders.")
    var destAlbum: String?

    @Flag(help: "Actually write to the library. Without this, nothing is created.")
    var confirm: Bool = false

    @Option(help: "Apply at most this many assets.")
    var limit: Int?

    // An asset created through PhotoKit belongs to no import session, so it
    // never shows under Collections > Other > Imports and carries no "added by"
    // line. Asking Photos to import the file instead sets both. Off by default
    // because it makes Automation consent mandatory rather than optional, and
    // because it hands Photos the reading of the filename — see
    // `Importer.createAssetViaPhotosApp`.
    @Flag(name: .customLong("import-via-applescript"),
          help: "Let Photos.app import the file, so it gets an import session.")
    var importViaAppleScript: Bool = false

    // Set by `convert`. Only affects wording: inside the chain the command to
    // re-run is `convert`, not `apply`.
    @Flag(name: .customLong("chained"), help: .hidden)
    var chained: Bool = false

    func validate() throws { try source.requireSelection() }

    /// Where the copies will go, spelled as the user would find it in Photos.
    private var destinationDescription: String {
        if let destAlbum { return "\"\(destAlbum)\"" }
        return "\(WorkspaceLayout.rootFolder) > (capture month) > \(WorkspaceLayout.copiesAlbum)"
    }

    func run() async throws {
        let area = try staging.makeArea()
        defer { area.cleanUp() }
        let ledgerURL = try ledgerOptions.url()

        // Read once. The journal is permanent and grows with every photo ever
        // converted, so the three separate reads this used to do would mean
        // decoding the whole history three times per run.
        let read = try Ledger.read(at: ledgerURL)
        ledgerOptions.warnIfDamaged(read)

        // Gate one: staged files must pass an independent re-check.
        let report = Verify.verify(entries: read.entries, stagedUnder: area.root, gate: gate)
        guard report.problems.isEmpty else {
            print("Refusing to apply: `verify` found \(report.problems.count) problem(s).")
            for problem in report.problems.prefix(10) {
                print("  \(problem.file): \(problem.detail)")
            }
            throw ExitCode.failure
        }

        // `alreadyApplied` is asked of the *whole* journal, not just this run's
        // staging: that is the point of it outliving the staging directory. The
        // pending queue is scoped, because only files still on disk can be
        // imported.
        let alreadyApplied = Ledger.appliedIdentifiers(in: read.entries)
        let pending = Ledger.entries(read.entries, stagedUnder: area.root)
            .filter { $0.outcome == .transcoded }
            .filter { !alreadyApplied.contains($0.sourceLocalIdentifier) }

        guard !pending.isEmpty else {
            print("""
                Nothing staged to apply. \(alreadyApplied.count) asset(s) have been \
                applied in runs before this one.

                Staging is temporary, so `transcode` in one command and `apply` in \
                the next have nothing to hand between them: `aplc convert` does the \
                whole pipeline in one process, which is the way to reach this step.
                """)
            return
        }

        let planned = limit.map { Array(pending.prefix($0)) } ?? pending
        let savedBytes = planned.reduce(0) { $0 + (($1.sourceBytes ?? 0) - ($1.stagedBytes ?? 0)) }
        let addedBytes = planned.reduce(0) { $0 + ($1.stagedBytes ?? 0) }

        print("\nPlan")
        print(Format.table([
            ("new HEIC assets to create", "\(planned.count)"),
            ("added to the library now", Format.bytes(addedBytes)),
            ("recoverable once you delete the JPEGs", Format.bytes(savedBytes)),
            ("destination", destinationDescription),
            ("import route", importViaAppleScript ? "Photos.app (AppleScript)" : "PhotoKit"),
        ]))

        guard confirm else {
            let rerun = chained
                ? "Re-run without --dry-run to create these assets."
                : "Re-run with --confirm to create these assets."
            print("\nDry run — nothing was written. \(rerun)")
            return
        }

        try await PhotoLibraryAccess.authorize()

        // Match staged entries back to live assets by local identifier. Chained
        // means `convert` has already selected for the whole run.
        let sourceCollection: PHAssetCollection
        if !chained, source.shouldRefreshSelection {
            guard let refreshed = try await source.resolveRefreshingSelection() else {
                print(source.nothingLeftMessage)
                return
            }
            sourceCollection = refreshed
        } else {
            sourceCollection = try source.resolve()
        }
        var assetsByIdentifier: [String: PHAsset] = [:]
        for asset in PhotoLibraryAccess.imageAssets(in: sourceCollection) {
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        let ledger = try Ledger(url: ledgerURL)

        // One flat album, or one album per capture month created on demand. Both
        // are resolved lazily so a run that imports nothing creates nothing.
        var flatDestination: PHAssetCollection?
        var albumsByFolder: [String: PHAssetCollection] = [:]
        func destination(forFolderNamed folder: String) async throws -> PHAssetCollection {
            if let destAlbum {
                if let flatDestination { return flatDestination }
                let album = try await Importer.ensureAlbum(titled: destAlbum)
                flatDestination = album
                return album
            }
            if let existing = albumsByFolder[folder] { return existing }
            let album = try await Importer.ensureWorkspaceAlbum(
                WorkspaceLayout.copiesAlbum, inFolderNamed: folder
            )
            albumsByFolder[folder] = album
            return album
        }

        // The library's own answer to "is this already here", built one month at
        // a time and only for the months this run actually touches.
        var duplicateIndexes: [MonthKey: [TwinKey: [LibraryCopy]]] = [:]
        func duplicateIndex(for month: MonthKey) throws -> [TwinKey: [LibraryCopy]] {
            if let cached = duplicateIndexes[month] { return cached }
            let range = try MonthBounds.range(year: month.year, month: month.month)
            let copies: [(key: TwinKey, copy: LibraryCopy)] = PhotoLibraryAccess
                .imageAssets(createdIn: range)
                .compactMap { asset in
                    let traits = PhotoLibraryAccess.traits(for: asset)
                    guard traits.uniformTypeIdentifier == "public.heic",
                          let key = TwinKey(filename: traits.originalFilename,
                                            creationDate: asset.creationDate)
                    else { return nil }
                    return (key, LibraryCopy(localIdentifier: asset.localIdentifier,
                                             pixelWidth: asset.pixelWidth,
                                             pixelHeight: asset.pixelHeight))
                }
            let index = DuplicateCheck.index(copies)
            duplicateIndexes[month] = index
            return index
        }

        // Strictly offline: comparing is not a reason to pull a photo down from
        // iCloud. An unreadable copy becomes a question, never a silent decision.
        let comparer = OriginalExporter(downloadBudgetBytes: nil)
        let compareDirectory = area.compareDirectory

        var created = 0
        var failed = 0
        var skipped = 0
        var importRest = false
        var stopped = false
        var perDestination: [String: Int] = [:]
        /// Month folder -> the JPEGs whose copy this run created.
        var convertedOriginals: [String: [PHAsset]] = [:]
        // Without a terminal there is nobody to answer, so a question would be a
        // hang. `convert` inherits this: run it from a script and a differing
        // copy is skipped and reported, not waited on.
        let interactive = isatty(FileHandle.standardInput.fileDescriptor) == 1
        /// New asset identifier -> the metadata it should end up carrying.
        var pendingText: [String: AssetTextMetadata] = [:]
        var createdFilenames: [String: String] = [:]
        /// Cleared the duplicate check and is to be imported. Gathered rather
        /// than imported on the spot so the Photos.app route can batch; a `q`
        /// part-way through still imports everything answered for before it,
        /// which is what stopping ought to mean.
        var accepted: [Accepted] = []

        for entry in planned {
            if stopped { break }
            guard let stagedPath = entry.stagedPath else { continue }
            guard let sourceAsset = assetsByIdentifier[entry.sourceLocalIdentifier] else {
                failed += 1
                try ledger.append(LedgerEntry(
                    outcome: .failed,
                    sourceLocalIdentifier: entry.sourceLocalIdentifier,
                    originalFilename: entry.originalFilename,
                    error: "source asset is no longer in \(source.displayName)"
                ))
                continue
            }

            let captureDate = sourceAsset.creationDate
            let folder = WorkspaceLayout.folder(for: captureDate)

            // A photo with no capture date has no pair identity, so it cannot be
            // checked and is offered rather than assumed — the same asymmetry
            // `select` makes, and for the same reason.
            if let captureDate,
               let key = TwinKey(filename: entry.originalFilename, creationDate: captureDate),
               let candidate = try duplicateIndex(for: WorkspaceLayout.month(of: captureDate))[key]?.first {

                // Left nil unless the existing copy is genuinely read: an
                // unreadable one must reach the user as a question, and falling
                // back to any other asset here would answer it with the wrong
                // file's bytes.
                var bytesEqual: Bool?
                var existingBytes: Int?
                if let existingAsset = PHAsset.fetchAssets(
                       withLocalIdentifiers: [candidate.localIdentifier], options: nil
                   ).firstObject,
                   let resource = PhotoLibraryAccess.originalPhotoResource(for: existingAsset) {
                    let scratch = compareDirectory.appendingPathComponent(
                        Format.safeFilename(for: candidate.localIdentifier)
                    ).appendingPathExtension("heic")
                    if let export = try? await comparer.export(resource: resource, to: scratch) {
                        existingBytes = export.byteCount
                        bytesEqual = (try? Digest.sha256(of: export.url)) == entry.stagedSHA256
                    }
                }

                let verdict = DuplicateCheck.verdict(
                    stagedWidth: entry.stagedFacts?.width ?? 0,
                    stagedHeight: entry.stagedFacts?.height ?? 0,
                    stagedSHA256: entry.stagedSHA256,
                    existing: candidate,
                    bytesEqual: bytesEqual
                )

                var decision = DuplicateCheck.resolution(for: verdict)
                if case .ask(let copy, let question) = decision {
                    if importRest {
                        decision = .importIt
                    } else if !interactive {
                        decision = .skip(
                            .duplicateInLibrary,
                            detail: "\(question); no terminal to ask on, so it was not imported",
                            collidedWith: copy.localIdentifier
                        )
                    } else {
                        switch askAboutDuplicate(
                            filename: entry.originalFilename,
                            question: question,
                            existingBytes: existingBytes,
                            stagedBytes: entry.stagedBytes,
                            existing: copy
                        ) {
                        case .importIt:
                            decision = .importIt
                        case .importRest:
                            importRest = true
                            decision = .importIt
                        case .skip:
                            decision = .skip(.duplicateInLibrary,
                                             detail: question,
                                             collidedWith: copy.localIdentifier)
                        case .quit:
                            stopped = true
                            decision = .skip(.duplicateInLibrary,
                                             detail: "stopped by the user",
                                             collidedWith: copy.localIdentifier)
                        }
                    }
                }

                if case .skip(let reason, let detail, let collided) = decision {
                    skipped += 1
                    // Always said out loud. A silent skip leaves the user with a
                    // count in the summary and no way to know which photo it was
                    // about, which is the one thing a report must not do.
                    print("  skipped  \(entry.originalFilename)  — \(detail)")
                    try ledger.append(LedgerEntry(
                        outcome: .skipped,
                        sourceLocalIdentifier: entry.sourceLocalIdentifier,
                        originalFilename: entry.originalFilename,
                        skipReason: reason,
                        stagedPath: stagedPath,
                        collidedWithLocalIdentifier: collided
                    ))
                    continue
                }
            }

            // Accepted. The import itself happens after this loop, because the
            // Photos.app route must hand over every file in one call: one
            // `import` is one import session, and a call per photo would fill
            // Collections > Other > Imports with one single-photo event each.
            let heicName = heicFilename(from: entry.originalFilename)
            var prepared: URL?
            if importViaAppleScript {
                do {
                    prepared = try Importer.prepareForPhotosImport(
                        stagedHEIC: URL(fileURLWithPath: stagedPath),
                        originalFilename: heicName
                    )
                } catch {
                    failed += 1
                    try ledger.append(LedgerEntry(
                        outcome: .failed,
                        sourceLocalIdentifier: entry.sourceLocalIdentifier,
                        originalFilename: entry.originalFilename,
                        error: "\(error)"
                    ))
                    print("  FAILED   \(entry.originalFilename): \(error)")
                    continue
                }
            }
            accepted.append(Accepted(entry: entry, sourceAsset: sourceAsset, folder: folder,
                                     heicName: heicName, preparedFile: prepared,
                                     stagedPath: stagedPath))
        }

        // One import for the whole run, so the copies read as a single import
        // event rather than as one per photo.
        var identifiersByFilename: [String: String] = [:]
        if importViaAppleScript, !accepted.isEmpty {
            let files = accepted.compactMap(\.preparedFile)
            print("  handing \(files.count) file(s) to Photos as one import...")
            identifiersByFilename = try await Importer.importViaPhotosApp(files)
        }

        for item in accepted {
            let entry = item.entry
            let sourceAsset = item.sourceAsset
            let folder = item.folder
            let stagedPath = item.stagedPath

            do {
                let album = try await destination(forFolderNamed: folder)
                let identifier: String
                if importViaAppleScript {
                    guard let imported = identifiersByFilename[item.heicName] else {
                        throw Importer.ImportError.photosImportedNothing(item.heicName)
                    }
                    try await Importer.adoptImportedAsset(
                        imported,
                        metadata: Importer.CarriedMetadata(from: sourceAsset),
                        into: album
                    )
                    identifier = imported
                } else {
                    identifier = try await Importer.createAsset(
                        fromStagedHEIC: URL(fileURLWithPath: stagedPath),
                        originalFilename: item.heicName,
                        metadata: Importer.CarriedMetadata(from: sourceAsset),
                        into: album
                    )
                }
                created += 1
                perDestination[destAlbum ?? folder, default: 0] += 1
                // Gathered, not filed yet: one `add` per month at the end beats
                // one per photo, and only a copy that actually got created earns
                // its original a place in the deletable album.
                convertedOriginals[folder, default: []].append(sourceAsset)
                if let text = entry.sourceTextMetadata, !text.isEmpty {
                    pendingText[identifier] = text
                    createdFilenames[identifier] = entry.originalFilename
                }
                try ledger.append(LedgerEntry(
                    outcome: .applied,
                    sourceLocalIdentifier: entry.sourceLocalIdentifier,
                    originalFilename: entry.originalFilename,
                    stagedPath: stagedPath,
                    stagedSHA256: entry.stagedSHA256,
                    sourceBytes: entry.sourceBytes,
                    stagedBytes: entry.stagedBytes,
                    quality: entry.quality,
                    ssim: entry.ssim,
                    psnr: entry.psnr,
                    sourceTextMetadata: entry.sourceTextMetadata,
                    createdAssetLocalIdentifier: identifier
                ))
                print("  created  \(entry.originalFilename)")
            } catch {
                failed += 1
                try ledger.append(LedgerEntry(
                    outcome: .failed,
                    sourceLocalIdentifier: entry.sourceLocalIdentifier,
                    originalFilename: entry.originalFilename,
                    error: "\(error)"
                ))
                print("  FAILED   \(entry.originalFilename): \(error)")
            }
        }

        // The JPEGs that now have a replacement, gathered where the user can
        // select them all and delete them in one gesture. Skipped in --dest-album
        // mode: that flag says "keep out of the workspace", and this album has
        // nowhere else to live.
        var markedForDeletion = 0
        if destAlbum == nil {
            for (folder, originals) in convertedOriginals.sorted(by: { $0.key < $1.key }) {
                let album = try await Importer.ensureWorkspaceAlbum(
                    WorkspaceLayout.convertedOriginalsAlbum, inFolderNamed: folder
                )
                let existing = PhotoLibraryAccess.identifiers(in: album)
                let toAdd = originals.filter { !existing.contains($0.localIdentifier) }
                try await Importer.add(toAdd, to: album)
                markedForDeletion += toAdd.count
            }
        }

        let textReport = await transferTextMetadata(pendingText, ledger: ledger,
                                                    filenames: createdFilenames)

        print("\nApply summary")
        var rows: [(String, String)] = [
            ("assets created", "\(created)"),
            ("skipped as duplicates", "\(skipped)"),
            ("failures", "\(failed)"),
        ]
        for (name, count) in perDestination.sorted(by: { $0.key < $1.key }) {
            rows.append((destAlbum == nil ? "into \(name)" : "into \"\(name)\"", "\(count)"))
        }
        if destAlbum == nil {
            rows.append(("originals now replaceable", "\(markedForDeletion)"))
        }
        rows.append(("keywords/title/caption transferred", textReport.summary))
        print(Format.table(rows))

        if stopped {
            print("\nStopped at your request. Nothing after that point was touched.")
        }

        // Name the albums that actually received something, rather than the
        // pattern: after the run there is no reason to make the user work out
        // which months "(capture month)" turned into.
        let reviewTarget: String
        if let destAlbum {
            reviewTarget = "\"\(destAlbum)\""
        } else if perDestination.isEmpty {
            reviewTarget = destinationDescription
        } else {
            reviewTarget = perDestination.keys.sorted()
                .map { "\(WorkspaceLayout.rootFolder) > \($0) > \(WorkspaceLayout.copiesAlbum)" }
                .joined(separator: ", ")
        }

        print("""

            Your originals are untouched. Nothing was deleted.

            Keywords, title and caption are carried over through Photos' scripting
            interface, since PhotoKit has no write API for them, then read back to
            confirm they stuck. Anything that did not is reported above rather than
            passed over, and the ledger records what each new asset was meant to
            carry — so a failed transfer can be repeated by hand, not reconstructed.

            Not carried over: People assignments — no supported API can set them. They
            are normally re-derived on their own, because Photos assigns faces by
            recognition rather than by hand; analysis runs while the Mac is idle, so
            give it time. Edit history and the original date added are likewise not
            transferable this way.

            Also not inherited: iCloud Shared Photo Library membership. Copies are
            created in your personal library even when the original was shared. Move
            them in Photos.app if you need them shared — and note that deleting a
            shared original removes it for the other participants too, while your
            converted copy stays personal.

            Review \(reviewTarget) in Photos.app.
            """)

        if destAlbum == nil && markedForDeletion > 0 {
            print("""

                The \(markedForDeletion) JPEG(s) this run replaced are gathered in \
                "\(WorkspaceLayout.convertedOriginalsAlbum)", next to their copies. \
                Deleting them is your step, and it is the one that finally reclaims \
                the space — they will sit in Recently Deleted for 30 days first.

                Inside an album, use Cmd+Backspace. Plain Backspace only takes a photo \
                out of the album: the file stays, nothing reaches Recently Deleted, and \
                nothing tells you it did not happen.
                """)
        }
    }

    /// One photo that passed every gate and is waiting to be imported.
    private struct Accepted {
        let entry: LedgerEntry
        let sourceAsset: PHAsset
        let folder: String
        let heicName: String
        /// Only on the Photos.app route: the copy named as the asset should be,
        /// since Photos takes the filename from the file.
        let preparedFile: URL?
        let stagedPath: String
    }

    // MARK: - Duplicates

    private enum DuplicateAnswer {
        case importIt
        case skip
        case importRest
        case quit
    }

    /// Asks once per colliding photo. Defaults to *not* importing, because the
    /// cost of the two mistakes is not symmetric: a skip is undone by re-running,
    /// a second copy is undone by hand in Photos.app.
    private func askAboutDuplicate(
        filename: String,
        question: String,
        existingBytes: Int?,
        stagedBytes: Int?,
        existing: LibraryCopy
    ) -> DuplicateAnswer {
        let existingSize = existingBytes.map(Format.bytes) ?? "size unknown"
        let stagedSize = stagedBytes.map(Format.bytes) ?? "size unknown"
        print("""

              \(filename) — \(question)
                existing  \(existingSize)  \(existing.pixelWidth)x\(existing.pixelHeight)
                staged    \(stagedSize)
            """)

        while true {
            print("  Import anyway? [y/N/a=all/q=quit]: ", terminator: "")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else {
                // stdin closed mid-run: treat as the default rather than looping.
                return .skip
            }
            switch answer {
            case "y", "yes": return .importIt
            case "", "n", "no": return .skip
            case "a", "all": return .importRest
            case "q", "quit": return .quit
            default: continue
            }
        }
    }

    // MARK: - Text metadata

    private struct TextTransferReport {
        var attempted = 0
        var confirmed = 0
        var problems: [String] = []

        var summary: String {
            if attempted == 0 { return "nothing to transfer" }
            if problems.isEmpty { return "\(confirmed) of \(attempted), verified" }
            return "\(confirmed) of \(attempted) — \(problems.count) not confirmed"
        }
    }

    /// Applies the captured metadata to the new assets, then reads it back to
    /// confirm it stuck. Never throws: the assets already exist, and the ledger
    /// records what each was meant to carry.
    private func transferTextMetadata(
        _ assignments: [String: AssetTextMetadata],
        ledger: Ledger,
        filenames: [String: String]
    ) async -> TextTransferReport {
        var report = TextTransferReport(attempted: assignments.count)
        guard !assignments.isEmpty else { return report }

        do {
            let refused = try await PhotosScripting.writeTextMetadata(assignments)
            for identifier in refused {
                report.problems.append("\(filenames[identifier] ?? identifier): Photos refused the update")
            }

            // Verify rather than assume: read the new assets back and compare
            // against what we intended to set. Asked for by identifier, so it no
            // longer matters which album — or which month's folder — they went to.
            let actual = try await PhotosScripting.readTextMetadata(
                forIdentifiers: Array(assignments.keys)
            )
            for (identifier, expected) in assignments where !refused.contains(identifier) {
                let got = actual[identifier]
                if matches(expected: expected, actual: got) {
                    report.confirmed += 1
                } else {
                    report.problems.append("\(filenames[identifier] ?? identifier): metadata did not stick")
                }
                try? ledger.append(LedgerEntry(
                    outcome: .applied,
                    sourceLocalIdentifier: identifier,
                    originalFilename: filenames[identifier] ?? identifier,
                    sourceTextMetadata: expected,
                    appliedTextMetadata: got,
                    createdAssetLocalIdentifier: identifier
                ))
            }
        } catch {
            report.problems.append("could not reach Photos: \(error)")
        }

        if !report.problems.isEmpty {
            print("\nMetadata transfer problems")
            for problem in report.problems.prefix(10) { print("  \(problem)") }
        }
        return report
    }

    /// Keyword order is not meaningful, so compare as sets.
    private func matches(expected: AssetTextMetadata, actual: AssetTextMetadata?) -> Bool {
        guard let actual else { return false }
        guard Set(expected.keywords) == Set(actual.keywords) else { return false }
        guard (expected.title ?? "") == (actual.title ?? "") else { return false }
        return (expected.caption ?? "") == (actual.caption ?? "")
    }

    /// Keeps the original stem so the pair stays recognisable side by side — and
    /// so `select` and the duplicate check can find the copy again.
    private func heicFilename(from original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        return stem.isEmpty ? "converted.heic" : "\(stem).heic"
    }
}
