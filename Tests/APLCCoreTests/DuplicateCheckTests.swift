import XCTest
@testable import APLCCore

final class DuplicateCheckTests: XCTestCase {
    private let noon = Date(timeIntervalSinceReferenceDate: 600_000_000)
    private let copy = LibraryCopy(localIdentifier: "EXISTING/L0/001",
                                   pixelWidth: 3168, pixelHeight: 4752)

    private func verdict(width: Int = 3168, height: Int = 4752,
                         sha: String? = "abc", bytesEqual: Bool?) -> DuplicateVerdict {
        DuplicateCheck.verdict(stagedWidth: width, stagedHeight: height,
                               stagedSHA256: sha, existing: copy, bytesEqual: bytesEqual)
    }

    // MARK: - The index

    func testCopiesAreGroupedByPairIdentity() {
        let a = TwinKey(filename: "IMG_1.heic", creationDate: noon)!
        let b = TwinKey(filename: "IMG_2.heic", creationDate: noon)!
        let index = DuplicateCheck.index([
            (a, LibraryCopy(localIdentifier: "1", pixelWidth: 10, pixelHeight: 10)),
            (a, LibraryCopy(localIdentifier: "2", pixelWidth: 10, pixelHeight: 10)),
            (b, LibraryCopy(localIdentifier: "3", pixelWidth: 10, pixelHeight: 10)),
        ])
        XCTAssertEqual(index[a]?.count, 2)
        XCTAssertEqual(index[b]?.count, 1)
    }

    /// The JPEG in the ledger and the HEIC in the library differ by extension,
    /// which is exactly what `TwinKey` is supposed to ignore — otherwise the
    /// check would never fire at all.
    func testAStagedJPEGNameMatchesTheHEICCopyItProduced() {
        let staged = TwinKey(filename: "5D3_7177.jpg", creationDate: noon)
        let inLibrary = TwinKey(filename: "5D3_7177.heic", creationDate: noon)
        XCTAssertEqual(staged, inLibrary)
    }

    // MARK: - The verdict ladder

    /// Geometry is checked first because it is free, and because two images of
    /// different size cannot be the same file however the bytes compare.
    func testDifferentDimensionsDifferWithoutConsultingTheBytes() {
        let result = verdict(width: 1536, height: 2304, bytesEqual: true)
        guard case .differs(let existing, let reason) = result else {
            return XCTFail("expected .differs, got \(result)")
        }
        XCTAssertEqual(existing, copy)
        XCTAssertTrue(reason.contains("1536x2304"))
        XCTAssertTrue(reason.contains("3168x4752"))
    }

    func testMatchingBytesAreIdentical() {
        XCTAssertEqual(verdict(bytesEqual: true), .identical(copy))
    }

    func testSameSizeDifferentBytesDiffer() {
        guard case .differs(_, let reason) = verdict(bytesEqual: false) else {
            return XCTFail("expected .differs")
        }
        XCTAssertEqual(reason, "same dimensions, different content")
    }

    /// An existing copy that could not be read — iCloud-only, and this check
    /// never spends the download budget — must not be reported as a match.
    func testAnUncomparableCopyIsUnknownRatherThanIdentical() {
        guard case .unknown = verdict(bytesEqual: nil) else {
            return XCTFail("expected .unknown")
        }
    }

    func testAStagedFileWithoutADigestIsUnknown() {
        guard case .unknown = verdict(sha: nil, bytesEqual: true) else {
            return XCTFail("expected .unknown")
        }
    }

    // MARK: - What to do about it

    func testNoCollisionImports() {
        XCTAssertEqual(DuplicateCheck.resolution(for: .none), .importIt)
    }

    /// There is nothing to decide about an identical copy, and a prompt for each
    /// one would be noise on a long run.
    func testAnIdenticalCopyIsSkippedWithoutAsking() {
        let resolution = DuplicateCheck.resolution(for: .identical(copy))
        guard case .skip(let reason, _, let collided) = resolution else {
            return XCTFail("expected .skip, got \(resolution)")
        }
        XCTAssertEqual(reason, .duplicateInLibrary)
        XCTAssertEqual(collided, copy.localIdentifier)
    }

    func testADifferingCopyIsPutToTheUser() {
        let resolution = DuplicateCheck.resolution(for: .differs(copy, reason: "why"))
        guard case .ask(let existing, let question) = resolution else {
            return XCTFail("expected .ask, got \(resolution)")
        }
        XCTAssertEqual(existing, copy)
        XCTAssertTrue(question.contains("why"))
    }

    /// Uncomparable is a question too. Refusing on a comparison that never
    /// happened would silently drop a conversion the user asked for.
    func testAnUncomparableCopyIsPutToTheUser() {
        guard case .ask = DuplicateCheck.resolution(for: .unknown(copy, reason: "offline")) else {
            return XCTFail("expected .ask")
        }
    }

    /// The two skip reasons answer different questions: the ledger's is about
    /// this staging directory, the library's is about every run there has been.
    func testTheDuplicateReasonIsDistinctFromAlreadyApplied() {
        XCTAssertNotEqual(SkipReason.duplicateInLibrary, SkipReason.alreadyApplied)
        XCTAssertFalse(SkipReason.duplicateInLibrary.explanation.isEmpty)
    }
}
