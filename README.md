# ApplePhotoLibraryCompressor (`aplc`)

An open-source macOS command-line tool that re-encodes the JPEG originals in your
Photos library as HEIC — reclaiming most of the space they take, at a fidelity
you choose — and that **cannot delete or modify anything**, by construction and
by test.

You convert a month, look at the results in Photos.app, and delete the old JPEGs
yourself. The tool never does that part.

## Why you might want it

### The space

In most libraries the JPEG originals are the largest thing after video, and HEIC
carries the same picture in a fraction of the bytes. `aplc` does not guess at a
quality setting: for each photo it searches for the **cheapest encoder setting
that still reaches the fidelity you asked for** (SSIM 0.97 by default), by
encoding and measuring rather than by assuming.

**Expect around 75%.** Measured over a full year — about 2,000 photographs,
twelve months, several cameras — 18.2 GB of JPEG became 4.5 GB of HEIC, a saving
of **74.5%**, and no single month fell outside 73.7%–78.3%. The consistency is
worth more than the headline figure: it is what lets you plan a library.

Two things move that number, and it is worth knowing which way:

- **How generously the originals were encoded.** Those were high-quality JPEG
  exports from a raw workflow, and that is where the fat is. Photos written
  straight out of a phone are already closer to the bone and will give up less.
- **The fidelity you ask for.** SSIM 0.97 is the default; `--min-ssim` moves it,
  and the saving moves with it.

Searching per photo is where most of that comes from. On one set of photographs,
against a fixed `--quality 0.8`:

| | space saved | SSIM range |
|---|---|---|
| fixed quality 0.80 | 77.1% | 0.9735 – 0.9805 |
| automatic, target 0.97 | **82.6%** | 0.9703 – 0.9735 |

The fixed setting was overshooting the bar it had been given, and paying for it
in bytes. Read that table as the shape of the argument rather than as a forecast:
it is five photographs from one shoot, an easy set, which is why it flatters the
74.5% above. `aplc calibrate` shows you the trade-off on your own pictures before
you commit to anything.

### It cannot destroy anything

- **It only ever *creates*.** New assets, new albums, new folders. That is all
  the code can do.
- **The destructive PhotoKit calls appear nowhere in `Sources/`** —
  `deleteAssets`, `removeAssets`, `contentEditingOutput`,
  `revertAssetContentToOriginal`, and the private shared-library API that could
  reach photos belonging to people you share with. `SafetyInvariantTests` greps
  the sources on every `swift test` and fails the build if one appears.
- **Every conversion must pass a gate.** Edited photos, Live Photos, HDR photos
  that would lose their gain map, anything that loses metadata or fails the
  fidelity target — all skipped, with a recorded reason, never converted
  approximately. Failing the fidelity bar is rare in practice: across 2,000
  photographs it happened once, to a photo no setting on the ladder could
  encode well enough, which was left alone.
- **Deletion is yours, in Photos.app.** The tool gathers the JPEGs it replaced
  into one album so it is a single gesture, and stops there.
- **So your library grows before it shrinks.** Copies are added alongside the
  originals, and with iCloud Photos on they are uploaded too.

