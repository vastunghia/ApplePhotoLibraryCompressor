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

            Work a month at a time. `select` gathers what that month still has
            left to convert, and the rest find it from the same --year and --month:

              aplc select  --year 2019 --month 7
              aplc convert --year 2019 --month 7 --out ./staging

            Or a step at a time, which is the same work with a pause after each:

              aplc select    --year 2019 --month 7
              aplc scan      --year 2019 --month 7
              aplc calibrate --year 2019 --month 7 --out ./staging
              aplc transcode --year 2019 --month 7 --out ./staging
              aplc verify    --out ./staging
              aplc apply     --year 2019 --month 7 --out ./staging --confirm

            Everything lives in "aplc workspace" > "YYYY-MM" in Photos, with the
            originals and their copies side by side. Pass --album instead to work
            on an album you made by hand.

            Quality is chosen per photo, by `transcode`, to meet --min-ssim.
            Pass --quality to fix it by hand instead.
            """,
        version: "0.1.0",
        subcommands: [
            Convert.self, Select.self, Scan.self, Calibrate.self,
            Transcode.self, Verify.self, Apply.self,
        ]
    )
}
