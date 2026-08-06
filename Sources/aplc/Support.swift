import APLCCore
import ArgumentParser
import Foundation
import Photos

/// Which photos a command works on: a month of the workspace, or a named album.
///
/// The two forms are exclusive. `--year`/`--month` is the normal way in, and
/// resolves to `aplc workspace` > `2026-02` > `Selected Originals`, the album
/// `select` fills. `--album` is the escape hatch for an album made by hand, and
/// keeps the behaviour every command had before the workspace existed.
struct SourceAlbumOptions: ParsableArguments {
    @Option(help: "Year the photos were taken, e.g. 2019. Use with --month.")
    var year: Int?

    @Option(help: "Month the photos were taken, 1 to 12. Use with --year.")
    var month: Int?

    @Option(help: "Work on this album by name instead of a month of the workspace.")
    var album: String?

    var isEmpty: Bool { year == nil && month == nil && album == nil }

    /// Checks that what was given makes sense together. Says nothing about
    /// whether *something* was given: `calibrate` can work from `--files` and
    /// needs no album at all, so that requirement belongs to each command.
    func validate() throws {
        if album != nil, year != nil || month != nil {
            throw ValidationError("--album and --year/--month are alternatives; give one or the other.")
        }
        guard album == nil, !isEmpty else { return }

        guard let year, let month else {
            throw ValidationError("--year and --month go together; give both.")
        }
        guard (1...12).contains(month) else {
            throw ValidationError("--month must be between 1 and 12, not \(month).")
        }
        guard (1...9999).contains(year) else {
            throw ValidationError("--year must be a four-digit year, not \(year).")
        }
    }

    /// For the commands that cannot work without an album.
    func requireSelection() throws {
        if isEmpty { throw ValidationError("give either --year and --month, or --album.") }
    }

    /// Nil when the command was pointed at a named album instead.
    var monthKey: MonthKey? {
        guard let year, let month, album == nil else { return nil }
        return MonthKey(year: year, month: month)
    }

    /// Finds the album. Never creates one: filling the workspace is `select`'s
    /// job, and a command that silently made an empty album to work on would be
    /// reporting on nothing.
    func resolve() throws -> PHAssetCollection {
        if let album { return try PhotoLibraryAccess.findAlbum(titled: album) }
        return try PhotoLibraryAccess.findWorkspaceAlbum(
            WorkspaceLayout.originalsAlbum,
            inFolderNamed: WorkspaceLayout.monthFolder(monthKey!)
        )
    }

    /// How to name this album in output, spelled the way the user would find it.
    var displayName: String {
        if let album { return "\"\(album)\"" }
        guard let key = monthKey else { return "the selected album" }
        return "\(WorkspaceLayout.rootFolder) > \(WorkspaceLayout.monthFolder(key)) > \(WorkspaceLayout.originalsAlbum)"
    }

    /// The same choice, as arguments — so `convert` can hand it to the commands
    /// it drives without deciding anything itself.
    var forwardedArguments: [String] {
        if let album { return ["--album", album] }
        guard let key = monthKey else { return [] }
        return ["--year", "\(key.year)", "--month", "\(key.month)"]
    }
}

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
