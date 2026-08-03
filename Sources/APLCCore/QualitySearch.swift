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
/// It assumes SSIM rises with quality, which is what makes bisection valid.
/// That assumption is not load-bearing for safety: the rung finally returned has
/// always been measured against the target itself, so a non-monotonic patch can
/// only cost a rung of saving — never yield an encode below the bar.
public struct QualitySearch {
    public let ladder: [Double]
    public let targetSSIM: Double

    public init(targetSSIM: Double, ladder: [Double] = QualityLadder.rungs) {
        precondition(!ladder.isEmpty, "the ladder needs at least one rung")
        self.targetSSIM = targetSSIM
        self.ladder = ladder
    }

    /// - Parameters:
    ///   - seedIndex: where to start, typically the rung chosen for earlier
    ///     assets in the same album. Photographs from one album resemble each
    ///     other, so a good seed usually turns the search into a two-probe
    ///     confirmation. It is only a starting point: a wrong seed costs a probe
    ///     or two, never a wrong answer.
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

        var low = 0
        var high = ladder.count - 1
        var accepted: QualitySearchOutcome.Accepted?
        var bestSSIM = 0.0
        var probes = 0

        /// Encodes at one rung and reports whether it met the target, keeping
        /// the file when it did. Walking downwards means a later acceptance is
        /// always the cheaper one, so it simply replaces the previous.
        func probe(_ index: Int) throws -> Bool {
            let result = try Transcoder(quality: ladder[index])
                .transcode(source: source, destination: probeURL, keywords: keywords)
            let score = try QualityMetrics.compare(source, probeURL)
            probes += 1
            bestSSIM = max(bestSSIM, score.ssim)

            guard score.ssim >= targetSSIM else {
                try? FileManager.default.removeItem(at: probeURL)
                return false
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
            return true
        }

        // With a seed, widen outwards from it — one rung, then two, four, eight —
        // until the answer is bracketed, and only bisect what is left. Bisecting
        // the whole range instead would throw the seed away: knowing the answer
        // is *near* index 10 is worth nothing to a search that starts at the
        // midpoint regardless. Neighbouring photographs usually agree within a
        // rung or two, which this resolves in two or three encodes.
        if let seedIndex {
            let seed = min(max(seedIndex, low), high)
            if try probe(seed) {
                high = seed - 1
                var step = 1
                while high >= low {
                    let index = max(low, seed - step)
                    if try probe(index) {
                        high = index - 1
                        if index == low { break }
                        step *= 2
                    } else {
                        low = index + 1
                        break
                    }
                }
            } else {
                low = seed + 1
                var step = 1
                while low <= high {
                    let index = min(high, seed + step)
                    if try probe(index) {
                        high = index - 1
                        break
                    }
                    low = index + 1
                    if index == high { break }
                    step *= 2
                }
            }
        }

        while low <= high {
            let index = (low + high) / 2
            if try probe(index) {
                high = index - 1
            } else {
                low = index + 1
            }
        }

        if accepted == nil {
            try? FileManager.default.removeItem(at: destination)
        }
        return QualitySearchOutcome(accepted: accepted, bestSSIM: bestSSIM, probes: probes)
    }
}
