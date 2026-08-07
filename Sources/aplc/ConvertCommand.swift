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

            Given --year alone it does all of that for each of the twelve months
            in turn, with its own staging each time, so the peak on disk is one
            month's worth however long the run is. A month that fails does not
            stop the others: it is reported in the summary at the end, and the
            command exits non-zero. Interrupting is safe, and re-running picks up
            where it left off — what is already converted is a question the
            library answers, not the run.

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

    @Option(help: "Stop after this many assets per month, in both transcode and apply.")
    var limit: Int?

    @Option(help: "How many photos to convert at once. Defaults to half the CPU cores; more is barely faster.")
    var jobs: Int = Transcode.defaultJobs

    @Flag(name: .customLong("dry-run"),
          help: "Do everything except write to the library.")
    var dryRun: Bool = false

    @Flag(name: .customLong("import-via-applescript"),
          help: "Let Photos.app import the file, so it gets an import session.")
    var importViaAppleScript: Bool = false

    func validate() throws { try source.requireSelection() }

    /// How one month of a run ended.
    ///
    /// A year is twelve independent conversions, so a month that fails is a
    /// result to record and report, not a reason to throw away the eleven
    /// others. With a single month there is nothing to go on to, and `.failed`
    /// becomes the same non-zero exit it always was.
    private enum MonthOutcome {
        case nothingToConvert
        case nothingConvertible
        case gateRejectedAll
        case done
        case failed(String)

        var summary: String {
            switch self {
            case .nothingToConvert: return "nothing left to convert"
            case .nothingConvertible: return "nothing convertible"
            case .gateRejectedAll: return "every photo rejected by the gate"
            case .done: return "done"
            case .failed(let why): return "failed — \(why)"
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    func run() async throws {
        // One scope unless a bare --year was given, in which case twelve, run in
        // order. Each is a self-contained conversion with its own staging: the
        // journal is scoped by staging root, so sharing one across months would
        // have December re-verifying January.
        let scopes = source.scopes
        let wholeYear = scopes.count > 1
        var results: [(label: String, outcome: MonthOutcome)] = []

        for (index, scope) in scopes.enumerated() {
            let label = Self.label(for: scope)
            if wholeYear {
                print("\n=== \(label) — \(index + 1) of \(scopes.count) ===")
            }

            let outcome: MonthOutcome
            do {
                outcome = try await convertOne(scope: scope)
            } catch {
                // With one month there is nothing to carry on to, so the error
                // keeps its own exit code and its own message.
                guard wholeYear else { throw error }
                outcome = .failed("\(error)")
            }
            results.append((label, outcome))

            if wholeYear, outcome.isFailure {
                print("\n\(label) \(outcome.summary). Going on to the next month.")
            }
        }

        if wholeYear {
            print("\nThe year, month by month")
            print(Format.table(results.map { ($0.label, $0.outcome.summary) }))
        }

        // Non-zero when any month failed, so a year run can still be trusted in
        // a script even though it does not stop at the first problem.
        if results.contains(where: { $0.outcome.isFailure }) { throw ExitCode.failure }
    }

    /// "March 2019", or the album's own name.
    private static func label(for scope: SourceAlbumOptions) -> String {
        guard let key = scope.monthKey else { return scope.displayName }
        return MonthBounds.label(year: key.year, month: key.month)
    }

    /// The whole pipeline over one month, or one named album.
    private func convertOne(scope: SourceAlbumOptions) async throws -> MonthOutcome {
        // This run owns the staging directory, and the delegated commands are
        // handed it by path. To them it is pinned, so only this command's
        // `cleanUp` can remove it — and it always does, success or failure.
        // A month of a year gets its own, so the peak on disk is one month's
        // worth however long the run is.
        let area: StagingArea
        if source.isWholeYear, let key = scope.monthKey {
            area = try staging.makeArea(named: WorkspaceLayout.monthFolder(key))
        } else {
            area = try staging.makeArea()
        }
        defer { area.cleanUp() }
        let ledgerURL = try ledgerOptions.url()

        // Both delegated commands are parsed before any work happens. Composing
        // by argument list means an option name could be wrong; parsing up front
        // turns that into a failure in the first second rather than after an
        // hour of transcoding. It cannot produce a wrong conversion — only a
        // refusal to start.
        let transcode = try Transcode.parse(transcodeArguments(scope: scope, area: area))
        let apply = try Apply.parse(applyArguments(scope: scope, area: area))

        // "Stopping" is the truth for one month, and a lie inside a year: there
        // the run goes straight on to the next one.
        let stopping = source.isWholeYear ? "" : " Stopping."

        if let key = scope.monthKey, scope.shouldRefreshSelection {
            print("[1/5] Selecting what \(scope.displayName) still has to convert")
            let outcome = try await Select.fill(year: key.year, month: key.month, into: nil)
            guard outcome.destination != nil else {
                print("\n\(scope.nothingLeftMessage)\(stopping)")
                return .nothingToConvert
            }
            print("  \(outcome.added) added, \(outcome.alreadyInAlbum) already there.")
        } else {
            print("[1/5] Working on \(scope.displayName) as it stands")
        }

        print("\n[2/5] Scanning \(scope.displayName)")
        // Already selected just above, so the census must not do it again.
        guard let census = try await Scan.census(source: scope, refreshingSelection: false) else {
            print("\n\(scope.nothingLeftMessage)\(stopping)")
            return .nothingToConvert
        }
        Scan.report(census, album: scope.displayName)
        guard census.eligible > 0 else {
            print("\nNothing in \(scope.displayName) can be converted.\(stopping)")
            return .nothingConvertible
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
            return .failed("`verify` found \(report.problems.count) problem(s)")
        }
        guard report.checked > 0 else {
            print("\nNothing was staged — every photo was rejected by the gate.\(stopping)")
            return .gateRejectedAll
        }

        let where_ = destAlbum.map { "\"\($0)\"" } ?? "the workspace"
        print("\n[5/5] \(dryRun ? "Planning the import" : "Adding copies to \(where_)")")
        try await apply.run()
        return .done
    }

    func transcodeArguments(scope: SourceAlbumOptions, area: StagingArea) -> [String] {
        var arguments = area.forwardedArguments + ledgerOptions.forwardedArguments + [
            "--max-download-gb", "\(maxDownloadGB)",
            "--chained",
        ]
        arguments += scope.forwardedArguments
        arguments += gateArguments()
        if let limit { arguments += ["--limit", "\(limit)"] }
        arguments += ["--jobs", "\(jobs)"]
        return arguments
    }

    func applyArguments(scope: SourceAlbumOptions, area: StagingArea) -> [String] {
        var arguments = area.forwardedArguments + ledgerOptions.forwardedArguments + [
            "--chained",
        ]
        arguments += scope.forwardedArguments
        if let destAlbum { arguments += ["--dest-album", destAlbum] }
        if importViaAppleScript { arguments.append("--import-via-applescript") }
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
