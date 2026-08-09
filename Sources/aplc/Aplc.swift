import ArgumentParser
import Foundation

@main
struct Aplc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aplc",
        abstract: "Convert JPEG originals in the macOS Photos library to HEIC.",
        discussion: """
            aplc never deletes or modifies an existing asset. It transcodes copies
            into a temporary folder, checks each result against its original, and
            adds the converted copies back as new assets in an album of their own.
            Removing the JPEG originals afterwards is left to you, in Photos.app.

            Work a month at a time. One command does all of it:

              aplc convert --year 2019 --month 7

            Leave --month out and it works through all twelve months of the year
            in turn, each one exactly as if you had asked for it alone:

              aplc convert --year 2019

            Only `apply` and `convert` create assets, and both say so: `apply`
            needs --confirm, and on `convert` typing the command is the
            confirmation, with --dry-run to hold it back.

            But with --year every command also gathers each month's
            unconverted JPEGs into "Selected Originals" before doing its own work
            — the job `select` does, now done for you. That is an album write, so
            in month mode `scan` and `calibrate` are not read-only either. Pass
            --album to point at an album you made by hand, which is never created
            or added to.

            To look before converting:

              aplc scan      --year 2019 --month 7   # what is convertible, and why not
              aplc calibrate --year 2019 --month 7   # sample encodes to judge by eye
              aplc convert   --year 2019 --month 7 --dry-run

            Everything lives in "aplc workspace" > "YYYY" > "YYYY-MM" in Photos, with the
            originals and their copies side by side.

            Staging is temporary and leaves nothing on disk. The journal is not:
            every run appends to ~/Library/Application Support/aplc/, which is how
            a photo converted months ago is still known to have been converted.

            Quality is chosen per photo to meet --min-ssim. Pass --quality to fix
            it by hand instead.
            """,
        version: "0.1.0",
        subcommands: [
            Convert.self, Select.self, Scan.self, Calibrate.self,
            Transcode.self, Verify.self, Apply.self,
        ]
    )
}
