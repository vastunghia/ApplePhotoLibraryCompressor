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

            Three commands write to the library, and all three say so: `apply`,
            which needs --confirm; `convert`, where typing the command is the
            confirmation and --dry-run is how you hold it back; and `select`,
            which only ever fills an album.

            The whole pipeline in one command, once you know you want the copies:

              aplc convert --album "My Album" --out ./staging --dest-album "Converted"

            Or a step at a time, which is the same work with a pause after each:

              aplc select    --year 2019 --month 7 --album "My Album"
              aplc scan      --album "My Album"
              aplc calibrate --album "My Album" --out ./staging
              aplc transcode --album "My Album" --out ./staging
              aplc verify    --out ./staging
              aplc apply     --album "My Album" --out ./staging --dest-album "Converted"

            Quality is chosen per photo, by `transcode`, to meet --min-ssim.
            Pass --quality to fix it by hand instead.

            `select` stands before all of that: it builds the album to work on
            from one month of photos, leaving out whatever it already finds a
            converted copy of.
            """,
        version: "0.1.0",
        subcommands: [
            Convert.self, Select.self, Scan.self, Calibrate.self,
            Transcode.self, Verify.self, Apply.self,
        ]
    )
}
