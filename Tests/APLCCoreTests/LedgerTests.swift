import XCTest
@testable import APLCCore

final class LedgerTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDown() { temp = nil }

    func testEntriesRoundTrip() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)

        try ledger.append(LedgerEntry(
            outcome: .transcoded,
            sourceLocalIdentifier: "A/L0/001",
            originalFilename: "IMG_1.JPG",
            stagedPath: "/tmp/a.heic",
            sourceBytes: 3_000_000,
            stagedBytes: 900_000,
            ssim: 0.991
        ))
        try ledger.append(LedgerEntry(
            outcome: .skipped,
            sourceLocalIdentifier: "B/L0/001",
            originalFilename: "IMG_2.HEIC",
            skipReason: .notAJPEG
        ))

        let entries = try Ledger.readAll(at: url)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].outcome, .transcoded)
        XCTAssertEqual(entries[0].ssim, 0.991)
        XCTAssertEqual(entries[1].skipReason, .notAJPEG)
    }

    func testAppendingIsAdditiveAcrossHandles() throws {
        let url = temp.file("ledger.jsonl")

        let first = try Ledger(url: url)
        try first.append(LedgerEntry(outcome: .transcoded,
                                     sourceLocalIdentifier: "A", originalFilename: "1.JPG"))

        // A second run must extend the journal, never truncate it.
        let second = try Ledger(url: url)
        try second.append(LedgerEntry(outcome: .applied,
                                      sourceLocalIdentifier: "A", originalFilename: "1.JPG",
                                      createdAssetLocalIdentifier: "NEW/L0/001"))

        XCTAssertEqual(try Ledger.readAll(at: url).count, 2)
    }

    func testAppliedIdentifiersDriveIdempotence() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)

        try ledger.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "A", originalFilename: "1.JPG"))
        try ledger.append(LedgerEntry(outcome: .applied,
                                      sourceLocalIdentifier: "A", originalFilename: "1.JPG",
                                      createdAssetLocalIdentifier: "NEW"))
        try ledger.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "B", originalFilename: "2.JPG"))

        let applied = try Ledger.appliedIdentifiers(at: url)
        XCTAssertEqual(applied, ["A"], "only applied assets count; B is still pending")
    }

    func testReadingAMissingLedgerYieldsNothing() throws {
        XCTAssertTrue(try Ledger.readAll(at: temp.file("absent.jsonl")).isEmpty)
    }

    func testImageFactsSurviveSerialisation() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)
        let facts = ImageFacts(
            width: 4032, height: 3024, byteCount: 3_000_000,
            typeIdentifier: "public.jpeg", hasGainMap: true,
            hasEXIF: true, hasGPS: true, hasTIFF: true,
            orientation: 6, profileName: "Display P3"
        )

        try ledger.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "A", originalFilename: "1.JPG",
                                      sourceFacts: facts))

        // verify relies on these coming back intact to re-run the gate.
        XCTAssertEqual(try Ledger.readAll(at: url).first?.sourceFacts, facts)
    }

    func testDigestMatchesKnownValue() throws {
        let file = temp.file("data.bin")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(
            try Digest.sha256(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testDigestHandlesFilesLargerThanOneChunk() throws {
        let file = temp.file("big.bin")
        try Data(repeating: 0x5A, count: (1 << 20) + 12345).write(to: file)
        let digest = try Digest.sha256(of: file)
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotEqual(digest, String(repeating: "0", count: 64))
    }
}
