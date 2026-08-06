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

    // MARK: - A journal that outlives the staging directory

    /// One truncated line from a hard stop used to make the whole file
    /// undecodable. That was survivable when the journal lived in a staging
    /// directory you could delete; it is not, now that it is the permanent
    /// record of what was done to the library.
    func testACorruptLineIsSkippedAndCountedRatherThanFatal() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)
        try ledger.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "A/L0/001",
                                      originalFilename: "IMG_1.JPG"))

        // A line cut off mid-write, exactly as a crash would leave it.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"outcome\":\"transc\n".utf8))
        try handle.close()

        let after = try Ledger(url: url)
        try after.append(LedgerEntry(outcome: .applied,
                                     sourceLocalIdentifier: "B/L0/001",
                                     originalFilename: "IMG_2.JPG"))

        let read = try Ledger.read(at: url)
        XCTAssertEqual(read.unreadableLines, 1)
        XCTAssertEqual(read.entries.count, 2)
        XCTAssertEqual(read.entries.map(\.sourceLocalIdentifier), ["A/L0/001", "B/L0/001"])
    }

    func testAHealthyJournalReportsNoDamage() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)
        try ledger.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "A/L0/001",
                                      originalFilename: "IMG_1.JPG"))
        XCTAssertEqual(try Ledger.read(at: url).unreadableLines, 0)
    }

    /// Two `aplc` processes can now hold the one journal open at once. With a
    /// remembered offset the second writer would overwrite the first's lines;
    /// O_APPEND is what stops that.
    func testInterleavedWritersDoNotOverwriteEachOther() throws {
        let url = temp.file("ledger.jsonl")
        let first = try Ledger(url: url)
        let second = try Ledger(url: url)

        try first.append(LedgerEntry(outcome: .transcoded,
                                     sourceLocalIdentifier: "A/L0/001",
                                     originalFilename: "A.JPG"))
        try second.append(LedgerEntry(outcome: .transcoded,
                                      sourceLocalIdentifier: "B/L0/001",
                                      originalFilename: "B.JPG"))
        try first.append(LedgerEntry(outcome: .applied,
                                     sourceLocalIdentifier: "C/L0/001",
                                     originalFilename: "C.JPG"))

        let entries = try Ledger.readAll(at: url)
        XCTAssertEqual(entries.map(\.originalFilename), ["A.JPG", "B.JPG", "C.JPG"])
    }

    // MARK: - Scoping a global journal to one run

    func testEntriesAreScopedToTheirStagingRoot() {
        let mine = URL(fileURLWithPath: "/tmp/aplc-1")
        let entries = [
            staged(at: "/tmp/aplc-1/heic/a.heic"),
            staged(at: "/tmp/aplc-2/heic/b.heic"),
            staged(at: nil),
        ]
        let scoped = Ledger.entries(entries, stagedUnder: mine)
        XCTAssertEqual(scoped.map(\.originalFilename), ["a.heic"])
    }

    /// Without the trailing separator, "/tmp/aplc-1" would claim everything
    /// staged under "/tmp/aplc-10" as its own.
    func testAStagingRootDoesNotClaimASiblingWithTheSamePrefix() {
        let entries = [staged(at: "/tmp/aplc-10/heic/a.heic")]
        XCTAssertTrue(Ledger.entries(entries, stagedUnder: URL(fileURLWithPath: "/tmp/aplc-1")).isEmpty)
        XCTAssertEqual(
            Ledger.entries(entries, stagedUnder: URL(fileURLWithPath: "/tmp/aplc-10")).count, 1)
    }

    /// The point of the journal outliving staging: what has been imported is
    /// remembered even though the directory that staged it is long gone.
    func testAppliedIdentifiersSurviveAStagingRootThatNoLongerExists() throws {
        let url = temp.file("ledger.jsonl")
        let ledger = try Ledger(url: url)
        try ledger.append(LedgerEntry(outcome: .applied,
                                      sourceLocalIdentifier: "A/L0/001",
                                      originalFilename: "A.JPG",
                                      stagedPath: "/var/folders/gone/heic/a.heic"))

        let read = try Ledger.read(at: url)
        XCTAssertEqual(Ledger.appliedIdentifiers(in: read.entries), ["A/L0/001"])
        XCTAssertTrue(Ledger.entries(read.entries,
                                     stagedUnder: URL(fileURLWithPath: "/var/folders/new")).isEmpty)
    }

    func testTheStandardJournalSitsInApplicationSupport() throws {
        let url = try LedgerLocation.standard()
        XCTAssertEqual(url.lastPathComponent, "aplc_ledger.jsonl")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "aplc")
        XCTAssertTrue(url.path.contains("Application Support"), url.path)
    }

    private func staged(at path: String?) -> LedgerEntry {
        LedgerEntry(outcome: .transcoded,
                    sourceLocalIdentifier: path ?? "none",
                    originalFilename: path.map { ($0 as NSString).lastPathComponent } ?? "none",
                    stagedPath: path)
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
