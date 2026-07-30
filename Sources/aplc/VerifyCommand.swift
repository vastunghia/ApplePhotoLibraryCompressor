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
            Reads the ledger, re-opens each staged file and re-runs the post-conditions
            against the facts recorded for its original. Also confirms each file still
            hashes to what was written, so a corrupted or swapped file is caught.

            `apply` refuses to run unless this passes, so it is not optional.
            """
    )

    @OptionGroup var staging: StagingOptions
    @OptionGroup var gate: GateOptions

    func run() async throws {
        let report = try Self.verify(staging: staging, gate: gate)

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
            print("\nNothing staged yet. Run `aplc transcode` first.")
            return
        }
        print("\nAll staged files check out.")
    }

    /// Shared with `apply`, which will not proceed unless this comes back clean.
    static func verify(staging: StagingOptions, gate: GateOptions) throws -> VerificationReport {
        let entries = try Ledger.readAll(at: staging.ledgerURL)
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

            // The file on disk must be byte-identical to what was recorded.
            if let expected = entry.stagedSHA256 {
                let actual = try Digest.sha256(of: url)
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
