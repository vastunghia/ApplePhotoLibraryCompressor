import XCTest
@testable import APLCCore

/// `RungSearch` decides where to spend the next encode. It touches no image, so
/// a whole search replays against a curve in microseconds — which is the point
/// of it being a separate type, and what makes it affordable to check that the
/// interpolation reaches the same answer as an exhaustive scan on every curve
/// here rather than on one or two.
final class RungSearchTests: XCTestCase {
    /// SSIM at each of the twenty rungs, for eight real photographs spanning the
    /// range from "already fine at the bottom rung" to "needs most of the
    /// ladder". Measured by encoding each one at every rung; no filenames, dates
    /// or sizes, because what matters here is only the shape of the curve.
    ///
    /// Real ones rather than generated: the whole premise of interpolating is
    /// that photographs behave a certain way, and a fixture that behaves that way
    /// by construction could not falsify it.
    static let realCurves: [[Double]] = [
        [0.9777, 0.9814, 0.9850, 0.9874, 0.9891, 0.9905, 0.9913, 0.9921, 0.9928, 0.9934,
         0.9941, 0.9945, 0.9947, 0.9949, 0.9951, 0.9953, 0.9954, 0.9955, 0.9956, 0.9956],
        [0.9279, 0.9320, 0.9363, 0.9409, 0.9458, 0.9507, 0.9556, 0.9604, 0.9651, 0.9695,
         0.9742, 0.9786, 0.9829, 0.9874, 0.9901, 0.9918, 0.9930, 0.9936, 0.9940, 0.9944],
        [0.8366, 0.8604, 0.8822, 0.9024, 0.9208, 0.9353, 0.9476, 0.9565, 0.9660, 0.9748,
         0.9812, 0.9853, 0.9884, 0.9911, 0.9924, 0.9928, 0.9932, 0.9942, 0.9952, 0.9959],
        [0.9444, 0.9452, 0.9462, 0.9476, 0.9495, 0.9520, 0.9549, 0.9580, 0.9614, 0.9649,
         0.9685, 0.9724, 0.9760, 0.9803, 0.9830, 0.9851, 0.9872, 0.9888, 0.9901, 0.9908],
        [0.9214, 0.9252, 0.9292, 0.9338, 0.9386, 0.9438, 0.9487, 0.9536, 0.9586, 0.9637,
         0.9690, 0.9739, 0.9781, 0.9817, 0.9843, 0.9862, 0.9878, 0.9892, 0.9902, 0.9910],
        [0.9246, 0.9310, 0.9373, 0.9435, 0.9494, 0.9548, 0.9597, 0.9644, 0.9688, 0.9732,
         0.9776, 0.9815, 0.9846, 0.9873, 0.9891, 0.9905, 0.9916, 0.9925, 0.9931, 0.9936],
        [0.9733, 0.9757, 0.9779, 0.9798, 0.9815, 0.9830, 0.9843, 0.9855, 0.9865, 0.9875,
         0.9884, 0.9893, 0.9901, 0.9908, 0.9915, 0.9922, 0.9927, 0.9932, 0.9937, 0.9941],
        [0.9580, 0.9632, 0.9680, 0.9723, 0.9762, 0.9796, 0.9826, 0.9851, 0.9875, 0.9896,
         0.9915, 0.9930, 0.9942, 0.9951, 0.9958, 0.9963, 0.9966, 0.9969, 0.9971, 0.9973],
    ]

    // MARK: - Replaying a search against a curve

