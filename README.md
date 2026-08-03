# ApplePhotoLibraryCompressor (`aplc`)

An open-source macOS CLI that converts JPEG originals in the Photos library to
HEIC, built so that it **cannot destroy anything**: it only ever *creates*
assets, never deletes or modifies existing ones.

Proof of concept. Read the safety model below before pointing it at anything you
care about.

## Why this exists

Tools that promise this are typically iOS-only and closed-source, which is a poor
combination for something that rewrites an irreplaceable photo library. This one
is auditable, and its safety properties are enforced by tests rather than by
promises.

## What macOS actually allows

Three constraints shape the entire design. All three were verified against the
SDK and the running system, not assumed:

1. **PhotoKit cannot replace an asset's original.** `PHAssetChangeRequest`
   exposes only `creationDate`, `location`, `favorite`, `hidden` and
   `contentEditingOutput`. That last one writes a *derived rendition* while
   keeping the original — which is why `revertAssetContentToOriginal` exists, and
   why using it would make the library **grow**. The only way to reclaim space is
   create-new + delete-old.

2. **AVIF cannot be written.** `CGImageDestinationCopyTypeIdentifiers()` does not
   list `public.avif`; `CGImageSourceCopyTypeIdentifiers()` does. macOS reads
   AVIF but has no encoder for it. HEIC is the only modern option without
   bundling a third-party encoder.

3. **Only the System Photo Library is reachable.** `PHPhotoLibrary` has no
   URL-based initialiser. Isolation therefore has to come from restricting work
   to a named album, not from pointing the tool at a scratch library.

## The safety model

`aplc` deliberately stops one step short of reclaiming space: it adds converted
copies and leaves deletion to you, in Photos.app.

- **`PHAssetChangeRequest.deleteAssets` does not appear in the source.** Neither
  does `contentEditingOutput` or `revertAssetContentToOriginal`.
  `SafetyInvariantTests` greps the sources on every test run to keep it so.
- **Your library grows before it shrinks.** Converted copies are added alongside
  the originals. With iCloud Photos on, they are also uploaded.
- **Every conversion must pass a gate** — anything questionable is skipped with a
  recorded reason, never converted approximately.
- **Two commands can write, and both refuse to start if `verify` reports a
  problem.** `apply` is a dry run unless you pass `--confirm`; `convert`, the
  one-shot pipeline, treats being invoked as the confirmation and takes
  `--dry-run` instead. Both are idempotent via the ledger, and neither can do
  anything but add.
- **Everything is journalled** to an append-only, `fsync`ed JSONL ledger before
  any library write.

### The gate

An asset is converted only if it passes all of these. Checks 4–8 are
post-conditions, re-read off the HEIC that was actually written — the encoder is
never taken at its word.

| Check | Rejects |
|---|---|
| Original resource is `public.jpeg` | anything else |
| `hasAdjustments == false`, no adjustment-base resource | edited photos, whose edit history cannot be carried over |
| Not a Live Photo or burst member | assets whose paired resources would be lost |
| Gain map preserved | HDR photos that would lose their gain map |
| EXIF / GPS / TIFF / ICC profile preserved | any metadata loss |
| Pixel dimensions unchanged | any geometry change |
| HEIC ≤ 90% of the JPEG | conversions that do not pay for themselves |
| SSIM ≥ `--min-ssim` | visually degraded conversions |

The last one is also what the quality search targets, so in automatic mode it is
satisfied by construction. It stays in the gate regardless, because `verify`
re-runs these checks later against files it did not encode.

### Metadata carried across

PhotoKit exposes exactly five writable properties on an asset — `creationDate`,
`location`, `favorite`, `hidden`, `contentEditingOutput` — so it alone cannot
carry text metadata. Photos.app's scripting interface can: its dictionary marks
`keywords`, `name` (title) and `description` (caption) as read-write on
`media item`, and maps `id` to the same `localIdentifier` the ledger records.

So **keywords, title and caption are transferred**, then read back to confirm
they stuck. Keywords are additionally embedded in the HEIC as IPTC, which keeps
them with the file outside Photos.

> One subtlety worth knowing: originals in a real library carry **stale** XMP
> `dc:subject` from old export cycles that disagrees with what Photos holds. aplc
> therefore always writes the authoritative keyword set, including an empty one,
> so old tags cannot come back from the dead.

### What still cannot be carried over

**People assignments.** No supported route exists: PhotoKit has no API, and
Photos' AppleScript dictionary has no person or face class at all. In practice
this matters less than it sounds — Photos assigns faces by recognition rather
than by hand, so the same face in the converted copy is re-assigned on its own
once analysis runs. (On the library this was developed against, only eighteen
face-to-person links out of many thousands had been made by hand — everything
else came from recognition, and recognition is exactly what runs again on the
copy.)

