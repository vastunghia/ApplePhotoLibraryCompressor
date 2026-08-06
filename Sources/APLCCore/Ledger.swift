import Foundation
import CryptoKit

public enum LedgerOutcome: String, Sendable, Codable {
    /// HEIC written to staging and it passed the gate. Nothing touched the library.
    case transcoded
    /// Asset was not converted; `skipReason` says why.
    case skipped
    /// A new HEIC asset was created in the library from a staged file.
    case applied
    /// Something went wrong; `error` carries the detail.
    case failed
}

public struct LedgerEntry: Sendable, Codable {
    public var timestamp: Date
    public var outcome: LedgerOutcome
    public var sourceLocalIdentifier: String
    public var originalFilename: String

    public var skipReason: SkipReason?
    public var error: String?

    public var stagedPath: String?
    public var sourceSHA256: String?
    public var stagedSHA256: String?

    public var sourceBytes: Int?
    public var stagedBytes: Int?
    public var quality: Double?
    public var ssim: Double?
    public var psnr: Double?

    /// Facts read off the exported original and off the written HEIC. Recorded
    /// so `verify` can re-check the post-conditions later without having to
    /// pull the original out of the library a second time.
    public var sourceFacts: ImageFacts?
    public var stagedFacts: ImageFacts?

    /// Keywords, title and caption read off the source asset via Photos
    /// scripting, and what was actually read back after applying them to the
    /// new asset. A difference between the two is a transfer that did not stick.
    public var sourceTextMetadata: AssetTextMetadata?
    public var appliedTextMetadata: AssetTextMetadata?

    /// Identifier of the asset created by `apply`, if any.
    public var createdAssetLocalIdentifier: String?

    /// The asset already in the library that stopped this one being imported.
    /// Recorded so a skip says *what* it collided with, not merely that it did —
    /// which is the difference between a line you can act on and one you cannot.
    public var collidedWithLocalIdentifier: String?

    public init(
        timestamp: Date = Date(),
        outcome: LedgerOutcome,
        sourceLocalIdentifier: String,
        originalFilename: String,
        skipReason: SkipReason? = nil,
        error: String? = nil,
        stagedPath: String? = nil,
        sourceSHA256: String? = nil,
        stagedSHA256: String? = nil,
        sourceBytes: Int? = nil,
        stagedBytes: Int? = nil,
        quality: Double? = nil,
        ssim: Double? = nil,
        psnr: Double? = nil,
        sourceFacts: ImageFacts? = nil,
        stagedFacts: ImageFacts? = nil,
        sourceTextMetadata: AssetTextMetadata? = nil,
        appliedTextMetadata: AssetTextMetadata? = nil,
        createdAssetLocalIdentifier: String? = nil,
        collidedWithLocalIdentifier: String? = nil
    ) {
        self.timestamp = timestamp
        self.outcome = outcome
        self.sourceLocalIdentifier = sourceLocalIdentifier
        self.originalFilename = originalFilename
        self.skipReason = skipReason
        self.error = error
        self.stagedPath = stagedPath
        self.sourceSHA256 = sourceSHA256
        self.stagedSHA256 = stagedSHA256
        self.sourceBytes = sourceBytes
        self.stagedBytes = stagedBytes
        self.quality = quality
        self.ssim = ssim
        self.psnr = psnr
        self.sourceFacts = sourceFacts
        self.stagedFacts = stagedFacts
        self.sourceTextMetadata = sourceTextMetadata
        self.appliedTextMetadata = appliedTextMetadata
        self.createdAssetLocalIdentifier = createdAssetLocalIdentifier
        self.collidedWithLocalIdentifier = collidedWithLocalIdentifier
    }
}

/// Where the journal lives.
///
/// Deliberately *not* in the staging directory any more. Staging is scratch space
/// that is thrown away when the run ends; the record of what was done to an
/// irreplaceable library has to outlive it. This is also what finally makes
/// `appliedIdentifiers` mean something across runs: the duplicate HEICs already
/// in the library were made by pointing a fresh staging directory at an album
/// that had been converted before, and a ledger that died with the folder could
/// not have known.
public enum LedgerLocation {
    public static let filename = "aplc_ledger.jsonl"

    /// `~/Library/Application Support/aplc/aplc_ledger.jsonl`.
    ///
    /// Not beside the photo library, which would have been the obvious home:
    /// PhotoKit exposes no URL for it, there can be more than one `.photoslibrary`
    /// in `~/Pictures`, and the bundle is Photos' to manage — a stray file inside
    /// it is a file a library repair may remove.
    public static func standard() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("aplc").appendingPathComponent(filename)
    }
}

