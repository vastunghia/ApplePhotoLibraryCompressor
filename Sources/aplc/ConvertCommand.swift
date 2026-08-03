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

            It still cannot destroy. The JPEG originals are untouched, nothing is
            deleted, and the copies land in --dest-album where you can delete them
            by hand if you change your mind. Removing the originals afterwards is
            a manual step in Photos.app, as always.

            Stops before writing if the album holds nothing convertible, if the
            gate rejected everything, or if `verify` finds a problem.

            Safe to re-run: transcoding resumes where it left off, and assets
            already imported are not imported twice.

            `calibrate` is deliberately not part of this. It exists to be looked
            at — it writes sample files for you to judge by eye — and quality is
            now chosen per photo anyway.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var gate: GateOptions

    @Option(help: "Title of the album to convert.")
    var album: String

    @Option(name: .customLong("dest-album"),
            help: "Album to place the converted copies in. Created if absent.")
    var destAlbum: String

    @Option(name: .customLong("max-download-gb"),
            help: "Ceiling on data pulled from iCloud, in GB. 0 refuses downloads entirely.")
    var maxDownloadGB: Double = 5.0

    @Option(help: "Stop after this many assets, in both transcode and apply.")
    var limit: Int?

    @Flag(name: .customLong("dry-run"),
          help: "Do everything except write to the library.")
    var dryRun: Bool = false

    func run() async throws {
        // Both delegated commands are parsed before any work happens. Composing
        // by argument list means an option name could be wrong; parsing up front
        // turns that into a failure in the first second rather than after an
        // hour of transcoding. It cannot produce a wrong conversion — only a
        // refusal to start.
        let transcode = try Transcode.parse(transcodeArguments())
        let apply = try Apply.parse(applyArguments())

        print("[1/4] Scanning \"\(album)\"")
        let census = try await Scan.census(album: album)
        Scan.report(census, album: album)
        guard census.eligible > 0 else {
            print("\nNothing in \"\(album)\" can be converted. Stopping.")
            return
        }

        print("\n[2/4] Transcoding \(census.eligible) convertible photo(s)")
        try await transcode.run()

        print("\n[3/4] Verifying")
        let report = try Verify.verify(staging: staging, gate: gate)
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

        print("\n[4/4] \(dryRun ? "Planning the import" : "Adding copies to \"\(destAlbum)\"")")
        try await apply.run()
    }

    func transcodeArguments() -> [String] {
        var arguments = [
            "--out", staging.out,
            "--album", album,
            "--max-download-gb", "\(maxDownloadGB)",
            "--chained",
        ]
        arguments += gateArguments()
        if let limit { arguments += ["--limit", "\(limit)"] }
        return arguments
    }

    func applyArguments() -> [String] {
        var arguments = [
            "--out", staging.out,
            "--album", album,
            "--dest-album", destAlbum,
            "--chained",
        ]
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
