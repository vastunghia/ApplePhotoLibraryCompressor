import XCTest
@testable import APLCCore

/// `transcode` converts several photos at once but reports and journals them in
/// album order, which is what makes two runs of the same month comparable line
/// by line. This is the piece that holds an early finisher back, so it is where
/// an off-by-one would silently reorder the journal.
final class OrderedSinkTests: XCTestCase {
    func testInOrderArrivalsAreReleasedImmediately() {
        var sink = OrderedSink<String>()
        XCTAssertEqual(sink.insert("a", at: 0), ["a"])
        XCTAssertEqual(sink.insert("b", at: 1), ["b"])
        XCTAssertEqual(sink.insert("c", at: 2), ["c"])
        XCTAssertEqual(sink.heldCount, 0)
    }

    func testAnEarlyFinisherWaitsForTheOneBeforeIt() {
        var sink = OrderedSink<String>()
        XCTAssertEqual(sink.insert("b", at: 1), [], "1 cannot go out before 0")
        XCTAssertEqual(sink.heldCount, 1)
        XCTAssertEqual(sink.insert("a", at: 0), ["a", "b"], "0 releases itself and 1")
        XCTAssertEqual(sink.heldCount, 0)
    }

    func testOneSlowPhotoParksEveryLaterOneAndThenReleasesThemAllInOrder() {
        var sink = OrderedSink<Int>()
        for index in stride(from: 6, through: 1, by: -1) {
            XCTAssertEqual(sink.insert(index, at: index), [])
        }
        XCTAssertEqual(sink.heldCount, 6)
        XCTAssertEqual(sink.insert(0, at: 0), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(sink.nextIndex, 7)
    }

    func testReleasesOnlyTheUnbrokenRun() {
        var sink = OrderedSink<Int>()
        // 3 is missing, so 4 stays put even once 0..2 have gone out.
        _ = sink.insert(2, at: 2)
        _ = sink.insert(4, at: 4)
        _ = sink.insert(1, at: 1)
        XCTAssertEqual(sink.insert(0, at: 0), [0, 1, 2])
        XCTAssertEqual(sink.heldCount, 1)
        XCTAssertEqual(sink.nextIndex, 3)
        XCTAssertEqual(sink.insert(3, at: 3), [3, 4])
    }

    func testAnEmptySinkHasReleasedNothing() {
        let sink = OrderedSink<Int>()
        XCTAssertEqual(sink.nextIndex, 0)
        XCTAssertEqual(sink.heldCount, 0)
    }

    func testCanStartPartWayThrough() {
        var sink = OrderedSink<Int>(startingAt: 10)
        XCTAssertEqual(sink.insert(11, at: 11), [])
        XCTAssertEqual(sink.insert(10, at: 10), [10, 11])
    }
}