This has been confirmed in the field on converted HEICs, with one caveat worth
knowing: `photoanalysisd` only works while the Mac is **idle**, so recognition
does not happen at import time. Checked too early, a converted copy shows no
detected faces at all and looks like a failure; left idle for a while, the people
appear. Judge it after some idle time, not immediately after `apply`.

**iCloud Shared Photo Library membership.** A converted copy is always created in
your **personal** library, even when the original was in the shared one. Measured
on the library this was developed against: 6 of 6 copies came out personal while
all their originals were shared.

There is no supported way to set it. The public headers expose nothing,
`PHAssetCreationRequest` has no scope setter, and Photos' AppleScript dictionary
does not know the concept. Private API does exist — `PHLibraryScopeChangeRequest`
— and `aplc` deliberately does not use it, because the same class also exposes
`trashLibraryScopes:` and `expungeLibraryScopes:`, which act on an *entire* shared
library and so would reach the other participants' photos. Those symbols are in
`SafetyInvariantTests`' forbidden list, so the choice is enforced rather than
merely intended.

> This matters most at deletion time, which is the step `aplc` leaves to you:
> deleting a shared original removes it **for everyone it was shared with**, while
> your converted copy remains personal. If the originals are shared, move the
> copies into the Shared Library in Photos.app *before* deleting anything.

**Edit history** and the original **date added** are likewise not transferable,
and assets with edits are refused by the gate for exactly that reason.

## Requirements

macOS 14+, Swift 6. Built against the macOS 26 SDK but deliberately targeting
macOS 14, so that macOS 26-only APIs (`PHAsset.contentType`, `addedDate`,
`PHAssetResourceCreationOptions.contentType`) fail to compile rather than
crashing at runtime on macOS 15.

## Install

```sh
swift build -c release          # always use release: SSIM is compute-heavy
cp .build/release/aplc /usr/local/bin/
```

The executable embeds an `Info.plist` in its `__TEXT` segment via linker flags.
Without it, TCC finds no usage description and kills the process on first access.
Consent is attributed to the **terminal** running it, and two separate grants are
needed:

- System Settings → Privacy & Security → **Photos** — to read and add assets.
- System Settings → Privacy & Security → **Automation** → your terminal →
  **Photos** — to carry keywords, title and caption across.

Only the first is required. Without the second, conversion proceeds and says so,
and the ledger still records what each new asset was meant to carry.

## Use

Create an album in Photos.app holding the photos you want to convert, then either
run the whole pipeline at once:

```sh
aplc convert --album "My Album" --out ./staging --dest-album "Converted" --dry-run
aplc convert --album "My Album" --out ./staging --dest-album "Converted" --limit 3
```

or drive it a step at a time, which is the same work with a pause after each:

```sh
aplc scan      --album "My Album"
aplc calibrate --album "My Album" --out ./staging
aplc transcode --album "My Album" --out ./staging   # no --quality: chosen per photo
aplc verify    --out ./staging
aplc apply     --album "My Album" --out ./staging --dest-album "Converted"   # dry run
aplc apply     --album "My Album" --out ./staging --dest-album "Converted" --confirm --limit 3
```

`convert` runs scan → transcode → verify → apply and stops before writing if the
album holds nothing convertible, if the gate rejected everything, or if `verify`
finds a problem. It is safe to re-run: transcoding resumes where it left off and
nothing is imported twice.

**`convert` writes without asking**, unlike `apply`. The flag exists to separate
exploring from intending, and `convert` is the intending — you type it because
you want the copies, and by the time it writes you have already spent the
transcoding time. `--dry-run` is how you hold it back. Either way nothing is ever
deleted: the worst case is copies in `--dest-album` that you remove by hand.

Two steps stay manual, in Photos.app, in this order:

