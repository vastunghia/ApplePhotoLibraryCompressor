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

    /// Photos sorts folders as text, so the padding is what keeps a year in
    /// chronological order rather than putting October before February.
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