/// What a read of the journal found, damage included.
public struct LedgerRead: Sendable {
    public let entries: [LedgerEntry]

    /// Lines that could not be decoded. Reported rather than thrown on, and
    /// counted rather than passed over in silence — see `read(at:)`.
    public let unreadableLines: Int

    public init(entries: [LedgerEntry], unreadableLines: Int) {
        self.entries = entries
        self.unreadableLines = unreadableLines
    }
}

/// Append-only JSONL journal, one line per asset per phase.
///
/// Two properties matter. Every line is flushed and `fsync`ed before the caller
/// proceeds, so a crash can never leave a library write unrecorded. And because
/// it is append-only, a later run can reconstruct exactly what an earlier one
/// did — which is what makes `apply` idempotent.
public final class Ledger {
    public let url: URL
    private let handle: FileHandle
    private let encoder: JSONEncoder

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // O_APPEND rather than seek-to-end. The journal is now one file shared by
        // every run there will ever be, so two `aplc` processes can hold it open
        // at once; with a remembered offset they would write over each other's
        // lines, and with O_APPEND the kernel places each write at the real end.
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    deinit { try? handle.close() }

    /// Writes one entry and does not return until it is durably on disk.
    public func append(_ entry: LedgerEntry) throws {
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        // fsync, not just flush: the whole point is surviving a hard stop.
        fsync(handle.fileDescriptor)
    }

    /// Reads the journal, skipping lines it cannot decode and saying how many.
    ///
    /// It used to throw on the first bad line, which was the right call when the
    /// file lived in a staging directory you could delete. A permanent journal
    /// makes that a trap: one truncated line from a hard stop would refuse every
    /// future run, with nothing to delete that would not also lose the history.
    /// Skipping silently would be worse still, so the count comes back with the
    /// entries and the commands say it out loud.
    public static func read(at url: URL) throws -> LedgerRead {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LedgerRead(entries: [], unreadableLines: 0)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        var entries: [LedgerEntry] = []
        var damaged = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = try? dec.decode(LedgerEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
            } else {
                damaged += 1
            }
        }
        return LedgerRead(entries: entries, unreadableLines: damaged)
    }

    public static func readAll(at url: URL) throws -> [LedgerEntry] {
        try read(at: url).entries
    }

    /// The entries whose staged file belongs to this staging root — that is, the
    /// ones this run put there.
    ///
    /// The journal is global now, so `verify` and `apply` would otherwise reach
    /// back over every transcode ever made, all of them pointing at temporary
    /// directories that no longer exist.
    public static func entries(_ entries: [LedgerEntry], stagedUnder root: URL) -> [LedgerEntry] {
        // The trailing separator is not decoration: without it "/tmp/aplc-1"
        // would also claim everything staged under "/tmp/aplc-10".
        let prefix = root.standardizedFileURL.path + "/"
        return entries.filter { ($0.stagedPath?.hasPrefix(prefix)) == true }
    }

    /// Local identifiers this journal says were carried through to a created
    /// asset.
    ///
    /// What the journal *says*, which is not the same as what is true: the copy
    /// it names may since have been deleted. Anything using this as a reason to
    /// skip work must check the library first — see `appliedCopies`.
    public static func appliedIdentifiers(at url: URL) throws -> Set<String> {
        appliedIdentifiers(in: try readAll(at: url))
    }

    public static func appliedIdentifiers(in entries: [LedgerEntry]) -> Set<String> {
        Set(entries.filter { $0.outcome == .applied }.map(\.sourceLocalIdentifier))
    }

    /// Each conversion this journal recorded, as the JPEG it came from and the
    /// asset it became.
    ///
    /// The pair is what makes the record checkable. The journal is permanent
    /// now, so it long outlives the copies it describes — delete every HEIC and
    /// it still claims those JPEGs are converted. That claim must never gate
    /// work on its own: "already converted" is a property of the library, which
    /// is exactly why the rest of this tool infers it rather than recording it.
    /// The caller asks the library which of these `created` identifiers survive,
    /// and believes only those.
    public static func appliedCopies(in entries: [LedgerEntry]) -> [(source: String, created: String)] {
        entries.compactMap { entry in
            guard entry.outcome == .applied,
                  let created = entry.createdAssetLocalIdentifier
            else { return nil }
            return (entry.sourceLocalIdentifier, created)
        }
    }
}

public enum Digest {
    /// SHA-256 of a file, streamed so that multi-hundred-MB originals do not
    /// have to be held in memory.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