1. If the originals were in the **iCloud Shared Photo Library**, select the new
   copies and move them there — they are created in your personal library. See
   [What still cannot be carried over](#what-still-cannot-be-carried-over).
2. Only then delete the JPEG originals, if you decide to.

Doing them the other way round removes the originals for everyone they were shared
with while leaving your copies personal.

`calibrate` also works on plain files, needing no library access at all:

```sh
aplc calibrate --out ./staging --files photo1.jpg photo2.jpg
```

### Quality is chosen per photo, by `transcode`

This happens in the **`aplc transcode`** step — the third line above, or step 2
of `convert`. `--quality` is optional there, and *omitting it is what asks for
the search*: each photo then gets the **cheapest encoder setting that still
reaches `--min-ssim`** (default 0.97), found by encoding it and measuring, not by
guessing.

This inverts the usual arrangement. Normally you pick a quality up front and SSIM
is a veto applied afterwards, which throws the work away when it fails and
silently overpays when it succeeds by a wide margin. Here SSIM is the objective
and quality is only the means, so what you state is the thing you actually care
about: *this much fidelity, at the smallest size that delivers it*.

The search is possible because Apple's encoder is not continuous. Measured by
encoding one image at every hundredth from 0.40 to 1.00 and hashing the results,
61 values collapse to **26 distinct files** — and two images of different size,
aspect and content produced identical boundaries, so the quantisation belongs to
the encoder, not the picture. `aplc` therefore searches a ladder of 20 real
rungs rather than a continuum, bisecting it and starting from the rung the
previous photos in the album needed. Typically **two to three encodes per photo**.

Consequences worth knowing:

- **Values between rungs round down.** `--quality 0.85` encodes exactly as 0.79
  does; `transcode` reports the rung it really used, not the number you typed.
- **Above roughly 0.95 the HEIC becomes larger than the JPEG** — at quality 1.0
  more than twice the size — so the ladder stops below that. The gate would
  reject those as `insufficientSaving` anyway.
- **A photo no rung can satisfy is skipped**, exactly as before. The difference
  is that the skip now means *no quality would have worked*, not *the one you
  chose did not*.

On one set of photographs, targeting SSIM 0.97 against a fixed `--quality 0.8`:

| | saved | SSIM range |
|---|---|---|
| fixed 0.80 | 77.1% | 0.9735 – 0.9805 |
| automatic, target 0.97 | **82.6%** | 0.9703 – 0.9735 |

The fixed setting was overshooting the bar it had been given, and paying for it
in bytes. Where both happened to pick the same rung, they produced the identical
file.

Passing `--quality` explicitly still works and is the way to reproduce an old
run. Either way, use `calibrate` and **look at the files**: a target that reads
well as a number can still be visibly wrong on your own photographs, and SSIM
does not know what the picture is of.

### iCloud

`--max-download-gb` caps what may be pulled from iCloud in a run (default 5 GB;
`0` refuses downloads entirely). Originals already on disk are always used
without touching the network — the export path tries offline first and only then
considers the network, so a run cannot quietly pull down hundreds of gigabytes.

## Layout

```
Sources/APLCCore/          testable core
  ImageProbe.swift         structural + metadata facts about an image file
  Transcoder.swift         JPEG -> HEIC preserving metadata and gain map
  QualityMetrics.swift     SSIM and PSNR, strip-processed to bound memory
  QualitySearch.swift      the encoder's real quality rungs, and the search
  EligibilityGate.swift    the eight checks, as pure functions
  Ledger.swift             append-only journal, SHA-256 digests
  PhotoLibraryAccess.swift authorisation, album lookup, metered export
  PhotosScripting.swift    Apple Events for keywords, title and caption
  Importer.swift           the only code that writes assets to the library
Sources/aplc/              CLI subcommands
Tests/APLCCoreTests/       73 tests, no photo library required
```

## Tests

```sh
swift test
```

Runs without a photo library: the gate is tested as pure functions, and the
transcode path against synthetic JPEGs. The generated AppleScript is checked for
escaping (quotes, backslashes, newlines in captions) and compiled with
`osacompile`, which resolves terminology without executing anything.

`SafetyInvariantTests` is the one that matters most. It fails the build if a
destructive PhotoKit call appears in the sources, and — since Apple Events are a
second route into the library — if a generated script ever uses a destructive
verb or assigns anything beyond the three permitted properties. Its forbidden list
also covers the private shared-library API, whose reach extends past your own
photos to those of everyone you share with.

## Known limitations

- Sequential; no parallelism across assets yet. SSIM at full resolution costs
  roughly 1–2 s per photo, and the quality search spends two or three of those
  per photo instead of one. Passing `--quality` explicitly skips the search when
  the time matters more than the bytes.
- `verify` re-checks structure and hashes from the ledger. It does not re-export
  originals to recompute SSIM from scratch.
- **Photos only.** In a library that holds much video, transcoding H.264 to HEVC
  would usually reclaim more space than anything this tool does. That is not
  implemented, and it is a considerably harder problem: video has no equivalent of
  SSIM-per-frame cheap enough to gate on, and Live Photos complicate the asset
  model further.

## Licence

MIT. See [LICENSE](LICENSE).