    /// Runs a whole search over `curve`, returning what it decided and what it
    /// spent. Also asserts the search never asks for a rung twice or one off the
    /// ladder — both would be silent waste rather than a wrong answer.
    private func run(
        _ curve: [Double],
        target: Double,
        seed: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (answer: Int?, probes: Int, kept: Int?) {
        var search = RungSearch(ladderCount: curve.count, target: target, seed: seed)
        var asked: Set<Int> = []
        var kept: Int?

        for _ in 0...(curve.count + 2) {
            switch search.next() {
            case .finished(let answer):
                XCTAssertEqual(answer, kept, "the answer must be the file that was kept",
                               file: file, line: line)
                return (answer, search.probeCount, kept)
            case .probe(let rung):
                XCTAssertTrue((0..<curve.count).contains(rung),
                              "probed rung \(rung) off a \(curve.count)-rung ladder",
                              file: file, line: line)
                XCTAssertTrue(asked.insert(rung).inserted,
                              "probed rung \(rung) twice, wasting an encode",
                              file: file, line: line)
                if search.record(rung: rung, ssim: curve[rung]) { kept = rung }
            }
        }
        XCTFail("search did not terminate", file: file, line: line)
        return (nil, search.probeCount, kept)
    }

    /// The answer by exhaustive scan: the cheapest rung that reaches the target.
    private func truth(_ curve: [Double], target: Double) -> Int? {
        curve.firstIndex { $0 >= target }
    }

    // MARK: - Real photographs

    func testFindsTheSameRungAsAnExhaustiveScanOnEveryRealCurve() {
        // Every seed, not just a plausible one: the seed is timing-dependent
        // under `--jobs`, so a curve that only works from a lucky start would be
        // a bug that appears at random.
        for (index, curve) in Self.realCurves.enumerated() {
            for target in [0.95, 0.97, 0.98, 0.99] {
                let expected = truth(curve, target: target)
                for seed in 0..<curve.count {
                    let got = run(curve, target: target, seed: seed)
                    XCTAssertEqual(got.answer, expected,
                                   "curve \(index), target \(target), seed \(seed)")
                }
            }
        }
    }

    func testTheRealCurvesAreMonotone() {
        // The premise the interpolation rests on. If a future ladder change
        // breaks it, the search still cannot return an encode below the target —
        // it can only lose a rung of saving — but this is where it would show.
        for (index, curve) in Self.realCurves.enumerated() {
            for rung in 1..<curve.count {
                XCTAssertGreaterThanOrEqual(curve[rung], curve[rung - 1],
                                            "curve \(index) dips at rung \(rung)")
            }
        }
    }

    func testCostsFewerEncodesThanBisectingWouldOnRealPhotographs() {
        // The whole reason for the change. An encode is the one thing the tool
        // cannot do in parallel, so this number is the critical path.
        var total = 0
        var runs = 0
        for curve in Self.realCurves {
            for seed in 0..<curve.count {
                total += run(curve, target: 0.97, seed: seed).probes
                runs += 1
            }
        }
        let average = Double(total) / Double(runs)
        // Bisecting the same set averages about 4.9. Measured for this search:
        // ~3.0. The bar is set loosely so ordinary drift does not fail the build,
        // but a regression to bisection-like cost would.
        XCTAssertLessThan(average, 3.6, "averaged \(average) encodes per photo")
    }

    // MARK: - The edges the eight curves do not reach

    func testARungZeroAnswerCostsASingleEncodeWhenSeededThere() {
        let curve = (0..<20).map { 0.98 + Double($0) * 0.0005 }
        let got = run(curve, target: 0.97, seed: 0)
        XCTAssertEqual(got.answer, 0)
        XCTAssertEqual(got.probes, 1, "nothing lies below rung 0, so nothing needs disproving")
    }

    func testAnAnswerAtTheTopOfTheLadderIsFound() {
        var curve = (0..<20).map { 0.90 + Double($0) * 0.003 }
        curve[19] = 0.9705
        let got = run(curve, target: 0.97, seed: 0)
        XCTAssertEqual(got.answer, 19)
    }

    func testATargetNoRungReachesReturnsNoAnswer() {
        let curve = (0..<20).map { 0.90 + Double($0) * 0.001 }
        let got = run(curve, target: 0.99, seed: 9)
        XCTAssertNil(got.answer)
        XCTAssertNil(got.kept, "nothing may be kept when nothing passed")
        XCTAssertGreaterThan(got.probes, 0)
    }

    func testATargetEveryRungReachesReturnsTheBottom() {
        let curve = (0..<20).map { 0.99 + Double($0) * 0.0001 }
        for seed in [0, 9, 19] {
            XCTAssertEqual(run(curve, target: 0.5, seed: seed).answer, 0)
        }
    }

    func testASingleRungLadder() {
        XCTAssertEqual(run([0.98], target: 0.97, seed: 0).answer, 0)
        XCTAssertNil(run([0.96], target: 0.97, seed: 0).answer)
    }

    func testASeedOutsideTheLadderIsClamped() {
        let curve = Self.realCurves[1]
        XCTAssertEqual(run(curve, target: 0.97, seed: 999).answer, truth(curve, target: 0.97))
        XCTAssertEqual(run(curve, target: 0.97, seed: -5).answer, truth(curve, target: 0.97))
    }

    /// A flat stretch makes the secant useless — dividing by it would fling the
    /// estimate to an end of the ladder. The prior has to take over.
    func testAFlatCurveStillTerminatesAndIsCorrect() {
        var curve = [Double](repeating: 0.9600, count: 20)
        for rung in 14..<20 { curve[rung] = 0.9750 }
        let got = run(curve, target: 0.97, seed: 0)
        XCTAssertEqual(got.answer, 14)
    }

    /// Monotonicity is an assumption, not a guarantee. A dip must not cost an
    /// answer below the bar: whatever comes back has been measured against it.
    func testANonMonotoneCurveStillReturnsARungThatMeetsTheTarget() {
        var curve = (0..<20).map { 0.94 + Double($0) * 0.004 }
        curve[11] = 0.9650   // a dip below the target, above a rung that passed
        for seed in 0..<20 {
            let got = run(curve, target: 0.97, seed: seed)
            if let answer = got.answer {
                XCTAssertGreaterThanOrEqual(curve[answer], 0.97,
                                            "seed \(seed) accepted rung \(answer), below the bar")
            }
        }
    }

    // MARK: - The rule that keeps the right file

    func testOnlyACheaperPassingRungClaimsTheFile() {
        // The probes no longer arrive in descending order, so this is what stops
        // a later, more expensive encode from overwriting the one that will be
        // recorded in the journal.
        var search = RungSearch(ladderCount: 20, target: 0.97, seed: 10)
        XCTAssertTrue(search.record(rung: 10, ssim: 0.985), "first pass takes the file")
        XCTAssertTrue(search.record(rung: 6, ssim: 0.972), "cheaper pass takes it")
        XCTAssertFalse(search.record(rung: 8, ssim: 0.980), "dearer pass must not")
        XCTAssertFalse(search.record(rung: 4, ssim: 0.960), "a failure must not")
    }

    func testBestSSIMReportsTheHighestSeen() {
        var search = RungSearch(ladderCount: 20, target: 0.99, seed: 0)
        search.record(rung: 0, ssim: 0.94)
        search.record(rung: 19, ssim: 0.9812)
        search.record(rung: 9, ssim: 0.9700)
        XCTAssertEqual(search.bestSSIM, 0.9812, accuracy: 1e-12)
    }
}
