import XCTest
@testable import APLCCore

final class RepairPlanTests: XCTestCase {

    private func applied(source: String, copy: String) -> LedgerEntry {
        LedgerEntry(
            outcome: .applied,
            sourceLocalIdentifier: source,
            originalFilename: "IMG_1.jpg",
            createdAssetLocalIdentifier: copy
        )
    }

    private func pair(
        _ source: String, _ copy: String, folder: String = "2023-08",
        sourceExists: Bool = true, sourceIsShared: Bool? = true
    ) -> RepairPlan.Pair {
        RepairPlan.Pair(source: source, copy: copy, folder: folder,
                        sourceExists: sourceExists, sourceIsShared: sourceIsShared)
    }

    // MARK: - Reading the journal

    func testConversionsPairsEachOriginalWithItsCopy() {
        let entries = [
            applied(source: "A/L0/001", copy: "A2/L0/001"),
            applied(source: "B/L0/001", copy: "B2/L0/001"),
        ]
        XCTAssertEqual(RepairPlan.conversions(in: entries), [
            RepairPlan.Conversion(source: "A/L0/001", copy: "A2/L0/001"),
            RepairPlan.Conversion(source: "B/L0/001", copy: "B2/L0/001"),
        ])
    }

    /// The one that matters most. `apply` records a second `applied` entry per
    /// asset it transferred keywords, title or caption to, and that entry names
    /// the *new* asset in both identifier fields. Taken at face value it says a
    /// copy is its own original — and the original is what gets filed into
    /// "Compressed Originals", the album the user deletes from. So a copy could
    /// be offered for deletion because it once carried a keyword.
    func testConversionsDropTheTextMetadataEntriesThatNameTheCopyAsItsOwnOriginal() {
        let entries = [
            applied(source: "A/L0/001", copy: "A2/L0/001"),
            // What transferTextMetadata appends.
            LedgerEntry(
                outcome: .applied,
                sourceLocalIdentifier: "A2/L0/001",
                originalFilename: "IMG_1.jpg",
                sourceTextMetadata: AssetTextMetadata(keywords: ["holiday"]),
                appliedTextMetadata: AssetTextMetadata(keywords: ["holiday"]),
                createdAssetLocalIdentifier: "A2/L0/001"
            ),
        ]

        let conversions = RepairPlan.conversions(in: entries)
        XCTAssertEqual(conversions, [RepairPlan.Conversion(source: "A/L0/001", copy: "A2/L0/001")])
        XCTAssertFalse(conversions.contains { $0.source == $0.copy },
                       "a copy must never be treated as an original to delete")
    }

    func testConversionsKeepOneEntryPerCreatedAsset() {
        let entries = [
            applied(source: "A/L0/001", copy: "A2/L0/001"),
            applied(source: "A/L0/001", copy: "A2/L0/001"),
        ]
        XCTAssertEqual(RepairPlan.conversions(in: entries).count, 1)
    }

    func testConversionsIgnoreEverythingThatIsNotAnAppliedEntryWithACopy() {
        let entries = [
            LedgerEntry(outcome: .transcoded, sourceLocalIdentifier: "A/L0/001",
                        originalFilename: "IMG_1.jpg", stagedPath: "/tmp/a.heic"),
            LedgerEntry(outcome: .skipped, sourceLocalIdentifier: "B/L0/001",
                        originalFilename: "IMG_2.jpg", skipReason: .notAJPEG),
            LedgerEntry(outcome: .failed, sourceLocalIdentifier: "C/L0/001",
                        originalFilename: "IMG_3.jpg", error: "boom"),
            // An `applied` entry with no created identifier says nothing usable.
            LedgerEntry(outcome: .applied, sourceLocalIdentifier: "D/L0/001",
                        originalFilename: "IMG_4.jpg"),
        ]
        XCTAssertTrue(RepairPlan.conversions(in: entries).isEmpty)
    }

    // MARK: - Grouping into months

    func testMonthsGroupByFolderInOrder() {
        let months = RepairPlan.months([
            pair("B", "B2", folder: "2023-09"),
            pair("A", "A2", folder: "2023-08"),
        ])
        XCTAssertEqual(months.map(\.folder), ["2023-08", "2023-09"])
        XCTAssertEqual(months[0].copies, ["A2"])
        XCTAssertEqual(months[1].copies, ["B2"])
    }

    func testMonthsKeepOnlyTheRequestedFolders() {
        let months = RepairPlan.months([
            pair("A", "A2", folder: "2023-08"),
            pair("B", "B2", folder: "2023-09"),
        ], limitedTo: ["2023-08"])
        XCTAssertEqual(months.map(\.folder), ["2023-08"])
    }

    /// The finished state of a month: the copies are there, the JPEGs have been
    /// deleted. The copies album is still rebuildable; there is simply no
    /// original left to gather for deletion, and that is not a problem.
    func testAnOriginalThatHasBeenDeletedStillYieldsItsCopy() {
        let months = RepairPlan.months([pair("A", "A2", sourceExists: false, sourceIsShared: nil)])
        XCTAssertEqual(months[0].copies, ["A2"])
        XCTAssertTrue(months[0].originals.isEmpty)
    }

    func testACopyWhoseOriginalWasSharedGoesInTheReshareList() {
        let months = RepairPlan.months([
            pair("A", "A2", sourceIsShared: true),
            pair("B", "B2", sourceIsShared: false),
        ])
        XCTAssertEqual(months[0].sharedCopies, ["A2"])
        XCTAssertTrue(months[0].unknownScopeCopies.isEmpty)
    }

    /// Unknown means out, and named. Publishing a personal photo to the other
    /// participants of a shared library is the one mistake here that reaches
    /// beyond the user's own library, so silence has to mean no.
    func testACopyWhoseScopeCannotBeReadIsLeftOutAndReported() {
        let months = RepairPlan.months([pair("A", "A2", sourceIsShared: nil)])
        XCTAssertTrue(months[0].sharedCopies.isEmpty)
        XCTAssertEqual(months[0].unknownScopeCopies, ["A2"])
    }

    /// Some JPEGs were converted twice, before the duplicate check existed. Both
    /// copies are real and both belong in the copies album; the one original
    /// behind them is one photo, and offering it twice would be a miscount in
    /// the album that invites deletion.
    func testOneOriginalConvertedTwiceIsGatheredOnce() {
        let months = RepairPlan.months([
            pair("A", "A2"),
            pair("A", "A3"),
        ])
        XCTAssertEqual(months[0].copies, ["A2", "A3"])
        XCTAssertEqual(months[0].originals, ["A"])
    }
}
