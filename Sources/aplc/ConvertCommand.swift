import APLCCore
import ArgumentParser
import Foundation

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Scan, transcode, verify — then add the copies to your library. Writes.",
        discussion: """
            The whole pipeline in one command, for when you already know you want
            the converted copies. Unlike `apply`, this does not ask for --confirm:
            typing `convert` is the confirmation. Pass --dry-run to see what it
            would do without writing anything.

            With --year and --month it starts by bringing that month's "Selected
            Originals" up to date, so a month you have never selected needs no
            preparatory command.

            It still cannot destroy. The JPEG originals are untouched, nothing is
            deleted, and the copies land in --dest-album where you can delete them
            by hand if you change your mind. Removing the originals afterwards is
            a manual step in Photos.app, as always.

            Staged files live in a temporary directory that is removed when the
            run ends, whether it succeeded or not. Nothing is left on disk except
            the journal.

            Stops before writing if the month has nothing left to convert, if the
            gate rejected everything, or if `verify` finds a problem.

            Safe to re-run: assets already imported are not imported twice, both
            because the journal remembers them and because the library is asked
            directly.

            `calibrate` is deliberately not part of this. It exists to be looked
            at — it writes sample files for you to judge by eye — and quality is
            now chosen per photo anyway.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var ledgerOptions: LedgerOptions
    @OptionGroup var gate: GateOptions

    @OptionGroup var source: SourceAlbumOptions

    @Option(name: .customLong("dest-album"),
            help: "Put every copy in this one album instead of the workspace's month folders.")
    var destAlbum: String?

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads entirely.")
    var maxDownloadGB: Double = 5.0

    @Option(help: "Stop after this many assets, in both transcode and apply.")
    var limit: Int?

    @Flag(name: .customLong("dry-run"),
          help: "Do everything except write to the library.")
    var dryRun: Bool = false

    func validate() throws { try source.requireSelection() }

    func run() async throws {
        // This run owns the staging directory, and the delegated commands are
        // handed it by path. To them it is pinned, so only this command's
        // `cleanUp` can remove it — and it always does, success or failure.
        let area = try staging.makeArea()
        defer { area.cleanUp() }
        let ledgerURL = try ledgerOptions.url()

        // Both delegated commands are parsed before any work happens. Composing
        // by argument list means an option name could be wrong; parsing up front
        // turns that into a failure in the first second rather than after an
        // hour of transcoding. It cannot produce a wrong conversion — only a
        // refusal to start.
        let transcode = try Transcode.parse(transcodeArguments(area: area))
        let apply = try Apply.parse(applyArguments(area: area))

        if let key = source.monthKey, source.shouldRefreshSelection {
            print("[1/5] Selecting what \(source.displayName) still has to convert")
            let outcome = try await Select.fill(year: key.year, month: key.month, into: nil)
            guard outcome.destination != nil else {
                print("\n\(source.nothingLeftMessage) Stopping.")
                return
            }
            print("  \(outcome.added) added, \(outcome.alreadyInAlbum) already there.")
        } else {
            print("[1/5] Working on \(source.displayName) as it stands")
        }

        print("\n[2/5] Scanning \(source.displayName)")
        // Already selected just above, so the census must not do it again.
        guard let census = try await Scan.census(source: source, refreshingSelection: false) else {
            print("\n\(source.nothingLeftMessage) Stopping.")
            return
        }
        Scan.report(census, album: source.displayName)
        guard census.eligible > 0 else {
            print("\nNothing in \(source.displayName) can be converted. Stopping.")
            return
        }

        print("\n[3/5] Transcoding \(census.eligible) convertible photo(s)")
        try await transcode.run()

        print("\n[4/5] Verifying")
        let read = try Ledger.read(at: ledgerURL)
        ledgerOptions.warnIfDamaged(read)
        let report = Verify.verify(entries: read.entries, stagedUnder: area.root, gate: gate)
        print(Format.table([
            ("staged entries checked", "\(report.checked)"),
            ("passed", "\(report.passed)"),
            ("problems", "\(report.problems.count)"),
        ]))
        guard report.problems.isEmpty else {
            print("\nProblems")
            for problem in report.problems.prefix(10) {
                print("  \(problem.file): \(problem.detail)")
            }
            print("\nStopping: nothing will be written to your library.")
            throw ExitCode.failure
        }
        guard report.checked > 0 else {
            print("\nNothing was staged — every photo was rejected by the gate. Stopping.")
            return
        }

        let where_ = destAlbum.map { "\"\($0)\"" } ?? "the workspace"
        print("\n[5/5] \(dryRun ? "Planning the import" : "Adding copies to \(where_)")")
        try await apply.run()
    }

    func transcodeArguments(area: StagingArea) -> [String] {
        var arguments = area.forwardedArguments + ledgerOptions.forwardedArguments + [
            "--max-download-gb", "\(maxDownloadGB)",
            "--chained",
        ]
        arguments += source.forwardedArguments
        arguments += gateArguments()
        if let limit { arguments += ["--limit", "\(limit)"] }
        return arguments
    }

    func applyArguments(area: StagingArea) -> [String] {
        var arguments = area.forwardedArguments + ledgerOptions.forwardedArguments + [
            "--chained",
        ]
        arguments += source.forwardedArguments
        if let destAlbum { arguments += ["--dest-album", destAlbum] }
        arguments += gateArguments()
        if let limit { arguments += ["--limit", "\(limit)"] }
        // The chain's whole premise: the user already confirmed by typing
        // `convert`. --dry-run is what withholds it.
        if !dryRun { arguments.append("--confirm") }
        return arguments
    }

    /// Forwarded so the two steps judge by the same rules — `verify` and `apply`
    /// re-run the gate later, and a mismatch here would reject staged files that
    /// were perfectly acceptable when they were written.
    private func gateArguments() -> [String] {
        var arguments = [
            "--min-ssim", "\(gate.minSSIM)",
            "--max-size-ratio", "\(gate.maxSizeRatio)",
        ]
        if let quality = gate.quality { arguments += ["--quality", "\(quality)"] }
        if gate.strictColorProfile { arguments.append("--strict-color-profile") }
        return arguments
    }
}
