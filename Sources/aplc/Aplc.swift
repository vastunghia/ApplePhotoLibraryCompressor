import ArgumentParser
import Foundation

@main
struct Aplc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aplc",
        abstract: "Convert JPEG originals in the macOS Photos library to HEIC.",
        discussion: """
            aplc never deletes or modifies an existing asset. It transcodes copies
            into a staging folder, checks each result against its original, and adds
            the converted copies back as new assets in an album of their own.
            Removing the JPEG originals afterwards is left to you, in Photos.app.

            Two commands write to the library, and both say so: `apply`, which
            needs --confirm, and `convert`, where typing the command is the
            confirmation and --dry-run is how you hold it back.

            The whole pipeline in one command, once you know you want the copies:

              aplc convert --album "My Album" --out ./staging --dest-album "Converted"

            Or a step at a time, which is the same work with a pause after each:

              aplc scan      --album "My Album"
              aplc calibrate --album "My Album" --out ./staging
              aplc transcode --album "My Album" --out ./staging
              aplc verify    --out ./staging
              aplc apply     --album "My Album" --out ./staging --dest-album "Converted"

            Quality is chosen per photo, by `transcode`, to meet --min-ssim.
            Pass --quality to fix it by hand instead.
            """,
        version: "0.1.0",
        subcommands: [
            Convert.self, Scan.self, Calibrate.self, Transcode.self, Verify.self, Apply.self,
        ]
    )
}
