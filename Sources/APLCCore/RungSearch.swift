import Foundation

/// Decides which rung to encode next, and nothing else.
///
/// Split out of `QualitySearch` so the decision can be tested against curves
/// rather than against the encoder: it holds no image, opens no file and does no
/// work, so a whole search replays in microseconds.
///
/// Being clever here is worth it because an encode is the most expensive thing
/// this tool does *and* the one thing it cannot do in parallel — see
/// `TECHNICAL.md`. Every probe saved comes straight off the critical path.
///
/// ## Why interpolation rather than bisection
///
/// A probe measures an SSIM. Bisection reduces that number to a single bit —
/// "did it reach the target?" — and discards the rest, which is wasteful,
/// because SSIM rises smoothly and monotonically with quality: the *value* says
/// how far off the rung was, not merely which side of the target it fell.
///
/// Measured on eight photographs across the whole ladder: every curve was
/// monotone, and in `log(1 - SSIM)` — distortion, which decays roughly
/// exponentially — each was nearly a straight line, r² between 0.90 and 0.999.
/// So one probe supports an extrapolation and two support a secant. Simulated
/// over the rung distribution of a real library that is 2.9 probes per photo
/// against 4.0 for the bisecting version, reaching the same answers.
///
/// This is a per-photo interpolation and not a model of anything: nothing is
/// learned and nothing is carried between photos. The one global constant is
/// used only for the first jump, and only ever decides *where to look*.
public struct RungSearch {
    public enum Step: Equatable {
        /// Encode this rung, then hand the score to `record`.
        case probe(Int)
        /// The boundary has been measured. `answer` is the cheapest rung that
        /// reached the target, or nil when none of them did.
        case finished(answer: Int?)
    }

    /// Average slope of `log(1 - SSIM)` per rung, measured across eight
    /// photographs spanning the range of difficulty (individually −0.079 to
    /// −0.206). Negative because distortion falls as quality rises.
    ///
    /// Used only for the very first jump, where one probe gives a point but no
    /// slope. Being wrong costs a probe, never an answer, and from the second
    /// probe on the secant replaces it with this photograph's own slope.
    static let priorSlope = -0.1306

    /// A secant flatter than this is not believable as a local slope — two
    /// probes on the saturated top of the curve, or a non-monotone patch. Using
    /// it would divide by nearly zero and fling the estimate to an end of the
    /// ladder, so the prior is used instead.
    static let minimumUsableSlope = -0.02

    public let target: Double
    private let count: Int
    private let seed: Int

    /// Rungs that could still be the answer. Everything below `lo` has been
    /// measured and failed; `hi` is the cheapest rung measured that passed, or
    /// the top of the ladder while nothing has passed yet.
    private var lo: Int
    private var hi: Int
    private var measured: [Int: Double] = [:]
    private var best: Int?

    /// - Parameter seed: where to spend the first probe. Clamped to the ladder.
    ///   Only a starting point — a poor one costs a probe, and the interpolation
    ///   corrects for it immediately, which is why this search cares far less
    ///   about the seed than the bisecting one did.
    public init(ladderCount: Int, target: Double, seed: Int = 0) {
        precondition(ladderCount > 0, "the ladder needs at least one rung")
        self.count = ladderCount
        self.target = target
        self.seed = min(max(seed, 0), ladderCount - 1)
        lo = 0
        hi = ladderCount - 1
    }

    public var probeCount: Int { measured.count }

    /// The highest SSIM seen, so a failure can report how far short it fell
    /// rather than merely that it did.
    public var bestSSIM: Double { measured.values.max() ?? 0 }

    /// What to do next.
    public mutating func next() -> Step {
        // Finished when the bracket has closed onto a rung that was measured and
        // passed. That is the same stopping condition the bisecting version had,
        // and it is what keeps the answer a measurement rather than an estimate:
        // rung `lo` passed, and either it is the bottom of the ladder or `lo - 1`
        // was measured and failed.
        if lo >= hi {
            if let ssim = measured[lo], ssim >= target { return .finished(answer: lo) }
            // The bracket can close onto a rung nobody has probed yet: every rung
            // below the top has failed, so the top is the only candidate left and
            // has still to be tried.
            if lo < count, measured[lo] == nil { return .probe(lo) }
            return .finished(answer: best)
        }
        if measured.isEmpty { return .probe(min(max(seed, lo), hi)) }
        return .probe(estimate())
    }

    /// Reports the score of the rung `next()` asked for.
    ///
    /// - Returns: true when this rung is the cheapest passing one so far, which
    ///   is the caller's signal to keep the file it just wrote. **The probes no
    ///   longer arrive in descending order**, so "the last one that passed" is no
    ///   longer the same thing as "the cheapest one that passed" — that is
    ///   exactly the mistake this return value exists to prevent.
    @discardableResult
    public mutating func record(rung: Int, ssim: Double) -> Bool {
        measured[rung] = ssim
        guard ssim >= target else {
            lo = max(lo, rung + 1)
            return false
        }
        hi = min(hi, rung)
        guard best == nil || rung < best! else { return false }
        best = rung
        return true
    }

    // MARK: - The estimate

    /// Distortion, the space in which the curve is nearly straight.
    static func distortion(_ ssim: Double) -> Double {
        log(max(1 - ssim, 1e-9))
    }

    /// Where the curve looks like it crosses the target, kept inside the
    /// unresolved bracket and off rungs already measured.
    private func estimate() -> Int {
        // The two probes nearest the target carry the most information about the
        // slope where it matters. A secant drawn across distant ones would be
        // dragged flat by the saturated top of the curve.
        let nearest = measured.sorted { abs($0.value - target) < abs($1.value - target) }
        let anchor = nearest[0]

        var slope = Self.priorSlope
        if nearest.count >= 2, nearest[1].key != anchor.key {
            let rise = Self.distortion(nearest[1].value) - Self.distortion(anchor.value)
            let secant = rise / Double(nearest[1].key - anchor.key)
            if secant < Self.minimumUsableSlope { slope = secant }
        }

        let steps = (Self.distortion(target) - Self.distortion(anchor.value)) / slope
        var guess = min(max(anchor.key + Int(steps.rounded()), lo), hi)

        if measured[guess] != nil {
            // Never spend an encode on a rung already known. The nearest
            // unmeasured rung inside the bracket is the next best use of it.
            let free = (lo...hi).filter { measured[$0] == nil }
            if let closest = free.min(by: { abs($0 - guess) < abs($1 - guess) }) {
                guess = closest
            }
        }
        return guess
    }
}
