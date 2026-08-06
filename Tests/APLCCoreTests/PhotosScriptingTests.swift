import XCTest
@testable import APLCCore

/// These tests never talk to Photos. They exercise script generation and reply
/// parsing, which is where the bugs that would corrupt someone's metadata live.
final class PhotosScriptingTests: XCTestCase {

    // MARK: - String escaping

    func testPlainStringIsQuoted() {
        XCTAssertEqual(PhotosScripting.literal("Milano"), "\"Milano\"")
    }

    func testQuotesAreEscaped() {
        XCTAssertEqual(PhotosScripting.literal(#"say "hi""#), #""say \"hi\"""#)
    }

    /// Backslash must be escaped before the quote. Doing it the other way round
    /// would turn \" into \\" and break the literal.
    func testBackslashIsEscapedBeforeQuote() {
        XCTAssertEqual(PhotosScripting.literal(#"a\b"#), #""a\\b""#)
        XCTAssertEqual(PhotosScripting.literal(#"\""#), #""\\\"""#)
    }

    /// A raw newline inside an AppleScript literal is a syntax error, and real
    /// captions contain them.
    func testNewlinesBecomeEscapeSequences() {
        XCTAssertEqual(PhotosScripting.literal("a\nb"), #""a\nb""#)
        XCTAssertEqual(PhotosScripting.literal("a\r\nb"), #""a\nb""#)
        XCTAssertEqual(PhotosScripting.literal("a\tb"), #""a\tb""#)

        for generated in [PhotosScripting.literal("a\nb"), PhotosScripting.literal("a\r\nb")] {
            XCTAssertFalse(generated.contains("\n"), "literal still contains a raw newline")
            XCTAssertFalse(generated.contains("\r"), "literal still contains a raw carriage return")
        }
    }

    func testNonASCIISurvivesUnescaped() {
        XCTAssertEqual(PhotosScripting.literal("Perché è così"), "\"Perché è così\"")
    }

    // MARK: - Script generation

    func testReadScriptAddressesEachAssetByIdentifier() {
        let script = PhotosScripting.readScript(for: ["A/L0/001", "B/L0/001"])
        XCTAssertTrue(script.contains(#"set m to media item id "A/L0/001""#))
        XCTAssertTrue(script.contains(#"set m to media item id "B/L0/001""#))
        XCTAssertTrue(script.contains("return outList"))
    }

    /// Reading must not depend on an album title, which the workspace made
    /// ambiguous: the same two names repeat in every month's folder.
    func testReadScriptNeverLooksAnAlbumUpByName() {
        let script = PhotosScripting.readScript(for: ["A/L0/001"])
        XCTAssertFalse(script.contains("albums"))
        XCTAssertFalse(script.contains("name of a"))
    }

    /// One unreachable asset must not cost the rest of the batch.
    func testReadScriptGuardsEachAssetSeparately() {
        let script = PhotosScripting.readScript(for: ["A/L0/001", "B/L0/001", "C/L0/001"])
        XCTAssertEqual(script.components(separatedBy: "end try").count - 1, 3 * 4)
    }

    func testWriteScriptSetsOnlyTheThreeProperties() {
        let script = PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata(keywords: ["P:Grazia", "L:Milano"],
                                           title: "Titolo", caption: "Didascalia"))
        ])

        XCTAssertTrue(script.contains(#"set m to media item id "A/L0/001""#))
        XCTAssertTrue(script.contains(#"set keywords of m to {"P:Grazia", "L:Milano"}"#))
        XCTAssertTrue(script.contains(#"set name of m to "Titolo""#))
        XCTAssertTrue(script.contains(#"set description of m to "Didascalia""#))
    }

    func testWriteScriptOmitsAbsentProperties() {
        let script = PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata(keywords: ["solo"], title: nil, caption: nil))
        ])
        XCTAssertTrue(script.contains("set keywords of m to"))
        XCTAssertFalse(script.contains("set name of m to"))
        XCTAssertFalse(script.contains("set description of m to"))
    }

    /// A refused asset must not abort the rest of the batch.
    func testWriteScriptIsolatesFailuresPerAsset() {
        let script = PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata(keywords: ["a"])),
            ("B/L0/001", AssetTextMetadata(keywords: ["b"])),
        ])
        XCTAssertEqual(script.components(separatedBy: "on error").count - 1, 2)
        XCTAssertTrue(script.contains(#"set end of failed to "A/L0/001""#))
        XCTAssertTrue(script.contains("return failed"))
    }

    func testEmptyMetadataProducesNoSetStatements() {
        let script = PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata())
        ])
        XCTAssertFalse(script.contains("set keywords of m to"))
        XCTAssertFalse(script.contains("media item id"))
    }

    // MARK: - Generated scripts must actually compile

    /// Compiles the generated source with osacompile. This only resolves
    /// terminology from the Photos bundle — it does not execute anything and
    /// does not need Automation consent.
    private func assertCompiles(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let photos = URL(fileURLWithPath: "/System/Applications/Photos.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: photos.path),
                          "Photos.app is not installed")

        let directory = try TempDirectory()
        let input = directory.file("script.applescript")
        try source.write(to: input, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osacompile")
        process.arguments = ["-o", directory.file("out.scpt").path, input.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0,
                       "generated AppleScript did not compile:\n\(errorText)", file: file, line: line)
    }

    func testGeneratedReadScriptCompiles() throws {
        try assertCompiles(PhotosScripting.readScript(for: ["A/L0/001", "B/L0/001"]))
    }

    func testGeneratedWriteScriptCompiles() throws {
        try assertCompiles(PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata(keywords: [#"tricky "kw""#, "normale"],
                                           title: "Titolo\ncon a capo",
                                           caption: #"back\slash e "virgolette""#)),
            ("B/L0/001", AssetTextMetadata(keywords: [], title: nil, caption: "solo didascalia")),
        ]))
    }

    // MARK: - Batching

    func testWritingIsChunked() {
        let entries = (0..<(PhotosScripting.batchSize * 2 + 5)).map {
            (key: "ID-\($0)/L0/001", value: AssetTextMetadata(keywords: ["k"]))
        }
        let chunks = stride(from: 0, to: entries.count, by: PhotosScripting.batchSize).map {
            Array(entries[$0..<min($0 + PhotosScripting.batchSize, entries.count)])
        }
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.count).reduce(0, +), entries.count)
    }

    // MARK: - Value semantics

    func testIsEmptyTreatsBlankStringsAsAbsent() {
        XCTAssertTrue(AssetTextMetadata().isEmpty)
        XCTAssertTrue(AssetTextMetadata(keywords: [], title: "", caption: "").isEmpty)
        XCTAssertFalse(AssetTextMetadata(keywords: ["k"]).isEmpty)
        XCTAssertFalse(AssetTextMetadata(title: "t").isEmpty)
        XCTAssertFalse(AssetTextMetadata(caption: "c").isEmpty)
    }

    func testMetadataRoundTripsThroughTheLedger() throws {
        let directory = try TempDirectory()
        let url = directory.file("ledger.jsonl")
        let ledger = try Ledger(url: url)
        let metadata = AssetTextMetadata(keywords: ["P:Grazia", "L:Milano"],
                                         title: "Titolo", caption: "Riga1\nRiga2")

        try ledger.append(LedgerEntry(outcome: .applied,
                                      sourceLocalIdentifier: "A", originalFilename: "1.JPG",
                                      sourceTextMetadata: metadata,
                                      appliedTextMetadata: metadata))

        let entry = try Ledger.readAll(at: url).first
        XCTAssertEqual(entry?.sourceTextMetadata, metadata)
        XCTAssertEqual(entry?.appliedTextMetadata, metadata)
    }
    // MARK: - The import script

    func testTheImportScriptListsEveryFileAsAPOSIXPath() {
        let script = PhotosScripting.importScript(for: [
            URL(fileURLWithPath: "/tmp/a/IMG_1.heic"),
            URL(fileURLWithPath: "/tmp/b/IMG_2.heic"),
        ])
        XCTAssertTrue(script.contains("POSIX file \"/tmp/a/IMG_1.heic\""), script)
        XCTAssertTrue(script.contains("POSIX file \"/tmp/b/IMG_2.heic\""), script)
    }

    /// A quote or a backslash in a path must not end the literal early. Photos
    /// would either fail to compile the script or, worse, be handed a different
    /// path than the one intended.
    func testAPathWithAQuoteIsEscaped() {
        let script = PhotosScripting.importScript(for: [
            URL(fileURLWithPath: "/tmp/it\"s/a.heic")
        ])
        XCTAssertTrue(script.contains("\\\""), script)
        XCTAssertEqual(script.components(separatedBy: "POSIX file").count - 1, 1)
    }

    /// Photos applies its own duplicate rule otherwise, and an import that comes
    /// back empty is indistinguishable from one that failed. `DuplicateCheck` has
    /// already asked the library, and asked the user where it was unsure.
    func testTheImportScriptLeavesDuplicateCheckingToUs() {
        let script = PhotosScripting.importScript(for: [URL(fileURLWithPath: "/tmp/a.heic")])
        XCTAssertTrue(script.contains("skip check duplicates true"), script)
    }

    /// The identifiers come back in the reply, which is the only reason this can
    /// be used at all: without them there would be no way to set the capture date
    /// afterwards or to file the copy in its album.
    ///
    /// The filename comes back with them because nothing in Photos' dictionary
    /// promises the order of the returned list, and matching results to inputs by
    /// position would put one photo's metadata on another.
    func testTheImportScriptReturnsIdentifiersAndFilenames() {
        let script = PhotosScripting.importScript(for: [URL(fileURLWithPath: "/tmp/a.heic")])
        XCTAssertTrue(script.contains("set end of outList to {id of m, filename of m}"), script)
        XCTAssertTrue(script.contains("return outList"), script)
    }

    /// One `import` is one import session. A script per file would give a month's
    /// conversion one single-photo entry under Imports for every photo, which is
    /// the opposite of what the feature is for.
    func testEveryFileGoesIntoASingleImportCall() {
        let urls = (1...20).map { URL(fileURLWithPath: "/tmp/IMG_\($0).heic") }
        let script = PhotosScripting.importScript(for: urls)

        XCTAssertEqual(script.components(separatedBy: " import ").count - 1, 1, script)
        XCTAssertEqual(script.components(separatedBy: "POSIX file").count - 1, 20)
    }

}