None of that is a guarantee about your library — please read the
[Disclaimer](#disclaimer) before you point this at photos you care about.

### Open source, so you can check

The tools that promise this are typically iOS-only and closed-source, which is a
poor combination for something that rewrites an irreplaceable photo library. You
are asked to trust a binary with the one collection you cannot recreate.

Here the safety properties are not promises: they are
[tests you can run](Tests/APLCCoreTests/SafetyInvariantTests.swift), on code you
can read. [`TECHNICAL.md`](TECHNICAL.md) documents what the tool does and why,
including what it deliberately refuses to do.

## Requirements

macOS 14 or later, and the Swift 6 toolchain (Xcode or the Command Line Tools).

**Where it has actually been run: macOS 15.7, on a six-core Intel Mac, against a
library whose originals are all on local disk.** Everything outside that is
untested rather than unsupported. It is built against the macOS 26 SDK while
targeting macOS 14, so newer APIs cannot slip in and crash an older system — but
that is an argument about how it compiles, not evidence about how it runs.

### Beta testers wanted

Three configurations would genuinely help, and a report of any of them is
welcome as an
[issue](https://github.com/vastunghia/ApplePhotoLibraryCompressor/issues) —
including the boring outcome where everything simply worked.

- **Apple Silicon.** Nothing here has ever run on an M-series Mac. Speed is the
  obvious unknown, but the more interesting one is the quality ladder: the
  encoder settings HEIC actually distinguishes were measured on Intel's ImageIO
  and are assumed to be a property of the encoder. If Apple Silicon quantises
  them differently the search will still return an honest result — every rung it
  accepts has been measured against your fidelity target — but it may waste
  probes, or leave saving on the table. The `(N encodes per photo)` figure in the
  transcode summary is the number to report.
- **macOS 26.** The risk is not the SDK, it is Photos itself: the scripting
  dictionary that carries keywords, title and caption, and any change in how
  PhotoKit reports assets. If keywords stop transferring, the `apply` summary
  says so explicitly rather than passing over it.
- **A library set to "Optimise Mac Storage"**, where originals live in iCloud
  rather than on disk — see [known limitations](#known-limitations) below.

In all three cases: run `aplc scan` first, then a single small month, and read
the report before going further.

## Setup

```sh
git clone https://github.com/vastunghia/ApplePhotoLibraryCompressor.git
cd ApplePhotoLibraryCompressor
swift build -c release            # release always: measuring fidelity is compute-heavy
cp .build/release/aplc /usr/local/bin/
```

macOS will ask for permission the first time you run it. Two separate grants are
involved, in System Settings → Privacy & Security, and they are attributed to the
**terminal application** you run `aplc` from:

- **Photos** — required, to read your photos and add the copies.
- **Automation → your terminal → Photos** — optional, and only used to carry
  keywords, titles and captions across. Without it the conversion runs anyway and
  tells you what it could not carry.

## Use it, one month at a time

```sh
aplc convert --year 2019 --month 7 --dry-run   # see what it would do
aplc convert --year 2019 --month 7             # do it
```

That is the whole tool. There is no preparatory step: `convert` finds the
month's JPEGs that have no converted copy yet, encodes them, re-checks every
result, and only then adds the copies to your library. It stops before writing if
the month has nothing left to do, if nothing passed the gate, or if a check
fails. It is safe to re-run — nothing is ever imported twice.

Start with `--limit 5` on a month you know well, and look at the results before
converting the rest.

It begins by telling you where the month stands:

```
July 2019
  photos in the month        412
  already HEIC                86
  JPEGs already converted     74
  JPEGs still to convert     240
  added to aplc workspace > 2019 > 2019-07 > Selected Originals   240

Why the rest are excluded
  notAJPEG        86  — original resource is not a JPEG
  hasAdjustments  12  — the photo has edits that would be lost
```

Then it converts, one line per photo, each carrying which month it belongs to,
how far through that month it is, and roughly how much longer the month has to
run:

```
  [ July 2019  123/198  62%  ~6m left ]  IMG_4471.jpg  8.2 MB -> 1.9 MB  (77% saved, q=0.88, SSIM 0.9733)
```

The month is on every line rather than only in a header, because on a long month
the header scrolls out of the window.

The estimate is the recent seconds-per-photo rather than the average from the
start, so it follows a month that changes camera part way through instead of
taking another hour to notice. It is a guess, and it says so with a `~`. The
count moves in steps of two or three when several photos are converted at once —
results are reported in album order, so the ones that finish early wait for the
photo in front of them.

**Encoding is the whole cost** — importing is instant. Budget **about five
seconds per photo** for 20-megapixel originals on a six-core Intel Mac; over a
twelve-month run, everything that was not encoding — scanning, selecting,
importing, verifying — added up to a rounding error against it. A month is a
coffee; a large library is days of machine time, which is why the tool is built
around working through it a month at a time.

### Or a whole year, unattended

Leave `--month` out and it works through all twelve months of that year, in
order:

```sh
aplc convert --year 2019
```

Each month is done exactly as if you had asked for it on its own — same albums,
same checks, its own temporary staging that goes away before the next month
starts. What changes is only that you type it once.

Three things worth knowing before you leave it running:

- **A month that fails does not stop the rest.** It is reported in a summary at
  the end, one line per month, and the command exits non-zero so a script still
  notices.
- **Interrupting is safe, and so is starting again.** Whether a photo is already
  converted is a question the tool asks your library, not a note it keeps, so a
  second run simply picks up what the first did not finish.
- **A year is hours, not minutes.** Budget from the count, not from the calendar:
  at roughly **five seconds per photo** a year of 2,000 photographs is about
  **three hours**, and a heavily shot year can be most of a day. Start with
  `aplc scan --year 2019` to see how many there are before committing an evening
  to it, or `--dry-run` to watch the whole thing decide without writing anything.

  That rate is from a six-core Intel i5 with 20-megapixel originals, and it is
  what a *sustained* run gives rather than a short one — see the note on
  throttling under [known limitations](#known-limitations). Smaller photographs
  are proportionally quicker: the cost tracks megapixels closely. Other hardware
  has not been measured, so scale it by your own first month rather than
  trusting it.

`scan`, `select` and `calibrate` take a bare `--year` too.

Note that `convert` writes without asking for confirmation: typing it *is* the
confirmation, and `--dry-run` is how you hold it back. Nothing it writes is
irreversible — the worst case is copies you delete by hand.

## Then, in Photos.app: three manual steps

The space does not come back until you do these. Do them **in this order**.

1. **Review the copies.** They are in `aplc workspace > YYYY-MM > Compressed
   Copies`. Look at a few at full size, next to their originals.

2. **Re-do the iCloud Shared Photo Library membership by hand.** If the originals
   were in your Shared Library, the copies are *not*: they are always created in
   your personal library, and no supported API can change that. The ones this
   applies to are gathered in `aplc workspace > YYYY-MM > Compressed Copies - to
   Share`, so it is a select-all and **Move to Shared Library**.

   This comes before step 3 on purpose. Deleting a shared original removes it
   **for everyone it was shared with** — so if you delete first, the other
   participants lose the photo and your copy stays personal.

3. **Delete the JPEG originals.** They are gathered for you in `aplc workspace >
   YYYY-MM > Compressed Originals`, so it is one select-all and one keystroke.

   > **Inside an album you must press ⌘⌫ (Command-Delete), not plain ⌫.**
   > Plain ⌫ only removes the photo *from the album*: the file stays, no space is
   > reclaimed, and nothing reaches Recently Deleted — so nothing tells you it did
   > not work. The two gestures look identical in the interface. This was
   > discovered the hard way.

   Deleted photos then sit in Recently Deleted for 30 days before the space is
   actually returned.

Two things worth knowing afterwards:

- **People come back on their own.** Face-to-person assignments cannot be copied
  by any supported API, but Photos re-derives them by recognition. The catch is
  that `photoanalysisd` only runs while your Mac is **idle**, so a copy checked
  straight after import shows no people at all and looks like a failure. Leave
  the Mac alone for a while and they appear.
- **Photos' search is not how to check what happened.** Its index is a separate
  database rebuilt in the background, so it can miss a photo that is really there
  and linger on one you deleted. Trust the albums.

## The workspace

The tool builds a folder tree in Photos as it goes, so you can see what is done:

```
aplc workspace
├── 2019
│   ├── 2019-06
│   │   ├── Selected Originals            the JPEGs it found to convert
│   │   ├── Compressed Originals          the JPEGs those replaced — delete from here
│   │   ├── Compressed Copies             the HEICs it created
│   │   └── Compressed Copies - to Share  of those, the ones to move back into
│   │                                     your Shared Library — see manual step 2
│   └── 2019-07
│       └── …
└── 2020
    └── …
```

Years, months and albums are each put in the right place as they are made: the
albums in the order you work through them, the folders by date. That has to
happen at creation, because Photos shows a folder's contents in the order they
were added and ignores their names — and this tool cannot move something it has
already created, deliberately, since the call that reorders is also the call that
can take things out.

**So anything made before a given version keeps the arrangement it was made
with.** If you used `aplc` before the year folders existed, your month folders are
still at the top of `aplc workspace`; the tool goes on finding and using them
there, indefinitely, and nothing breaks if you leave them. Drag one into a year
folder whenever you like and it will be found there instead — there is no
migration step to run, and none is needed.

Copies are filed by the **capture date of the original**, not by when you
converted them, so a photo you convert next year still lands beside the JPEG it
came from. Photos with no capture date at all go to `aplc workspace > undated`.
Nothing is created before there is something to put in it — a month where nothing
was shared gets no `Compressed Copies - to Share` album at all.

**Why `Selected Originals` and `Compressed Originals` can differ.** They usually
hold the same photos, but not always, and the difference is deliberate:
`Compressed Originals` only accepts a JPEG whose replacement **this tool made, in
a run it watched, and checked afterwards**. So a photo that was skipped because a
converted copy already existed appears in `Selected Originals` but never in
`Compressed Originals` — even though its copy is sitting right there. Photos you
converted before installing the tool never appear in it either.

That narrowness is the point: `Compressed Originals` is the album that invites
deletion, and having *found* a replacement is not the same standard as having
*made* one. To see the wider picture, use the "JPEGs already converted" count
that every run prints.

`Compressed Copies - to Share` is narrow in the same way, and in one more: a copy
goes in only if the tool could actually read that its original was in a Shared
Library. When it cannot, the copy is left out and the run says how many — leaving
a photo for you to share by hand is a smaller mistake than publishing a personal
one to other people.

One caveat: **album membership is one-way.** Putting a photo into an album needs
no destructive API; taking it out does, and this tool contains none. So a wrong
month is undone by hand in Photos.app, and nothing here can empty an album it
filled.

## Other commands

`convert` is the one to use. The pipeline steps exist separately, mostly for
looking at things:

| Command | What it does |
|---|---|
| `aplc scan --year Y --month M` | Census: how many photos are convertible, and why the rest are not. Writes nothing but album membership. |
| `aplc calibrate --year Y --month M` | Encodes a sample at several qualities and prints the path, for you to judge by eye. |
| `aplc calibrate --files a.jpg b.jpg` | The same on plain files, with no library access at all. |
| `aplc select --year Y --month M` | Just the "what is left to convert" step, on its own. |
| `aplc transcode` / `verify` / `apply` | The individual stages. Staging is temporary, so they cannot hand work to each other across separate runs — `convert` is what runs them in one process. |

Each of these takes a bare `--year Y` as well, meaning all twelve months.

Options worth knowing:

| Option | |
|---|---|
| `--year Y` without `--month` | Work through all twelve months of that year, one at a time. |
| `--album "Name"` | Work on an album you made by hand instead of a month. The only form that writes nothing at all. |
| `--limit N` | Stop after N photos. `convert --year Y` applies it to each month. |
| `--jobs N` | How many photos to convert at once. Defaults to half your CPU cores; raising it is worth very little, because the encoder cannot run twice at the same time. |
| `--dry-run` | Do everything except write to the library. |
| `--min-ssim` | The fidelity target every conversion must reach. Default 0.97. |
| `--quality` | Fix the encoder quality instead of searching per photo. See [TECHNICAL.md](TECHNICAL.md#quality-is-chosen-per-photo). |
| `--dest-album "Name"` | Put every copy in one flat album instead of the month workspace. |
| `--max-download-gb` | Ceiling on what may be pulled from iCloud in a run. Default 5 GB; `0` refuses downloads entirely. |
| `--import-via-applescript` | Import through Photos.app so the copies appear under Collections › Imports. See [TECHNICAL.md](TECHNICAL.md#two-import-routes). |

`aplc --help` and `aplc <command> --help` document the rest.

## Where your files go

Encoded files live in a temporary directory that is removed when the run ends,
whichever way it ends. There is nothing to clean up.

The one exception is the journal:

```
~/Library/Application Support/aplc/aplc_ledger.jsonl
```

Every run appends to it — what was converted, at what quality, to what fidelity,
and which new asset each conversion became. **The journal records; the library
decides.** It is never trusted as the authority on what is converted: every claim
is checked against your library first. Delete a copy you made and the tool will
offer that photo again, which is the right answer.

## Known limitations

- **Conversion is slow, and the ceiling is the encoder.** It uses most of your
  cores for one photo but cannot be run twice at the same time, so converting
  photos in parallel is worth about 1.5× and raising `--jobs` past the default
  adds very little. The remaining cost is the number of encodes each photo needs
  to find its quality — measured at 2.9 on average across 2,000 photographs, and
  between 2.8 and 3.1 in every month of them — and `--quality` skips that search
  entirely when time matters more than bytes. See
  [TECHNICAL.md](TECHNICAL.md#several-photos-at-once) for the measurements.
- **A long run will thermally throttle**, and there is nothing the tool can do
  about it: encoding is the one thing that keeps every core busy. On a six-core
  Intel iMac a multi-hour run held 75–80% of maximum clock throughout. Budget
  from a long run rather than a short one.
- **It has only ever been run against a library whose originals are all on local
  disk.** If your library is set to **"Optimise Mac Storage"**, most originals
  live in iCloud and each one has to come down before it can be re-encoded. That
  path exists and is metered — `--max-download-gb` caps a run, default 5 GB, and
  `0` refuses downloads outright — but it has never been exercised at scale, so
  treat it as the least proven part of the tool. Two things to expect if you try
  it: the run will be bound by your connection rather than by your CPU, so none
  of the timings above apply; and downloading an original does not change what
  the tool then does with it. Convert one small month first and check the
  `downloaded from iCloud` line in the transcode summary against what you
  expected.
- **`verify` re-checks structure and hashes**, and does not re-export originals to
  recompute fidelity from scratch.
- **Photos only.** In a library that holds much video, transcoding H.264 to HEVC
  would usually reclaim more space than anything this tool does. It is not
  implemented, and it is a considerably harder problem.

## Disclaimer

> **Use this at your own risk.**
>
> This tool was *written* to be incapable of destroying anything, and that
> property is enforced by tests you can run. That is not the same as a guarantee
> that nothing can go wrong. A bug, an untested version of macOS, an interrupted
> run, an iCloud sync landing at the wrong moment, or a mistake of your own at
> the deletion step can each end in **irreversible damage to your photo
> library**.
>
> The step that actually reclaims space is a **deletion you perform yourself**,
> entirely outside this tool's control — and if the photos are in a Shared
> Library, it removes them for the other participants too.
>
> **Have a backup, and know that it restores, before you start.** iCloud Photos
> is synchronisation, not backup: a deletion propagates to every device.
>
> **The author accepts no liability for any loss or damage**, to your photo
> library or to anything else, arising from the use of this software. This is
> what the MIT licence already says in legal terms; it is stated here in plain
> language so that nobody has to go and read it.
>
> Try a small `--limit` first, and check the results in Photos.app before
> converting a whole month.

## Tests

```sh
swift test
```

194 tests, no photo library and no permissions required: the gate is tested as
pure functions, the encoding path against synthetic images, and the generated
AppleScript is compiled without being executed. `SafetyInvariantTests` is the one
that matters most — see [TECHNICAL.md](TECHNICAL.md#the-safety-model).

## Licence

MIT. See [LICENSE](LICENSE) — including its disclaimer of warranty and
liability, which is the legal form of the section above.
