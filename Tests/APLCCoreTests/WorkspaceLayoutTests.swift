import XCTest
@testable import APLCCore

final class WorkspaceLayoutTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    /// The order is the workflow's, not the alphabet's, and the alphabet would
    /// give a different one — which is the whole reason the insertion index
    /// exists. Pinned so a rename cannot quietly drop an album out of the order.
    func testAlbumOrderIsTheWorkflowOrderAndHoldsEveryWorkspaceAlbum() {
        XCTAssertEqual(WorkspaceLayout.albumOrder, [
            "Selected Originals",
            "Compressed Originals",
            "Compressed Copies",
            "Compressed Copies - to Share",
        ])
        XCTAssertNotEqual(WorkspaceLayout.albumOrder, WorkspaceLayout.albumOrder.sorted())
    }

    func testFirstAlbumInAnEmptyFolderGoesAtTheStart() {
        XCTAssertEqual(
            WorkspaceLayout.insertionIndex(for: WorkspaceLayout.originalsAlbum, among: []), 0
        )
    }

    /// The album `apply` creates second must land *above* the one `select` made
    /// first, which is the case appending gets wrong.
    func testAnAlbumIsPlacedAheadOfOnesThatComeAfterItInTheOrder() {
        let existing = [WorkspaceLayout.originalsAlbum, WorkspaceLayout.copiesAlbum]
        XCTAssertEqual(
            WorkspaceLayout.insertionIndex(for: WorkspaceLayout.convertedOriginalsAlbum,
                                           among: existing),
            1
        )
    }

    func testTheSharedCopiesAlbumGoesLastAmongTheWorkspaceAlbums() {
        let existing = [
            WorkspaceLayout.originalsAlbum,
            WorkspaceLayout.convertedOriginalsAlbum,
            WorkspaceLayout.copiesAlbum,
        ]
        XCTAssertEqual(
            WorkspaceLayout.insertionIndex(for: WorkspaceLayout.sharedCopiesAlbum, among: existing),
            3
        )
    }

    /// Built in the order the commands actually create them, the four end up in
    /// `albumOrder` — which is the property the whole mechanism is for.
    func testInsertingInCreationOrderReproducesTheIntendedOrder() {
        // `select` first, then `apply`: copies, then originals, then to-share.
        let creationOrder = [
            WorkspaceLayout.originalsAlbum,
            WorkspaceLayout.copiesAlbum,
            WorkspaceLayout.convertedOriginalsAlbum,
            WorkspaceLayout.sharedCopiesAlbum,
        ]
        var folder: [String] = []
        for title in creationOrder {
            folder.insert(title, at: WorkspaceLayout.insertionIndex(for: title, among: folder))
        }
        XCTAssertEqual(folder, WorkspaceLayout.albumOrder)
    }

    /// An album the user made himself is not ours to move. A workspace album
    /// goes above it; his keeps its place.
    func testAnAlbumTheUserMadeIsNotReordered() {
        let existing = [WorkspaceLayout.originalsAlbum, "Sergio's picks"]
        let index = WorkspaceLayout.insertionIndex(for: WorkspaceLayout.copiesAlbum,
                                                   among: existing)
        XCTAssertEqual(index, 1)

        var folder = existing
        folder.insert(WorkspaceLayout.copiesAlbum, at: index)
        XCTAssertEqual(folder.last, "Sergio's picks")
    }

    /// `ensureAlbum` returns early when the album is already there, so this never
    /// runs in practice — but if it ever did, it must not move the album.
    func testAnAlbumAlreadyPresentWouldBePlacedWhereItAlreadyIs() {
        let folder = WorkspaceLayout.albumOrder
        for (position, title) in folder.enumerated() {
            XCTAssertEqual(WorkspaceLayout.insertionIndex(for: title, among: folder), position)
        }
    }

    func testTheInsertionIndexIsAlwaysAValidInsertionPoint() {
        let candidates = WorkspaceLayout.albumOrder + ["Sergio's picks"]
        for title in candidates {
            for count in 0...candidates.count {
                let existing = Array(candidates.prefix(count))
                let index = WorkspaceLayout.insertionIndex(for: title, among: existing)
                XCTAssertTrue((0...existing.count).contains(index),
                              "\(index) is not an insertion point for \(existing)")
            }
        }
    }

    /// The padding is what makes a text sort of these names chronological rather
    /// than putting October before February. Whether Photos sorts month folders
    /// that way is a separate, unmeasured question — see `monthFolder`.
    func testMonthFolderIsZeroPaddedAndSortsChronologically() {
        XCTAssertEqual(WorkspaceLayout.monthFolder(MonthKey(year: 2026, month: 2)), "2026-02")
        XCTAssertEqual(WorkspaceLayout.monthFolder(MonthKey(year: 2026, month: 12)), "2026-12")

        let names = [2, 12, 1, 10].map { WorkspaceLayout.monthFolder(MonthKey(year: 2026, month: $0)) }
        XCTAssertEqual(names.sorted(), ["2026-01", "2026-02", "2026-10", "2026-12"])
    }

    func testMonthOfADateInTheMiddleOfAMonth() {
        XCTAssertEqual(WorkspaceLayout.month(of: date("2026-02-08 11:26:20"), calendar: utc),
                       MonthKey(year: 2026, month: 2))
    }

    /// The first and last instants of a month are exactly where an off-by-one
    /// would file a photo in the neighbouring folder.
    func testMonthOfTheEdgesOfAMonth() {
        XCTAssertEqual(WorkspaceLayout.month(of: date("2026-01-01 00:00:00"), calendar: utc),
                       MonthKey(year: 2026, month: 1))
        XCTAssertEqual(WorkspaceLayout.month(of: date("2026-12-31 23:59:59"), calendar: utc),
                       MonthKey(year: 2026, month: 12))
    }

    /// A photo taken on the last day of the year belongs to that year, not the
    /// next — the case a naive "add a month then take the year" would break.
    func testDecemberDoesNotRollIntoTheFollowingYear() {
        let key = WorkspaceLayout.month(of: date("2025-12-31 12:00:00"), calendar: utc)
        XCTAssertEqual(key, MonthKey(year: 2025, month: 12))
        XCTAssertEqual(WorkspaceLayout.monthFolder(key), "2025-12")
    }

    func testMonthKeysOrderByYearThenMonth() {
        let keys = [
            MonthKey(year: 2026, month: 1),
            MonthKey(year: 2025, month: 12),
            MonthKey(year: 2026, month: 2),
        ]
        XCTAssertEqual(keys.sorted().map(WorkspaceLayout.monthFolder),
                       ["2025-12", "2026-01", "2026-02"])
    }

    /// A bare `--year` expands to exactly these twelve, in order: the whole of
    /// the year-wide mode is this list, so a gap or a stray month here is a
    /// month of the library silently skipped or converted twice.
    func testMonthsInYearAreTheTwelveInOrder() {
        let months = MonthKey.months(inYear: 2019)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months, months.sorted())
        XCTAssertEqual(months.first, MonthKey(year: 2019, month: 1))
        XCTAssertEqual(months.last, MonthKey(year: 2019, month: 12))
        XCTAssertEqual(months.map(WorkspaceLayout.monthFolder).first, "2019-01")
        XCTAssertEqual(months.map(WorkspaceLayout.monthFolder).last, "2019-12")
        XCTAssertEqual(Set(months).count, 12)
    }

    /// Each of them must be a month `select` can actually fetch, and the twelve
    /// ranges must tile the year with no gap and no overlap — the property that
    /// makes a year of work equivalent to twelve separate months of it.
    func testMonthsInYearTileTheYearExactly() throws {
        let ranges = try MonthKey.months(inYear: 2019).map {
            try MonthBounds.range(year: $0.year, month: $0.month, calendar: utc)
        }
        XCTAssertEqual(ranges.first?.lowerBound, date("2019-01-01 00:00:00"))
        XCTAssertEqual(ranges.last?.upperBound, date("2020-01-01 00:00:00"))
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(earlier.upperBound, later.lowerBound)
        }
    }

    /// The month folder derived from a date must be the same month whose bounds
    /// `select` fetches, or a photo could be selected in one month and filed in
    /// another.
    func testMonthOfAgreesWithMonthBounds() throws {
        let range = try MonthBounds.range(year: 2026, month: 2, calendar: utc)
        let expected = MonthKey(year: 2026, month: 2)
        XCTAssertEqual(WorkspaceLayout.month(of: range.lowerBound, calendar: utc), expected)
        XCTAssertEqual(
            WorkspaceLayout.month(of: range.upperBound.addingTimeInterval(-1), calendar: utc),
            expected
        )
    }
}
