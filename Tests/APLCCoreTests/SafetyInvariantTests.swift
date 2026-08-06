import XCTest
@testable import APLCCore

/// These tests do not exercise behaviour — they guard the property that makes
/// this tool safe to run against an irreplaceable photo library: the destructive
/// PhotoKit calls are not merely unused, they are absent from the source.
///
/// If someone later adds `deleteAssets`, this fails and the reviewer has to make
/// that a deliberate, visible decision rather than an incidental one.
final class SafetyInvariantTests: XCTestCase {
    /// PhotoKit calls that would destroy or overwrite existing library content.
    private static let forbidden = [
        // Moves assets to Recently Deleted.
        "deleteAssets",
        // Replaces an asset's current rendition.
        "contentEditingOutput",
        // Discards a user's edits.
        "revertAssetContentToOriginal",
        // Deletes albums or removes assets from them.
        "deleteAssetCollections",
        "removeAssets",
        // The same rule one level up. `PHCollectionListChangeRequest` is what
        // builds the workspace folders, and the class that can create a folder
        // can also unmake one or empty it — so a folder is as one-way as an
        // album, deliberately and by the same test.
        "deleteCollectionLists",
        "removeChildCollections",
        "removeChildCollectionsAtIndexes",
        "replaceChildCollectionsAtIndexes",
        "moveChildCollectionsAtIndexes",
        // Deletes the file we exported *from* the library rather than a copy.
        "PHAssetChangeRequest.deleteAssets",
        // Private API, and worse than everything above it: these act on an
        // entire iCloud Shared Photo Library, so they would destroy the other
        // participants' photos too — data the user could not restore. The
        // symbols are absent from the public headers but present in Photos.tbd,
        // so they are reachable; they stay out of this binary by choice.
        "expungeLibraryScopes",
        "trashLibraryScopes",
        "PHLibraryScopeChangeRequest",
    ]

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/APLCCoreTests/SafetyInvariantTests.swift
            .deletingLastPathComponent()          // .../Tests/APLCCoreTests
            .deletingLastPathComponent()          // .../Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("Sources")
    }

    private func swiftSources() throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            XCTFail("cannot enumerate \(sourceRoot.path)")
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testSourcesContainNoDestructivePhotoKitCalls() throws {
        let sources = try swiftSources()
        XCTAssertFalse(sources.isEmpty, "found no Swift sources to scan")

        for url in sources {
            // This file necessarily names the forbidden symbols.
            if url.lastPathComponent == "SafetyInvariantTests.swift" { continue }

            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments explaining what the tool deliberately avoids are fine.
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                for symbol in Self.forbidden where line.contains(symbol) {
                    XCTFail("""
                        \(url.lastPathComponent) calls \(symbol), which can destroy \
                        library content. This tool must only ever create assets.
                        Offending line: \(trimmed)
                        """)
                }
            }
        }
    }

    /// Word-boundary matched so "deleted" inside a string would not trip it, and
    /// so `description` does not read as a hit for some substring.
    private func words(of script: String) -> [String] {
        script.components(separatedBy: CharacterSet.alphanumerics.inverted).map { $0.lowercased() }
    }

    /// Apple Events are a second route into the library, and Photos' dictionary
    /// exposes destructive verbs there too. The text scripts must only ever set
    /// the three text properties.
    func testGeneratedAppleScriptsAreNonDestructive() {
        let scripts = [
            PhotosScripting.readScript(for: ["A/L0/001"]),
            PhotosScripting.writeScript(for: [
                ("A/L0/001", AssetTextMetadata(keywords: ["k"], title: "t", caption: "c"))
            ]),
        ]

        let forbiddenVerbs = ["delete", "remove", "duplicate", "move", "import", "export"]

        for script in scripts {
            let found = words(of: script)
            for verb in forbiddenVerbs {
                XCTAssertFalse(found.contains(verb),
                               "generated AppleScript uses the verb \"\(verb)\":\n\(script)")
            }
        }
    }

    /// `import` is the one verb allowed out of that list, in the one script that
    /// exists to use it — and the exception is narrow on purpose.
    ///
    /// It was on the list as a write path outside the audited one, not as
    /// something that can destroy: `import` only ever adds an asset. The property
    /// the list protects — that nothing here can lose a photo — is untouched, and
    /// every verb that *could* lose one stays banned in this script too.
    func testTheImportScriptUsesImportAndNothingElseFromTheBannedList() {
        let script = PhotosScripting.importScript(for: [URL(fileURLWithPath: "/tmp/a.heic")])
        let found = words(of: script)

        XCTAssertTrue(found.contains("import"), "the import script should import:\n\(script)")
        for verb in ["delete", "remove", "duplicate", "move", "export"] {
            XCTAssertFalse(found.contains(verb),
                           "the import script uses the verb \"\(verb)\":\n\(script)")
        }
    }

    /// It hands Photos files and reads identifiers back. It must not reach for a
    /// `media item` to change, nor name an album — album titles stopped
    /// identifying albums when the workspace began repeating them per month, so
    /// `into` is deliberately not used.
    func testTheImportScriptAssignsNothingToAMediaItemAndNamesNoAlbum() {
        let script = PhotosScripting.importScript(for: [URL(fileURLWithPath: "/tmp/a.heic")])

        for line in script.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set ") else { continue }
            XCTAssertFalse(trimmed.contains(" of m to "),
                           "the import script assigns to a media item: \(trimmed)")
        }
        XCTAssertFalse(words(of: script).contains("album"),
                       "the import script names an album:\n\(script)")
    }

    /// Whatever else changes, these are the only properties we may assign.
    func testGeneratedAppleScriptsAssignOnlyPermittedProperties() {
        let script = PhotosScripting.writeScript(for: [
            ("A/L0/001", AssetTextMetadata(keywords: ["k"], title: "t", caption: "c"))
        ])
        let permitted = ["set keywords of m to", "set name of m to",
                         "set description of m to", "set m to media item id",
                         "set failed to", "set end of failed to"]

        for line in script.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set ") else { continue }
            XCTAssertTrue(permitted.contains { trimmed.hasPrefix($0) },
                          "unexpected assignment in generated script: \(trimmed)")
        }
    }

    /// The read script names the same three properties as the write script, so
    /// one misplaced `to` would turn a read into a write. It may only ever assign
    /// to its own local variables.
    func testTheReadScriptAssignsNothingToAMediaItem() {
        let script = PhotosScripting.readScript(for: ["A/L0/001"])

        for line in script.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("set ") else { continue }
            XCTAssertFalse(trimmed.contains(" of m to "),
                           "the read script assigns to a media item: \(trimmed)")
        }
    }

    /// The staging directory is a safety net; nothing should move files out of it.
    func testImporterCopiesRatherThanMovesStagedFiles() throws {
        let importer = sourceRoot
            .appendingPathComponent("APLCCore/Importer.swift")
        let text = try String(contentsOf: importer, encoding: .utf8)
        XCTAssertTrue(
            text.contains("shouldMoveFile = false"),
            "Importer must copy staged files into the library, never move them"
        )
    }
}
