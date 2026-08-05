import XCTest
@testable import APLCCore

final class MonthBoundsTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testARangeStartsOnTheFirstAndEndsBeforeTheNextFirst() throws {
        let range = try MonthBounds.range(year: 2019, month: 7, calendar: utc)
        XCTAssertEqual(utc.component(.day, from: range.lowerBound), 1)
        XCTAssertEqual(utc.component(.month, from: range.lowerBound), 7)
        XCTAssertEqual(utc.component(.day, from: range.upperBound), 1)
        XCTAssertEqual(utc.component(.month, from: range.upperBound), 8)
    }

    func testDecemberRollsIntoTheFollowingYear() throws {
        let range = try MonthBounds.range(year: 2019, month: 12, calendar: utc)
        XCTAssertEqual(utc.component(.year, from: range.upperBound), 2020)
        XCTAssertEqual(utc.component(.month, from: range.upperBound), 1)
    }

    /// A fixed 30- or 31-day offset would put four extra days into March.
    func testFebruaryLengthFollowsTheCalendar() throws {
        let leap = try MonthBounds.range(year: 2020, month: 2, calendar: utc)
        let common = try MonthBounds.range(year: 2019, month: 2, calendar: utc)
        let day: TimeInterval = 86_400
        XCTAssertEqual(leap.upperBound.timeIntervalSince(leap.lowerBound) / day, 29, accuracy: 0.01)
        XCTAssertEqual(common.upperBound.timeIntervalSince(common.lowerBound) / day, 28, accuracy: 0.01)
    }

    func testAMonthOutsideOneToTwelveIsRejected() {
        XCTAssertThrowsError(try MonthBounds.range(year: 2019, month: 0, calendar: utc))
        XCTAssertThrowsError(try MonthBounds.range(year: 2019, month: 13, calendar: utc))
    }

    func testLabelIsEnglishRegardlessOfLocale() {
        XCTAssertEqual(MonthBounds.label(year: 2019, month: 7), "July 2019")
    }
}

final class CandidateSelectionTests: XCTestCase {
    private let noon = Date(timeIntervalSinceReferenceDate: 600_000_000)

    private func jpeg(
        _ name: String,
        at date: Date? = nil,
        edited: Bool = false,
        live: Bool = false
    ) -> AssetTraits {
        AssetTraits(
            localIdentifier: "jpeg-\(name)",
            originalFilename: name,
            uniformTypeIdentifier: "public.jpeg",
            hasAdjustments: edited,
            isLivePhoto: live,
            creationDate: date ?? noon
        )
    }

    private func heic(_ name: String, at date: Date? = nil) -> AssetTraits {
        AssetTraits(
            localIdentifier: "heic-\(name)",
            originalFilename: name,
            uniformTypeIdentifier: "public.heic",
            creationDate: date ?? noon
        )
    }

    private func names(_ traits: [AssetTraits]) -> [String] {
        traits.map(\.originalFilename)
    }

    func testAJPEGWithNoCopyIsACandidate() {
        let selection = CandidateSelection.select(among: [jpeg("IMG_0001.JPG")])
        XCTAssertEqual(names(selection.candidates), ["IMG_0001.JPG"])
        XCTAssertEqual(selection.alreadyConverted, 0)
    }

    func testAJPEGWhoseCopyIsPresentIsReportedAsConverted() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG"),
            heic("IMG_0001.heic"),
        ])
        XCTAssertTrue(selection.candidates.isEmpty)
        XCTAssertEqual(selection.alreadyConverted, 1)
    }

    /// The stems come from different filesystems and different code paths, so
    /// the comparison cannot be case-sensitive.
    func testStemMatchingIgnoresCaseAndExtension() {
        let selection = CandidateSelection.select(among: [
            jpeg("DSC_1234.jpg"),
            heic("dsc_1234.HEIC"),
        ])
        XCTAssertEqual(selection.alreadyConverted, 1)
    }

    /// `IMG_0001` recurs across cameras and years; only the date separates them.
    func testTheSameStemAtADifferentTimeIsADifferentPhoto() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG"),
            heic("IMG_0001.heic", at: noon.addingTimeInterval(3600)),
        ])
        XCTAssertEqual(names(selection.candidates), ["IMG_0001.JPG"])
        XCTAssertEqual(selection.alreadyConverted, 0)
    }

    func testTheSameTimeWithADifferentStemIsADifferentPhoto() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG"),
            heic("IMG_0002.heic"),
        ])
        XCTAssertEqual(names(selection.candidates), ["IMG_0001.JPG"])
    }

    /// The date is copied verbatim by `Importer`, but the pairing must not
    /// depend on the last bits of a floating-point round trip.
    func testSubSecondDriftStillPairs() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG"),
            heic("IMG_0001.heic", at: noon.addingTimeInterval(0.0004)),
        ])
        XCTAssertEqual(selection.alreadyConverted, 1)
    }

    /// The 8,000 camera-native HEICs in a library must not make their JPEG
    /// neighbours look converted.
    func testACameraNativeHEICPairsWithNothing() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG"),
            heic("IMG_9999.heic"),
        ])
        XCTAssertEqual(names(selection.candidates), ["IMG_0001.JPG"])
        XCTAssertEqual(selection.heicPresent, 1)
        XCTAssertEqual(selection.alreadyConverted, 0)
    }

    func testTheGateStillExcludesWhatItAlwaysExcluded() {
        let selection = CandidateSelection.select(among: [
            jpeg("EDIT.JPG", edited: true),
            jpeg("LIVE.JPG", live: true),
            heic("NATIVE.heic"),
            jpeg("GOOD.JPG"),
        ])
        XCTAssertEqual(names(selection.candidates), ["GOOD.JPG"])
        XCTAssertEqual(selection.skips[.hasAdjustments], 1)
        XCTAssertEqual(selection.skips[.livePhotoOrBurst], 1)
        XCTAssertEqual(selection.skips[.notAJPEG], 1)
    }

    /// Being converted is reported as such even when the photo would also have
    /// been excluded for another reason — otherwise the count of remaining work
    /// would be wrong in a way the user cannot see.
    func testConversionIsReportedBeforeAnyOtherReason() {
        let selection = CandidateSelection.select(among: [
            jpeg("IMG_0001.JPG", edited: true),
            heic("IMG_0001.heic"),
        ])
        XCTAssertEqual(selection.alreadyConverted, 1)
        XCTAssertNil(selection.skips[.hasAdjustments])
    }

    /// Unpairable rather than assumed converted: offering a photo twice costs a
    /// wasted conversion, and skipping one silently loses it.
    func testAPhotoWithoutADateIsOfferedRatherThanGuessedAt() {
        var undated = jpeg("IMG_0001.JPG")
        undated.creationDate = nil
        let selection = CandidateSelection.select(among: [undated, heic("IMG_0001.heic")])
        XCTAssertEqual(names(selection.candidates), ["IMG_0001.JPG"])
    }

    func testCountsAddUp() {
        let selection = CandidateSelection.select(among: [
            jpeg("A.JPG"),
            jpeg("B.JPG"),
            heic("B.heic"),
            jpeg("C.JPG", edited: true),
            heic("NATIVE.heic"),
        ])
        let accounted = selection.candidates.count + selection.skips.values.reduce(0, +)
        XCTAssertEqual(accounted, selection.considered)
        XCTAssertEqual(selection.heicPresent, 2)
    }
}
