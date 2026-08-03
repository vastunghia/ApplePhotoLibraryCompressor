import CryptoKit
import XCTest
@testable import APLCCore

final class QualitySearchTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// A target that lands in the middle of the ladder *for the test fixture*.
    ///
    /// Not 0.97: the synthetic image is far easier to encode than a photograph
    /// and already scores 0.988 at the bottom rung, so the production default
    /// would make every search terminate immediately and quietly assert nothing.
    /// Measured range across the ladder is 0.9876 to 0.9943; this sits inside it.
    private let midLadderTarget = 0.9905

    // MARK: - The ladder

    func testEveryRungProducesADistinctEncoding() throws {
        // The premise of the whole search: these values are not aliases of each
        // other. If ImageIO's quantisation ever changes, this is what says so —
        // a ladder with duplicate rungs would waste probes on identical files.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)

        var digests: [String: Double] = [:]
        for rung in QualityLadder.rungs {
            let out = temp.file("q\(Int(rung * 100)).heic")
            _ = try Transcoder(quality: rung).transcode(source: jpeg, destination: out)
            let digest = try sha256(out)
            if let clash = digests[digest] {
                XCTFail("rungs \(clash) and \(rung) encode identically")
            }
            digests[digest] = rung
        }
        XCTAssertEqual(digests.count, QualityLadder.rungs.count)
    }

    func testRungsAreAscending() {
        XCTAssertEqual(QualityLadder.rungs, QualityLadder.rungs.sorted())
    }

    func testQualityBetweenRungsRoundsDown() {
        // 0.85 is the documented case: it encodes exactly as 0.79 does, which is
        // why `transcode` reports the rung rather than the value it was given.
        XCTAssertEqual(QualityLadder.rung(containing: 0.85), 0.79)
        XCTAssertEqual(QualityLadder.rung(containing: 0.70), 0.65)
        XCTAssertEqual(QualityLadder.rung(containing: 0.79), 0.79)
        // Below the ladder there is nothing to round down to, so it clamps.
        XCTAssertEqual(QualityLadder.rung(containing: 0.10), QualityLadder.rungs[0])
    }

    // MARK: - The search

    func testFindsTheLowestRungMeetingTheTarget() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 640, height: 480)
        let heic = temp.file("out.heic")
        let target = midLadderTarget

        let found = try QualitySearch(targetSSIM: target)
            .search(source: jpeg, destination: heic)

        let accepted = try XCTUnwrap(found.accepted)
        XCTAssertGreaterThanOrEqual(accepted.score.ssim, target)
        XCTAssertGreaterThan(accepted.rungIndex, 0, "target too low to test anything")

        // The rung below it must genuinely fall short, or the search settled too
        // high and is giving away saving.
        let lower = temp.file("lower.heic")
        _ = try Transcoder(quality: QualityLadder.rungs[accepted.rungIndex - 1])
            .transcode(source: jpeg, destination: lower)
        let lowerScore = try QualityMetrics.compare(jpeg, lower)
        XCTAssertLessThan(lowerScore.ssim, target)
    }

    func testSeedDoesNotChangeTheAnswer() throws {
        // The seed is an optimisation. It may cost or save probes; it must never
        // move the result, including when it points at the wrong end entirely.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let search = QualitySearch(targetSSIM: midLadderTarget)

        let unseeded = try search.search(source: jpeg, destination: temp.file("a.heic"))
        let expected = try XCTUnwrap(unseeded.accepted).rungIndex

        for seed in [0, expected, QualityLadder.rungs.count - 1] {
            let found = try search.search(
                source: jpeg, destination: temp.file("s\(seed).heic"), seedIndex: seed
            )
            XCTAssertEqual(try XCTUnwrap(found.accepted).rungIndex, expected,
                           "seed \(seed) changed the chosen rung")
        }
    }

    func testAnAccurateSeedCostsTwoProbes() throws {
        // The point of seeding: once an album has settled, confirming the rung
        // takes one probe at it and one below, not a full bisection.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let search = QualitySearch(targetSSIM: midLadderTarget)

        let unseeded = try search.search(source: jpeg, destination: temp.file("a.heic"))
        let answer = try XCTUnwrap(unseeded.accepted).rungIndex
        XCTAssertGreaterThan(answer, 0, "target too low to test anything")

        let seeded = try search.search(
            source: jpeg, destination: temp.file("b.heic"), seedIndex: answer
        )
        XCTAssertEqual(seeded.probes, 2)
        XCTAssertLessThan(seeded.probes, unseeded.probes)
    }

    func testUnreachableTargetAcceptsNothingAndLeavesNoFile() throws {
        // Nothing reaches SSIM 1.0 through a lossy encoder. The contract is that
        // the caller gets no file to apply — a near miss must not be left behind
        // where `apply` could pick it up.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        let found = try QualitySearch(targetSSIM: 1.0)
            .search(source: jpeg, destination: heic)

        XCTAssertNil(found.accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
        // Reported anyway, so the skip can say how far short it fell.
        XCTAssertGreaterThan(found.bestSSIM, 0.9)
    }

    func testProbesAreBoundedByTheLadder() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let found = try QualitySearch(targetSSIM: 1.0)
            .search(source: jpeg, destination: temp.file("out.heic"))

        // Bisection over 20 rungs: 5 probes, plus at most one for the seed
        // detour. A linear scan would be 20 and would show up here.
        XCTAssertLessThanOrEqual(found.probes, 6)
    }

    func testKeptFileIsTheOneThatWasMeasured() throws {
        // The safety property. SSIM is recorded in the ledger and re-checked by
        // `verify`, so the staged file must be the exact encode that scored it —
        // not a re-run at the same quality that happens to look similar.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        let found = try QualitySearch(targetSSIM: 0.97)
            .search(source: jpeg, destination: heic, keywords: ["holiday"])
        let accepted = try XCTUnwrap(found.accepted)

        XCTAssertEqual(accepted.result.destination, heic)
        XCTAssertEqual(accepted.result.destinationFacts.byteCount,
                       try Data(contentsOf: heic).count)
        let rescored = try QualityMetrics.compare(jpeg, heic)
        XCTAssertEqual(rescored.ssim, accepted.score.ssim, accuracy: 1e-12)
        // Keywords reach the kept file, not just the probes.
        XCTAssertEqual(accepted.result.destinationFacts.keywords, ["holiday"])
    }

    func testNoProbeFilesSurvive() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        _ = try QualitySearch(targetSSIM: 0.97).search(source: jpeg, destination: heic)

        let left = try FileManager.default.contentsOfDirectory(
            atPath: heic.deletingLastPathComponent().path
        )
        XCTAssertEqual(left.filter { $0.contains("probe") }, [])
    }

    func testALowerTargetNeverChoosesAHigherRung() throws {
        // Monotonicity of the search itself, which is what makes --min-ssim
        // behave the way a user would expect: asking for less cannot cost more.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)

        let strict = try QualitySearch(targetSSIM: 0.9930)
            .search(source: jpeg, destination: temp.file("strict.heic"))
        let lax = try QualitySearch(targetSSIM: 0.9890)
            .search(source: jpeg, destination: temp.file("lax.heic"))

        let strictRung = try XCTUnwrap(strict.accepted).rungIndex
        let laxRung = try XCTUnwrap(lax.accepted).rungIndex
        XCTAssertLessThan(laxRung, strictRung)
    }

    func testSSIMRisesWithQualityAcrossTheLadder() throws {
        // Bisection is only valid if this holds. It is not a guarantee the codec
        // makes, so it is asserted rather than assumed — on this fixture the
        // ladder spans 0.9876 to 0.9943 without a single reversal. A real
        // photograph could still misbehave locally, which is why the search
        // re-measures the rung it returns instead of trusting the ordering.
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)

        var previous = 0.0
        for (i, rung) in QualityLadder.rungs.enumerated() {
            let out = temp.file("m\(i).heic")
            _ = try Transcoder(quality: rung).transcode(source: jpeg, destination: out)
            let ssim = try QualityMetrics.compare(jpeg, out).ssim
            XCTAssertGreaterThan(ssim, previous, "SSIM fell going from rung \(i - 1) to \(i)")
            previous = ssim
        }
    }
}
