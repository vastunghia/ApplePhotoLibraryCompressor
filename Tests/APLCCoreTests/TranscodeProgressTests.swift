import XCTest
@testable import APLCCore

final class TranscodeProgressTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    // MARK: - The counter

    func testTheCounterCountsEveryPhotoAndPadsToTheWidestNumber() {
        var progress = TranscodeProgress(total: 198, encodable: 198)
        progress.advance(costAnEncode: true, at: at(0))
        XCTAssertTrue(progress.prefix().hasPrefix("[   1/198"), progress.prefix())
    }

    /// The exact string, since it is the thing the user actually reads and every
    /// other test here checks only a fragment of it.
    func testTheWholePrefixReadsAsIntended() {
        var progress = TranscodeProgress(total: 198, encodable: 198)
        var clock = 0.0
        for _ in 0..<123 {
            progress.advance(costAnEncode: true, at: at(clock))
            clock += 5
        }
        XCTAssertEqual(progress.prefix(), "[ 123/198  62%  ~6m left ]")
    }

    /// The month goes on every line because the header that names it scrolls out
    /// of the window on a long month, leaving the lines on screen saying nothing
    /// about where they belong.
    func testTheMonthGoesInFrontOfTheCounter() {
        var progress = TranscodeProgress(total: 198, encodable: 198)
        var clock = 0.0
        for _ in 0..<123 {
            progress.advance(costAnEncode: true, at: at(clock))
            clock += 5
        }
        XCTAssertEqual(progress.prefix(label: "July 2019"),
                       "[ July 2019  123/198  62%  ~6m left ]")
    }

    /// In `--album` mode there is one album and the user named it himself, so
    /// repeating it on every line would say nothing.
    func testAnEmptyLabelLeavesNoGap() {
        var progress = TranscodeProgress(total: 4, encodable: 4)
        progress.advance(costAnEncode: false, at: at(0))
        XCTAssertEqual(progress.prefix(label: ""), "[ 1/4  25% ]")
    }

    func testAPhotoTheGateRefusedStillAdvancesTheCounter() {
        var progress = TranscodeProgress(total: 3, encodable: 1)
        progress.advance(costAnEncode: false, at: at(0))
        progress.advance(costAnEncode: false, at: at(1))
        XCTAssertTrue(progress.prefix().contains("2/3"), progress.prefix())
    }

    func testThePercentageReachesAHundredOnTheLastPhoto() {
        var progress = TranscodeProgress(total: 4, encodable: 4)
        for i in 0..<4 { progress.advance(costAnEncode: true, at: at(Double(i))) }
        XCTAssertTrue(progress.prefix().contains("100%"), progress.prefix())
    }

    /// `transcode` can be handed an album where every photo is already done.
    func testAnEmptyRunDoesNotProduceAPrefix() {
        let progress = TranscodeProgress(total: 0, encodable: 0)
        XCTAssertEqual(progress.prefix(), "")
    }

    // MARK: - The estimate

    func testThereIsNoEstimateUntilTwoPhotosHaveBeenEncoded() {
        var progress = TranscodeProgress(total: 10, encodable: 10)
        XCTAssertNil(progress.secondsPerPhoto)
        progress.advance(costAnEncode: true, at: at(0))
        XCTAssertNil(progress.secondsPerPhoto)
        XCTAssertFalse(progress.prefix().contains("left"), progress.prefix())

        progress.advance(costAnEncode: true, at: at(5))
        XCTAssertEqual(progress.secondsPerPhoto ?? 0, 5, accuracy: 0.001)
    }

    /// Five seconds a photo with eight left is forty seconds, and the prefix has
    /// to say so.
    func testTheEstimateIsTheRateTimesWhatIsLeftToEncode() {
        var progress = TranscodeProgress(total: 10, encodable: 10)
        progress.advance(costAnEncode: true, at: at(0))
        progress.advance(costAnEncode: true, at: at(5))
        XCTAssertEqual(progress.remaining ?? 0, 40, accuracy: 0.001)
        XCTAssertTrue(progress.prefix().contains("~40s left"), progress.prefix())
    }

    /// Photos the gate refused cost no measurable time, so counting them as work
    /// would make the estimate optimistic in exactly the months full of them.
    func testRefusedPhotosAreNotPartOfWhatIsLeftToEncode() {
        var progress = TranscodeProgress(total: 10, encodable: 4)
        progress.advance(costAnEncode: true, at: at(0))
        progress.advance(costAnEncode: true, at: at(5))
        // Two encodes done of four, so two left: ten seconds, not forty.
        XCTAssertEqual(progress.remaining ?? 0, 10, accuracy: 0.001)
    }

    func testThereIsNoEstimateOnceEverythingHasBeenEncoded() {
        var progress = TranscodeProgress(total: 2, encodable: 2)
        progress.advance(costAnEncode: true, at: at(0))
        progress.advance(costAnEncode: true, at: at(5))
        XCTAssertNil(progress.remaining)
        XCTAssertFalse(progress.prefix().contains("left"), progress.prefix())
    }

    /// The trap this type exists to avoid. Results are recorded in album order,
    /// so a slow photo parks the ones behind it and several land in the same
    /// instant. Timing the gaps between consecutive samples would read that as
    /// "three photos in no time"; the span of the window cannot be fooled.
    func testABurstOfSimultaneousRecordingsDoesNotCollapseTheEstimate() {
        var progress = TranscodeProgress(total: 100, encodable: 100)
        // Four photos, one every fifteen seconds of real work, but released in
        // bursts of three at t=0, 45, 90 as the slow ones finally arrive.
        for time in [0.0, 0.0, 0.0, 45.0, 45.0, 45.0, 90.0, 90.0, 90.0] {
            progress.advance(costAnEncode: true, at: at(time))
        }
        // Nine photos across ninety seconds is 11.25 s each, not zero.
        XCTAssertEqual(progress.secondsPerPhoto ?? 0, 90.0 / 8.0, accuracy: 0.001)
    }

    /// A month that changes camera half way through must not take another hour
    /// to notice: the window forgets the early photos.
    func testTheRateFollowsTheRecentPhotosRatherThanTheWholeRun() {
        var progress = TranscodeProgress(total: 100, encodable: 100, windowSize: 3)
        // Ten fast photos, then three slow ones.
        var clock = 0.0
        for _ in 0..<10 {
            progress.advance(costAnEncode: true, at: at(clock))
            clock += 1
        }
        for _ in 0..<3 {
            progress.advance(costAnEncode: true, at: at(clock))
            clock += 20
        }
        // The window holds only the last three, twenty seconds apart.
        XCTAssertEqual(progress.secondsPerPhoto ?? 0, 20, accuracy: 0.001)
    }

    // MARK: - Durations

    func testDurationsAreCoarseOnPurpose() {
        XCTAssertEqual(TranscodeProgress.duration(0), "0s")
        XCTAssertEqual(TranscodeProgress.duration(45), "45s")
        XCTAssertEqual(TranscodeProgress.duration(59.4), "59s")
        // Crossing the minute reads as a minute rather than as "60s".
        XCTAssertEqual(TranscodeProgress.duration(59.6), "1m")
        XCTAssertEqual(TranscodeProgress.duration(90), "2m")
        XCTAssertEqual(TranscodeProgress.duration(540), "9m")
        XCTAssertEqual(TranscodeProgress.duration(3600), "1h")
        XCTAssertEqual(TranscodeProgress.duration(9240), "2h 34m")
    }

    func testANonsenseDurationDoesNotProduceNonsenseOutput() {
        XCTAssertEqual(TranscodeProgress.duration(-1), "0s")
        XCTAssertEqual(TranscodeProgress.duration(.infinity), "0s")
        XCTAssertEqual(TranscodeProgress.duration(.nan), "0s")
    }
}
