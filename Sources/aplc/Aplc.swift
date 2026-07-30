import ArgumentParser
import Foundation

@main
struct Aplc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aplc",
        abstract: "Convert JPEG originals in the macOS Photos library to HEIC.",
        discussion: """
            aplc never deletes or modifies an existing asset. It transcodes copies
            into a staging folder, checks each result against its original, and — \
            only when you pass --confirm — adds the converted copies back as new
            assets in an album of their own. Removing the JPEG originals afterwards
            is left to you, in Photos.app.

            The usual order is:

              aplc scan      --album "My Album"
              aplc calibrate --album "My Album" --out ./staging
              aplc transcode --album "My Album" --out ./staging
              aplc verify    --out ./staging
              aplc apply     --album "My Album" --out ./staging --dest-album "Converted"
            """,
        version: "0.1.0",
        subcommands: [Scan.self, Calibrate.self, Transcode.self, Verify.self, Apply.self]
    )
}
