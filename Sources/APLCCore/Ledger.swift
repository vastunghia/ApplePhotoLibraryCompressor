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
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle.seekToEnd()

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

    public static func readAll(at url: URL) throws -> [LedgerEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try dec.decode(LedgerEntry.self, from: Data($0.utf8)) }
    }

    /// Local identifiers already carried through to a created asset. `apply`
    /// consults this so a re-run cannot duplicate work.
    public static func appliedIdentifiers(at url: URL) throws -> Set<String> {
        Set(try readAll(at: url).filter { $0.outcome == .applied }.map(\.sourceLocalIdentifier))
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
