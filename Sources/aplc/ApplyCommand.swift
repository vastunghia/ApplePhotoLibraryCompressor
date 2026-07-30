import APLCCore
import ArgumentParser
import Foundation
import Photos

struct Apply: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Add staged HEIC files to the library as new assets. Deletes nothing.",
        discussion: """
            This is the only command that writes to your photo library, and it can
            only add. The JPEG originals stay exactly where they are; your library
            will temporarily grow. Removing the originals is a manual step in
            Photos.app, once you are satisfied with the copies.

            Runs as a dry run unless you pass --confirm. It refuses to start if
            `verify` reports any problem, and it skips assets already applied, so
            running it twice cannot create duplicates.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var gate: GateOptions

    @Option(help: "Title of the album the originals came from.")
    var album: String

    @Option(name: .customLong("dest-album"),
            help: "Album to place the converted copies in. Created if absent.")
    var destAlbum: String

    @Flag(help: "Actually write to the library. Without this, nothing is created.")
    var confirm: Bool = false

    @Option(help: "Apply at most this many assets.")
    var limit: Int?

    func run() async throws {
        // Gate one: staged files must pass an independent re-check.
        let report = try Verify.verify(staging: staging, gate: gate)
        guard report.problems.isEmpty else {
            print("Refusing to apply: `verify` found \(report.problems.count) problem(s).")
            for problem in report.problems.prefix(10) {
                print("  \(problem.file): \(problem.detail)")
            }
            throw ExitCode.failure
        }

        let entries = try Ledger.readAll(at: staging.ledgerURL)
        let alreadyApplied = try Ledger.appliedIdentifiers(at: staging.ledgerURL)
        let pending = entries
            .filter { $0.outcome == .transcoded }
            .filter { !alreadyApplied.contains($0.sourceLocalIdentifier) }

        guard !pending.isEmpty else {
            print("Nothing to apply. \(alreadyApplied.count) asset(s) were applied previously.")
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
            ("destination album", destAlbum),
        ]))

        guard confirm else {
            print("""

                Dry run — nothing was written. Re-run with --confirm to create these assets.
                """)
            return
        }

        try await PhotoLibraryAccess.authorize()

        // Match staged entries back to live assets by local identifier.
        let sourceCollection = try PhotoLibraryAccess.findAlbum(titled: album)
        var assetsByIdentifier: [String: PHAsset] = [:]
        for asset in PhotoLibraryAccess.imageAssets(in: sourceCollection) {
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        let destination = try await Importer.ensureAlbum(titled: destAlbum)
        let ledger = try Ledger(url: staging.ledgerURL)

        var created = 0
        var failed = 0
        /// New asset identifier -> the metadata it should end up carrying.
        var pendingText: [String: AssetTextMetadata] = [:]
        var createdFilenames: [String: String] = [:]

        for entry in planned {
            guard let stagedPath = entry.stagedPath else { continue }
            guard let source = assetsByIdentifier[entry.sourceLocalIdentifier] else {
                failed += 1
                try ledger.append(LedgerEntry(
                    outcome: .failed,
                    sourceLocalIdentifier: entry.sourceLocalIdentifier,
                    originalFilename: entry.originalFilename,
                    error: "source asset is no longer in album \"\(album)\""
                ))
                continue
            }

            do {
                let identifier = try await Importer.createAsset(
                    fromStagedHEIC: URL(fileURLWithPath: stagedPath),
                    originalFilename: heicFilename(from: entry.originalFilename),
                    metadata: Importer.CarriedMetadata(from: source),
                    into: destination
                )
                created += 1
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

        // Always write the restore file, before attempting the transfer: if the
        // Apple Events path fails, this is what makes the metadata recoverable.
        let restoreURL = try writeRestoreFile(pendingText, filenames: createdFilenames)

        let textReport = await transferTextMetadata(pendingText, ledger: ledger,
                                                    filenames: createdFilenames)

        print("\nApply summary")
        print(Format.table([
            ("assets created", "\(created)"),
            ("failures", "\(failed)"),
            ("album", destAlbum),
            ("keywords/title/caption transferred", textReport.summary),
        ]))

        print("""

            Your originals are untouched. Nothing was deleted.

            Keywords, title and caption are carried over through Photos' scripting
            interface, since PhotoKit has no write API for them. If that did not run,
            \(restoreURL.lastPathComponent) holds what each new asset should carry.

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

            Review \(destAlbum) in Photos.app. Deleting the JPEG originals — if you decide
            to — is a manual step, and they will sit in Recently Deleted for 30 days first.
            """)
    }

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
    /// confirm it stuck. Never throws: the assets already exist, and the restore
    /// file covers the failure case.
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

            // Verify rather than assume: read the destination album back and
            // compare against what we intended to set.
            let actual = try await PhotosScripting.readTextMetadata(inAlbumTitled: destAlbum)
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

    @discardableResult
    private func writeRestoreFile(
        _ assignments: [String: AssetTextMetadata],
        filenames: [String: String]
    ) throws -> URL {
        struct RestoreRecord: Encodable {
            let createdAssetLocalIdentifier: String
            let originalFilename: String
            let metadata: AssetTextMetadata
        }

        let records = assignments
            .map { RestoreRecord(createdAssetLocalIdentifier: $0.key,
                                 originalFilename: filenames[$0.key] ?? "",
                                 metadata: $0.value) }
            .sorted { $0.createdAssetLocalIdentifier < $1.createdAssetLocalIdentifier }

        let url = staging.stagingRoot.appendingPathComponent("metadata-restore.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url)
        return url
    }

    /// Keeps the original stem so the pair stays recognisable side by side.
    private func heicFilename(from original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        return stem.isEmpty ? "converted.heic" : "\(stem).heic"
    }
}
