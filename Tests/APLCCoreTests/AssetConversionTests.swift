import XCTest
@testable import APLCCore

/// `AssetConversion` is the half of `transcode` that several photos are in at
/// once. These tests exercise it on files, with no photo library involved, which
/// is the whole reason it takes a URL rather than a `PHAsset`.
final class AssetConversionTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    /// See `QualitySearchTests`: the synthetic fixture is far easier to encode
    /// than a photograph and scores 0.988 at the bottom rung, so the production
    /// default of 0.97 would make every search stop at once and assert nothing.
    private let midLadderTarget = 0.9905

    private func traits(_ name: String) -> AssetTraits {
        AssetTraits(
            localIdentifier: "\(name)/L0/001",
            originalFilename: "\(name).JPG",
            uniformTypeIdentifier: "public.jpeg"
        )
    }

    private func convert(
        _ name: String,
        source: URL,
        destination: URL,
        policy: GatePolicy = GatePolicy(minSSIM: 0.0),
        fixedQuality: Double? = 0.71,
        targetSSIM: Double? = nil,
        text: AssetTextMetadata? = nil,
        textIsAuthoritative: Bool = true,
        seedIndex: Int? = nil
    ) -> AssetConversion.Outcome {
        AssetConversion.run(
            source: source,
            destination: destination,
            traits: traits(name),
            text: text,
            textIsAuthoritative: textIsAuthoritative,
            policy: policy,
            fixedQuality: fixedQuality,
            search: QualitySearch(targetSSIM: targetSSIM ?? midLadderTarget),
            seedIndex: seedIndex
        )
    }

    // MARK: - One photo

    func testAConvertedPhotoProducesAJournalLineReadyToAppend() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")
        let text = AssetTextMetadata(keywords: ["holiday"], title: "A title", caption: nil)

        let outcome = convert("IMG_0001", source: jpeg, destination: heic, text: text)

        guard case .converted(let result) = outcome.kind else {
            return XCTFail("expected a conversion, got \(outcome.kind)")
        }
        XCTAssertEqual(outcome.entry.outcome, .transcoded)
        XCTAssertEqual(outcome.entry.sourceLocalIdentifier, "IMG_0001/L0/001")
        XCTAssertEqual(outcome.entry.originalFilename, "IMG_0001.JPG")
        XCTAssertEqual(outcome.entry.stagedPath, heic.path)
        XCTAssertEqual(outcome.entry.sourceTextMetadata, text)
        XCTAssertEqual(outcome.entry.quality, 0.71)
        XCTAssertEqual(outcome.entry.ssim, result.score.ssim)
        XCTAssertNil(result.rungIndex, "a fixed --quality means no search ran")
        XCTAssertEqual(outcome.probes, 0)
        XCTAssertFalse(outcome.searched)

        // Both hashes are taken here rather than by the caller, because the
        // exported original is deleted the moment this returns.
        XCTAssertEqual(outcome.entry.sourceSHA256, try Digest.sha256(of: jpeg))
        XCTAssertEqual(outcome.entry.stagedSHA256, try Digest.sha256(of: heic))
        XCTAssertTrue(FileManager.default.fileExists(atPath: heic.path))
    }

    func testTheSearchReportsWhichRungItSettledOnSoTheNextPhotoCanStartThere() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        let outcome = convert("IMG_0002", source: jpeg, destination: heic, fixedQuality: nil)

        guard case .converted(let result) = outcome.kind else {
            return XCTFail("expected a conversion, got \(outcome.kind)")
        }
        let rung = try XCTUnwrap(result.rungIndex)
        XCTAssertEqual(QualityLadder.rungs[rung], result.result.quality)
        XCTAssertGreaterThanOrEqual(result.score.ssim, midLadderTarget)
        XCTAssertTrue(outcome.searched)
        XCTAssertGreaterThan(outcome.probes, 0)
    }

    // MARK: - The refusals

    func testARejectedEncodeIsRemovedSoApplyCannotFindIt() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        // No HEIC can be 1% of its JPEG, so the size rule refuses this one.
        let outcome = convert("IMG_0003", source: jpeg, destination: heic,
                              policy: GatePolicy(minSSIM: 0.0, maxSizeRatio: 0.01))

        XCTAssertEqual(outcome.entry.outcome, .skipped)
        XCTAssertEqual(outcome.entry.skipReason, .insufficientSaving)
        guard case .notConverted(let reason) = outcome.kind else {
            return XCTFail("expected a skip, got \(outcome.kind)")
        }
        XCTAssertEqual(reason, .insufficientSaving)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path),
                       "a rejected encode must not be left where `apply` could stage it")
        // Recorded even though it was thrown away: the numbers are why it went.
        XCTAssertNotNil(outcome.entry.stagedBytes)
        XCTAssertNotNil(outcome.entry.ssim)
    }

    func testATargetNoRungReachesIsSkippedWithHowFarShortItFell() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 480, height: 360)
        let heic = temp.file("out.heic")

        let outcome = convert("IMG_0004", source: jpeg, destination: heic,
                              fixedQuality: nil, targetSSIM: 0.99999)

        XCTAssertEqual(outcome.entry.skipReason, .qualityBelowThreshold)
        XCTAssertEqual(outcome.entry.quality, QualityLadder.rungs.last)
        // The best score seen, not merely "too low" — the difference between a
        // line you can act on and one you cannot.
        let best = try XCTUnwrap(outcome.entry.ssim)
        XCTAssertGreaterThan(best, 0.9)
        XCTAssertLessThan(best, 0.99999)
        XCTAssertTrue(outcome.searched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path))
    }

    func testAThrowingEncodeBecomesAFailedLineRatherThanTakingTheRunDown() throws {
        let missing = temp.file("does-not-exist.jpg")
        let heic = temp.file("out.heic")

        let outcome = convert("IMG_0005", source: missing, destination: heic)

        XCTAssertEqual(outcome.entry.outcome, .failed)
        XCTAssertNotNil(outcome.entry.error)
        guard case .notConverted(let reason) = outcome.kind else {
            return XCTFail("expected a skip tally, got \(outcome.kind)")
        }
        // The entry says `.failed` with the message; the summary tallies it as a
        // transcode failure. The two say different things on purpose.
        XCTAssertEqual(reason, .transcodeFailed)
        XCTAssertNil(outcome.entry.skipReason)
    }

    // MARK: - The property the parallel run rests on

    func testConvertingManyAtOnceGivesExactlyWhatConvertingThemInTurnGives() async throws {
        // Different sizes so the photos are genuinely different work, and so a
        // result accidentally shared between two of them would show up.
        let sizes = [(480, 360), (400, 300), (360, 480), (320, 240), (440, 330), (300, 400)]
        let sources = try sizes.enumerated().map { index, size in
            try TestImages.writeJPEG(at: temp.file("in-\(index).jpg"),
                                     width: size.0, height: size.1)
        }

        // A fixed seed on both runs. In the real command the seed evolves as
        // photos finish, which is timing-dependent by design; what has to hold
        // here is that the conversion itself carries nothing between photos.
        func outcomes(intoSuffix suffix: String) -> [Int: AssetConversion.Outcome] {
            var byIndex: [Int: AssetConversion.Outcome] = [:]
            for (index, source) in sources.enumerated() {
                byIndex[index] = convert(
                    "IMG_\(index)",
                    source: source,
                    destination: temp.file("out-\(suffix)-\(index).heic"),
                    fixedQuality: nil,
                    seedIndex: 10
                )
            }
            return byIndex
        }

        let sequential = outcomes(intoSuffix: "seq")

        // Everything the workers need is prepared here, as values. That is the
        // shape the command uses too: the tasks share nothing.
        let search = QualitySearch(targetSSIM: midLadderTarget)
        let policy = GatePolicy(minSSIM: 0.0)
        let jobs = sources.enumerated().map { index, source in
            (index: index,
             source: source,
             destination: temp.file("out-par-\(index).heic"),
             traits: traits("IMG_\(index)"))
        }

        // Through `BlockingWork`, exactly as the command does. Encoding straight
        // from the task group's own threads deadlocks instead of failing — the
        // encoder blocks inside VideoToolbox and the cooperative pool will not
        // grow past it. This test hung for ten minutes before that was found.
        var concurrent: [Int: AssetConversion.Outcome] = [:]
        await withTaskGroup(of: (Int, AssetConversion.Outcome).self) { group in
            for job in jobs {
                group.addTask {
                    let outcome = await BlockingWork.run {
                        AssetConversion.run(
                            source: job.source,
                            destination: job.destination,
                            traits: job.traits,
                            text: nil,
                            textIsAuthoritative: true,
                            policy: policy,
                            fixedQuality: nil,
                            search: search,
                            seedIndex: 10
                        )
                    }
                    return (job.index, outcome)
                }
            }
            for await (index, outcome) in group { concurrent[index] = outcome }
        }

        XCTAssertEqual(concurrent.count, sources.count)
        for index in sources.indices {
            let a = try XCTUnwrap(sequential[index])
            let b = try XCTUnwrap(concurrent[index])

            XCTAssertEqual(a.entry.outcome, b.entry.outcome, "photo \(index)")
            XCTAssertEqual(a.entry.originalFilename, b.entry.originalFilename, "photo \(index)")
            XCTAssertEqual(a.entry.quality, b.entry.quality, "photo \(index) chose a different rung")
            XCTAssertEqual(a.entry.ssim, b.entry.ssim, "photo \(index) scored differently")
            XCTAssertEqual(a.entry.sourceBytes, b.entry.sourceBytes, "photo \(index)")
            XCTAssertEqual(a.entry.stagedBytes, b.entry.stagedBytes, "photo \(index)")
            XCTAssertEqual(a.probes, b.probes, "photo \(index) took a different number of encodes")
            // The bytes themselves, not merely their size: this is what says the
            // encoder produced the same file with six of them running at once.
            XCTAssertEqual(a.entry.stagedSHA256, b.entry.stagedSHA256,
                           "photo \(index) encoded to different bytes in parallel")
        }
    }
}
