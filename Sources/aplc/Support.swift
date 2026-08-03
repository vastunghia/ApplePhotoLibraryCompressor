import APLCCore
import ArgumentParser
import Foundation

/// Options shared by every command that reads a staging directory.
struct StagingOptions: ParsableArguments {
    @Option(name: .long, help: "Directory holding staged HEIC files and the ledger.")
    var out: String

    var stagingRoot: URL { URL(fileURLWithPath: out).standardizedFileURL }
    var heicDirectory: URL { stagingRoot.appendingPathComponent("heic") }
    var originalsDirectory: URL { stagingRoot.appendingPathComponent("originals") }
    var ledgerURL: URL { stagingRoot.appendingPathComponent("ledger.jsonl") }
}

struct GateOptions: ParsableArguments {
    // Deliberately without a default: omitting it selects the automatic search,
    // which picks a quality per asset to meet --min-ssim. Giving this a default
    // would make the manual path the silent one, and a default that the search
    // then overrode would be worse still — an option that appears to control the
    // output while doing nothing.
    //
    // ImageIO quantises the value into buckets rather than honouring every one:
    // see QualityLadder for the measured rungs. Anything between them rounds
    // down, so 0.80 and 0.85 give byte-identical files.
    @Option(help: "HEIC quality, 0.0 to 1.0. Omit to choose it per photo from --min-ssim.")
    var quality: Double?

    // 0.97 rather than something stricter: on real library photos q=0.8 lands
    // around 0.984 mean SSIM with outliers near 0.97, so a higher bar rejects
    // perfectly good conversions. Use `calibrate` to set this from your own set.
    //
    // In automatic mode this stops being a veto and becomes the objective — the
    // search returns the cheapest rung reaching it. The gate still checks it,
    // which is then a tautology; that is intentional, since the gate is also
    // what `verify` re-runs later against files it did not encode.
    @Option(name: .customLong("min-ssim"),
            help: "Target SSIM: the fidelity every converted photo must reach.")
    var minSSIM: Double = 0.97

    @Option(name: .customLong("max-size-ratio"),
            help: "Reject conversions whose HEIC exceeds this fraction of the JPEG's size.")
    var maxSizeRatio: Double = 0.9

    @Flag(name: .customLong("strict-color-profile"),
          help: "Require the ICC profile name to match exactly, not just be present.")
    var strictColorProfile: Bool = false

    func policy(allowDownloads: Bool) -> GatePolicy {
        GatePolicy(
            minSSIM: minSSIM,
            maxSizeRatio: maxSizeRatio,
            allowDownloads: allowDownloads,
            requireExactProfileMatch: strictColorProfile
        )
    }
}

enum Format {
    static func bytes(_ count: Int) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(count) B" : String(format: "%.2f %@", value, units[unit])
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    /// PHAsset local identifiers contain slashes ("UUID/L0/001"), which cannot
    /// go into a filename.
    static func safeFilename(for localIdentifier: String) -> String {
        localIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    static func table(_ rows: [(String, String)], indent: String = "  ") -> String {
        guard let widest = rows.map(\.0.count).max() else { return "" }
        return rows
            .map { "\(indent)\($0.0.padding(toLength: widest, withPad: " ", startingAt: 0))  \($0.1)" }
            .joined(separator: "\n")
    }
}

extension Double {
    var clampedToUnitInterval: Double { Swift.min(Swift.max(self, 0), 1) }
}
