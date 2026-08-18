import XCTest
@testable import APLCCore

/// The ordering rule behind `PhotoLibraryAccess.assets(withIdentifiers:)`.
///
/// It is tested through the pure half because the fetch itself needs a photo
/// library and the user's consent, while the property that broke an album is
/// entirely in the reordering: a fetch by local identifier answers in the
/// library's own order, and an album shows its photos in the order they arrived.
final class PhotoLibraryAccessTests: XCTestCase {
    private struct Item: Equatable {
        let identifier: String
    }

    private func ordered(_ fetched: [String], like asked: [String]) -> [String] {
        PhotoLibraryAccess.ordered(
            fetched.map(Item.init), like: asked, by: \.identifier
        ).map(\.identifier)
    }

    func testResultFollowsTheOrderAskedForRatherThanTheFetch() {
        XCTAssertEqual(
            ordered(["c", "a", "b"], like: ["a", "b", "c"]),
            ["a", "b", "c"]
        )
    }

    func testIdentifiersTheFetchDidNotAnswerDropOut() {
        XCTAssertEqual(ordered(["c", "a"], like: ["a", "b", "c"]), ["a", "c"])
    }

    func testARepeatedIdentifierYieldsItsItemOnce() {
        XCTAssertEqual(ordered(["a", "b"], like: ["b", "a", "b"]), ["b", "a"])
    }

    func testNothingAskedForIsNothingReturned() {
        XCTAssertEqual(ordered(["a", "b"], like: []), [])
        XCTAssertEqual(ordered([], like: ["a", "b"]), [])
    }
}
