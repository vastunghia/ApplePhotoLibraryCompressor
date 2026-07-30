import XCTest
import UniformTypeIdentifiers
@testable import APLCCore

final class TranscoderTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws {
        temp = try TempDirectory()
    }

    override func tearDown() {
        temp = nil
    }

    func testSystemCanWriteHEIC() {
        // The whole tool rests on this. AVIF fails the same check, which is why
        // it is not an option on macOS.
        XCTAssertTrue(Transcoder.canWriteHEIC)
    }

    func testTranscodeProducesHEICOfIdenticalGeometry() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 800, height: 600)
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(source: jpeg, destination: heic)

        XCTAssertEqual(result.destinationFacts.typeIdentifier.map { UTType($0) }, .heic)
        XCTAssertEqual(result.destinationFacts.width, 800)
        XCTAssertEqual(result.destinationFacts.height, 600)
        XCTAssertEqual(result.sourceFacts.width, result.destinationFacts.width)
        XCTAssertEqual(result.sourceFacts.height, result.destinationFacts.height)
    }

    func testMetadataSurvivesTheRoundTrip() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), includeGPS: true)
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(source: jpeg, destination: heic)

        XCTAssertTrue(result.sourceFacts.hasEXIF, "test fixture should carry EXIF")
        XCTAssertTrue(result.sourceFacts.hasGPS, "test fixture should carry GPS")

        XCTAssertTrue(result.destinationFacts.hasEXIF, "EXIF was dropped by the encoder")
        XCTAssertTrue(result.destinationFacts.hasGPS, "GPS was dropped by the encoder")
        XCTAssertTrue(result.destinationFacts.hasTIFF, "TIFF block was dropped by the encoder")
        XCTAssertNotNil(result.destinationFacts.profileName, "colour profile was dropped")
    }

    func testOrientationIsPreserved() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), orientation: 6)
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(source: jpeg, destination: heic)
        XCTAssertEqual(result.sourceFacts.orientation, 6)
        XCTAssertEqual(result.destinationFacts.orientation, 6)
    }

    func testTranscodedFilePassesTheGate() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), width: 1200, height: 900)
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.75).transcode(source: jpeg, destination: heic)
        let score = try QualityMetrics.compare(jpeg, heic)

        let outcome = EligibilityGate.evaluatePostConditions(
            source: result.sourceFacts, destination: result.destinationFacts,
            quality: score, policy: .default
        )
        XCTAssertEqual(outcome, .eligible, "SSIM was \(score.ssim), ratio \(1 - result.savedFraction)")
    }

    func testExistingDestinationIsReplacedNotAppended() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"))
        let heic = temp.file("out.heic")
        try Data("stale contents from an interrupted run".utf8).write(to: heic)

        let result = try Transcoder(quality: 0.8).transcode(source: jpeg, destination: heic)
        XCTAssertEqual(result.destinationFacts.typeIdentifier.map { UTType($0) }, .heic)
    }

    // MARK: - Keywords

    func testKeywordsAreEmbedded() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"))
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(
            source: jpeg, destination: heic, keywords: ["P:Grazia", "L:Milano"]
        )
        XCTAssertEqual(Set(result.destinationFacts.keywords), ["P:Grazia", "L:Milano"])
    }

    /// The important one. Library originals carry stale XMP/IPTC keywords from
    /// old export cycles that disagree with what Photos actually holds. Passing
    /// the authoritative set — even an empty one — must overwrite them, or the
    /// converted copy would resurrect tags the user has since changed.
    func testAuthoritativeKeywordsReplaceStaleOnes() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), keywords: ["Milano", "Indoor"])
        let heic = temp.file("out.heic")

        let source = try ImageProbe.probe(jpeg)
        XCTAssertEqual(Set(source.keywords), ["Milano", "Indoor"], "fixture should carry stale keywords")

        let result = try Transcoder(quality: 0.8).transcode(
            source: jpeg, destination: heic, keywords: ["P:Giorgio", "L:Irnerio"]
        )
        XCTAssertEqual(Set(result.destinationFacts.keywords), ["P:Giorgio", "L:Irnerio"])
    }

    func testEmptyKeywordSetClearsStaleOnes() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), keywords: ["Milano", "Indoor"])
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(
            source: jpeg, destination: heic, keywords: []
        )
        XCTAssertTrue(result.destinationFacts.keywords.isEmpty,
                      "an empty set must clear the source's keywords, not be ignored")
    }

    /// nil means "Photos was unreachable" — guessing would be worse than
    /// leaving the file exactly as it came.
    func testNilKeywordsLeaveSourceMetadataAlone() throws {
        let jpeg = try TestImages.writeJPEG(at: temp.file("in.jpg"), keywords: ["Milano", "Indoor"])
        let heic = temp.file("out.heic")

        let result = try Transcoder(quality: 0.8).transcode(
            source: jpeg, destination: heic, keywords: nil
        )
        XCTAssertEqual(Set(result.destinationFacts.keywords), ["Milano", "Indoor"])
    }

    func testUnreadableSourceThrows() {
        let missing = temp.file("nope.jpg")
        XCTAssertThrowsError(
            try Transcoder(quality: 0.8).transcode(source: missing, destination: temp.file("o.heic"))
        )
    }

    func testFailedEncodeLeavesNoPartialFile() {
        // A directory can never be a valid image source, so the encode must fail.
        let heic = temp.file("out.heic")
        XCTAssertThrowsError(
            try Transcoder(quality: 0.8).transcode(source: temp.url, destination: heic)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: heic.path),
                       "a failed transcode must not leave a file behind")
    }
}
