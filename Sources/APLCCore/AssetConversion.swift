import Foundation

/// One photo's conversion: a JPEG already on disk becomes a staged HEIC, judged
/// by the gate, with the journal line that describes what happened.
///
/// Deliberately free of PhotoKit. It takes a file, not a `PHAsset`, which is what
/// lets `transcode` run several of these at once — the library reads are all done
/// before any of them start — and what lets it be tested without a photo library.
/// It formats nothing: the progress lines belong to the command that prints them.
public enum AssetConversion {
    /// The encode that was kept, for the caller's running totals.
    public struct Converted: Sendable {
        public let result: TranscodeResult
        public let score: QualityScore
        /// Which rung the search settled on, to seed the next photo's search.
        /// Nil when `--quality` fixed it and no search happened.
        public let rungIndex: Int?

        public init(result: TranscodeResult, score: QualityScore, rungIndex: Int?) {
            self.result = result
            self.score = score
            self.rungIndex = rungIndex
        }
    }

    public enum Kind: Sendable {
        case converted(Converted)
        /// Not converted, and what the summary should tally it as. For a thrown
        /// error that is `.transcodeFailed` while the entry records `.failed`
        /// with the message — the two say different things on purpose.
        case notConverted(SkipReason)
    }

    public struct Outcome: Sendable {
        /// Ready to append. The caller writes it; nothing here touches the journal.
        public let entry: LedgerEntry
        public let kind: Kind
        /// Encodes performed. Zero when `--quality` fixed the value.
        public let probes: Int
        /// Whether the search ran at all, so "encodes per photo" divides by the
        /// right number.
        public let searched: Bool

        public init(entry: LedgerEntry, kind: Kind, probes: Int, searched: Bool) {
            self.entry = entry
            self.kind = kind
            self.probes = probes
            self.searched = searched
        }
    }

    /// - Parameters:
    ///   - source: the original, already exported out of the library.
    ///   - destination: where the HEIC goes. Removed again if the gate rejects it,
    ///     so nothing `apply` might later find is left behind.
    ///   - text: keywords, title and caption read from Photos, recorded in the
    ///     entry whatever happens to them.
    ///   - textIsAuthoritative: false when Photos could not be reached. It is the
    ///     difference between "Photos says this photo has no keywords", which must
    ///     overwrite the stale `dc:subject` a library original carries, and "we do
    ///     not know", which must leave the file's own metadata alone. Passing an
    ///     empty set is a real instruction; passing nil is an absence of one.
    ///   - seedIndex: where to start the search, typically the rung earlier photos
    ///     needed. Only a starting point — a wrong seed costs a probe, never a
    ///     wrong answer.
    public static func run(
        source: URL,
        destination: URL,
        traits: AssetTraits,
        text: AssetTextMetadata?,
        textIsAuthoritative: Bool,
        policy: GatePolicy,
        fixedQuality: Double?,
        search: QualitySearch,
        seedIndex: Int?
    ) -> Outcome {
        let keywords = textIsAuthoritative ? (text?.keywords ?? []) : nil

        var probes = 0
        var searched = false

        do {
            let result: TranscodeResult
            let score: QualityScore
            var rungIndex: Int?

            if let fixedQuality {
                result = try Transcoder(quality: fixedQuality)
                    .transcode(source: source, destination: destination, keywords: keywords)
                score = try QualityMetrics.compare(source, destination)
            } else {
                searched = true
                let found = try search.search(
                    source: source,
                    destination: destination,
                    keywords: keywords,
                    seedIndex: seedIndex
                )
                probes = found.probes

                guard let accepted = found.accepted else {
                    // Not even the top rung reached the target. The answer is the
                    // same skip it always was; the search only means we now know
                    // no quality would have worked.
                    return Outcome(
                        entry: LedgerEntry(
                            outcome: .skipped,
                            sourceLocalIdentifier: traits.localIdentifier,
                            originalFilename: traits.originalFilename,
                            skipReason: .qualityBelowThreshold,
                            quality: QualityLadder.rungs.last,
                            ssim: found.bestSSIM
                        ),
                        kind: .notConverted(.qualityBelowThreshold),
                        probes: probes,
                        searched: searched
                    )
                }
                result = accepted.result
                score = accepted.score
                rungIndex = accepted.rungIndex
            }

            let gate = EligibilityGate.evaluatePostConditions(
                source: result.sourceFacts,
                destination: result.destinationFacts,
                quality: score,
                policy: policy
            )

            if case .skip(let reason) = gate {
                // A rejected encode must not linger where `apply` might find it.
                try? FileManager.default.removeItem(at: destination)
                return Outcome(
                    entry: LedgerEntry(
                        outcome: .skipped,
                        sourceLocalIdentifier: traits.localIdentifier,
                        originalFilename: traits.originalFilename,
                        skipReason: reason,
                        sourceBytes: result.sourceBytes,
                        stagedBytes: result.destinationBytes,
                        quality: result.quality,
                        ssim: score.ssim,
                        psnr: score.psnr.isFinite ? score.psnr : nil
                    ),
                    kind: .notConverted(reason),
                    probes: probes,
                    searched: searched
                )
            }

            // Hashed here rather than by the caller: the exported original is
            // deleted the moment this returns, and doing it inside means the
            // hashing of one photo overlaps the encoding of the next.
            return Outcome(
                entry: LedgerEntry(
                    outcome: .transcoded,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    stagedPath: destination.path,
                    sourceSHA256: try? Digest.sha256(of: source),
                    stagedSHA256: try? Digest.sha256(of: destination),
                    sourceBytes: result.sourceBytes,
                    stagedBytes: result.destinationBytes,
                    quality: result.quality,
                    ssim: score.ssim,
                    psnr: score.psnr.isFinite ? score.psnr : nil,
                    sourceFacts: result.sourceFacts,
                    stagedFacts: result.destinationFacts,
                    sourceTextMetadata: text
                ),
                kind: .converted(Converted(result: result, score: score, rungIndex: rungIndex)),
                probes: probes,
                searched: searched
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            return Outcome(
                entry: LedgerEntry(
                    outcome: .failed,
                    sourceLocalIdentifier: traits.localIdentifier,
                    originalFilename: traits.originalFilename,
                    error: "\(error)"
                ),
                kind: .notConverted(.transcodeFailed),
                probes: probes,
                searched: searched
            )
        }
    }
}
