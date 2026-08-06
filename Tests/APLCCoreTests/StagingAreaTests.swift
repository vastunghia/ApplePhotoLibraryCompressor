import XCTest
@testable import APLCCore

final class StagingAreaTests: XCTestCase {
    private var temp: TempDirectory!

    override func setUpWithError() throws { temp = try TempDirectory() }
    override func tearDown() { temp = nil }

    func testATemporaryRootIsCreatedAndThenRemoved() throws {
        let area = try StagingArea()
        XCTAssertTrue(FileManager.default.fileExists(atPath: area.root.path))

        // The files a run leaves behind must go with it, not just the empty root.
        try FileManager.default.createDirectory(at: area.heicDirectory,
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: area.heicDirectory.appendingPathComponent("a.heic"))

        area.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: area.root.path))
    }

    /// The one that matters. `cleanUp` deletes a tree recursively, so it must be
    /// incapable of touching a directory the user named — otherwise
    /// `--staging-dir ~/Pictures` would be one command away from a disaster.
    func testAPinnedRootIsNeverRemoved() throws {
        let pinned = temp.file("pinned")
        let area = try StagingArea(pinnedTo: pinned.path)
        try Data("keep me".utf8).write(to: pinned.appendingPathComponent("evidence"))

        area.cleanUp()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: pinned.appendingPathComponent("evidence").path))
    }

    func testTwoTemporaryAreasDoNotShareARoot() throws {
        let first = try StagingArea()
        let second = try StagingArea()
        defer { first.cleanUp(); second.cleanUp() }
        XCTAssertNotEqual(first.root, second.root)
    }

    func testCleaningUpTwiceIsHarmless() throws {
        let area = try StagingArea()
        area.cleanUp()
        area.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: area.root.path))
    }

    /// `convert` hands the root to the commands it drives this way, and they must
    /// see it as pinned — only the owner may clean up.
    func testForwardedArgumentsPinTheSameRoot() throws {
        let owner = try StagingArea()
        defer { owner.cleanUp() }

        let arguments = owner.forwardedArguments
        XCTAssertEqual(arguments.first, "--staging-dir")

        let child = try StagingArea(pinnedTo: arguments[1])
        XCTAssertEqual(child.root, owner.root)
        child.cleanUp()
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner.root.path))
    }
}
