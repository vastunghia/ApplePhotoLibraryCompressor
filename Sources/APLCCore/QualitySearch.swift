import Foundation

/// The quality values ImageIO's HEIC encoder actually distinguishes.
///
/// `kCGImageDestinationLossyCompressionQuality` is not continuous: it is
/// quantised, and most values are aliases for the same output. Measured on
/// macOS 15.7.7 by encoding one image at every hundredth from 0.40 to 1.00 and
/// hashing the results — 61 values collapse to 26 distinct files. Two images of
/// different size, aspect and content produced *identical* boundaries, so these
/// are a property of the encoder rather than of the picture.
///
/// The practical consequence is that a bisection over a continuous range spends
/// most of its probes on values that cannot differ. Searching over these rungs
/// instead makes every probe count.
public enum QualityLadder {
    /// Ascending, one entry per distinct encoder output.
    ///
    /// The low end starts at 0.40 rather than 0.0 because nothing below it has
    /// ever passed the SSIM gate on a real photograph. The top stops at 0.94
    /// because the size curve turns vicious above 0.86 — on the measured image,
    /// 0.79 gives 20 KB, 0.90 gives 34 KB and 0.95 gives 70 KB — so higher rungs
    /// produce HEICs that `maxSizeRatio` rejects anyway. Values between the rungs
    /// are legal input to `Transcoder`; they simply round down to one of these.
    public static let rungs: [Double] = [
        0.40, 0.41, 0.45, 0.49, 0.53, 0.55, 0.57, 0.61, 0.65, 0.71,
        0.76, 0.79, 0.86, 0.88, 0.89, 0.90, 0.91, 0.92, 0.93, 0.94,
    ]

    /// The rung an explicit `--quality` value actually encodes at.
    public static func rung(containing quality: Double) -> Double {
        rungs.last { $0 <= quality } ?? rungs[0]
    }

    /// Index of the rung nearest `quality`, for seeding a search.
    public static func index(nearest quality: Double) -> Int {
        var best = 0
        for (i, rung) in rungs.enumerated()
        where abs(rung - quality) < abs(rungs[best] - quality) {
            best = i
        }
        return best
    }
}

public struct QualitySearchOutcome: Sendable {
    /// The encode that was kept, or `nil` when no rung reached the target.
    public struct Accepted: Sendable {
        public let result: TranscodeResult
        public let score: QualityScore
        public let rungIndex: Int
        public var quality: Double { result.quality }
    }

    public let accepted: Accepted?
    /// Highest SSIM seen across all probes, so a failure can be reported with
    /// how far short it fell rather than just "too low".
    public let bestSSIM: Double
    /// Encodes performed. Worth surfacing: this is what the search cost.
    public let probes: Int
}

/// Finds the cheapest HEIC quality that still meets a target SSIM.
///
/// The search inverts the usual arrangement. Normally a quality is chosen up
/// front and SSIM is a veto applied afterwards, which throws away the work when
/// it fails; here SSIM is the objective and quality is merely the means, so the
/// result is the smallest file that satisfies the caller's fidelity bar.
///
/// This type is the loop that encodes and measures; `RungSearch` decides where
/// to look next, and holds the reasoning about why.
///
/// It assumes SSIM rises with quality, which is what lets a search over the
/// ladder mean anything at all. That assumption is not load-bearing for safety:
/// the rung finally returned has always been measured against the target itself,
/// so a non-monotonic patch can only cost a rung of saving — never yield an
/// encode below the bar.
///
/// `Sendable` because every photo in a `transcode` run shares one of these:
/// it is two immutable values and holds nothing that a search mutates.
public struct QualitySearch: Sendable {
    public let ladder: [Double]
    public let targetSSIM: Double

    public init(targetSSIM: Double, ladder: [Double] = QualityLadder.rungs) {
        precondition(!ladder.isEmpty, "the ladder needs at least one rung")
        self.targetSSIM = targetSSIM
        self.ladder = ladder
    }

    /// - Parameters:
    ///   - seedIndex: where to spend the first encode, typically the rung chosen
    ///     for earlier assets in the same album. Only a starting point: the
    ///     search reads the SSIM it gets back and corrects for a poor one
    ///     immediately, so a wrong seed costs at most a probe and never an
    ///     answer. Omitting it starts in the middle of the ladder.
    ///   - keywords: passed straight to `Transcoder`; see its documentation for
    ///     why `nil` and `[]` mean different things.
    ///
    /// On success `destination` holds exactly the encode that was measured — the
    /// accepted probe is moved into place rather than re-encoded, so the file
    /// applied to the library is the one the SSIM belongs to.
    public func search(
        source: URL,
        destination: URL,
        keywords: [String]? = nil,
        seedIndex: Int? = nil
    ) throws -> QualitySearchOutcome {
        let probeURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).probe")
        defer { try? FileManager.default.removeItem(at: probeURL) }

        // Without a seed, start in the middle. With nothing known about the
        // photograph that is the rung furthest from being badly wrong, and it is
        // where the bisecting version used to begin too.
        var search = RungSearch(
            ladderCount: ladder.count,
            target: targetSSIM,
            seed: seedIndex ?? ((ladder.count - 1) / 2)
        )
        var accepted: QualitySearchOutcome.Accepted?

        // `RungSearch` chooses where to look; this loop does the looking. The
        // split is what lets the choosing be tested against measured curves
        // instead of against the encoder.
        loop: while true {
            let index: Int
            switch search.next() {
            case .finished:
                break loop
            case .probe(let next):
                index = next
            }

            let result = try Transcoder(quality: ladder[index])
                .transcode(source: source, destination: probeURL, keywords: keywords)
            let score = try QualityMetrics.compare(source, probeURL)

            // The probes no longer arrive in descending order, so "this one
            // passed" is not the same as "this one is the cheapest that passed".
            // Keeping the wrong file here would put an image in the library whose
            // SSIM is not the one recorded beside it — `record` answers the
            // question so only one place has to get it right.
            guard search.record(rung: index, ssim: score.ssim) else {
                try? FileManager.default.removeItem(at: probeURL)
                continue
            }

            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: probeURL, to: destination)
            accepted = QualitySearchOutcome.Accepted(
                result: TranscodeResult(
                    source: result.source,
                    destination: destination,
                    sourceFacts: result.sourceFacts,
                    destinationFacts: result.destinationFacts,
                    quality: result.quality
                ),
                score: score,
                rungIndex: index
            )
        }

        if accepted == nil {
            try? FileManager.default.removeItem(at: destination)
        }
        return QualitySearchOutcome(
            accepted: accepted,
            bestSSIM: search.bestSSIM,
            probes: search.probeCount
        )
    }
}
