import APLCCore
import ArgumentParser
import Foundation

struct VerificationReport {
    var checked = 0
    var passed = 0
    var problems: [(file: String, detail: String)] = []

    var isClean: Bool { problems.isEmpty && checked > 0 }
}

struct Verify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Re-check every staged HEIC before anything is allowed into the library.",
        discussion: """
            Reads the journal, re-opens each staged file and re-runs the post-conditions
            against the facts recorded for its original. Also confirms each file still
            hashes to what was written, so a corrupted or swapped file is caught.

            `apply` refuses to run unless this passes, so it is not optional — and
            it runs this itself, which is why it is normally not typed at all.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var ledgerOptions: LedgerOptions
    @OptionGroup var gate: GateOptions

    func run() async throws {
        let area = try staging.makeArea()
        defer { area.cleanUp() }
        let read = try Ledger.read(at: try ledgerOptions.url())
        ledgerOptions.warnIfDamaged(read)
        let report = Self.verify(entries: read.entries, stagedUnder: area.root, gate: gate)

        print("\nVerification")
        print(Format.table([
            ("staged entries checked", "\(report.checked)"),
            ("passed", "\(report.passed)"),
            ("problems", "\(report.problems.count)"),
        ]))

        if !report.problems.isEmpty {
            print("\nProblems")
            for problem in report.problems {
                print("  \(problem.file): \(problem.detail)")
            }
            throw ExitCode.failure
        }

        if report.checked == 0 {
            print("""

                Nothing is staged. Staging is temporary, so a `transcode` that has \
                already finished has taken its files with it — `aplc convert` runs \
                this step in the same breath, which is the ordinary way to reach it.
                """)
            return
        }
        print("\nAll staged files check out.")
    }

    /// Shared with `apply`, which will not proceed unless this comes back clean.
    ///
    /// Takes the entries already read and the staging root to scope them to. The
    /// journal is permanent and global now, so verifying everything in it would
    /// mean re-checking every transcode ever made — all of them staged in
    /// temporary directories that are long gone, and every one of them reported
    /// as a missing file. That would stop `convert` dead on a healthy run.
    static func verify(
        entries allEntries: [LedgerEntry],
        stagedUnder root: URL,
        gate: GateOptions
    ) -> VerificationReport {
        let entries = Ledger.entries(allEntries, stagedUnder: root)
        let policy = gate.policy(allowDownloads: true)
        var report = VerificationReport()

        for entry in entries where entry.outcome == .transcoded {
            report.checked += 1
            let label = entry.originalFilename

            guard let path = entry.stagedPath else {
                report.problems.append((label, "ledger entry has no staged path"))
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                report.problems.append((label, "staged file is missing: \(path)"))
                continue
            }

            // The file on disk must be byte-identical to what was recorded. A
            // file that cannot even be read is a problem to report, not an error
            // to throw: one unreadable staged file must not hide the verdict on
            // all the others.
            if let expected = entry.stagedSHA256 {
                guard let actual = try? Digest.sha256(of: url) else {
                    report.problems.append((label, "staged file could not be read: \(path)"))
                    continue
                }
                guard actual == expected else {
                    report.problems.append((label, "staged file has changed since it was written"))
                    continue
                }
            }

            let facts: ImageFacts
            do {
                facts = try ImageProbe.probe(url)
            } catch {
                report.problems.append((label, "staged file is unreadable: \(error)"))
                continue
            }

            guard let recordedStaged = entry.stagedFacts, let recordedSource = entry.sourceFacts else {
                report.problems.append((label, "ledger entry lacks the recorded image facts"))
                continue
            }
            guard facts == recordedStaged else {
                report.problems.append((label, "staged file no longer matches its recorded properties"))
                continue
            }

            let score = entry.ssim.map {
                QualityScore(ssim: $0, psnr: entry.psnr ?? .infinity,
                             width: facts.width, height: facts.height)
            }
            let outcome = EligibilityGate.evaluatePostConditions(
                source: recordedSource, destination: facts, quality: score, policy: policy
            )
            if case .skip(let reason) = outcome {
                report.problems.append((label, "fails the gate on re-check: \(reason.explanation)"))
                continue
            }

            report.passed += 1
        }

        return report
    }
}
