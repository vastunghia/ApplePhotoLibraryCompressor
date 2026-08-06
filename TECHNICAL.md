# How `aplc` works, and why

The design record for [ApplePhotoLibraryCompressor](README.md): what the platform
allows, what the tool refuses to do, and which claims were measured rather than
assumed. If you are deciding whether to run this on your own library, this is the
file to read.

Everything below was verified on **macOS 15.7** with the **macOS 26.2 SDK**.

## What macOS actually allows

Two constraints shape the whole design.

**PhotoKit cannot replace an asset's original.** `PHAssetChangeRequest` exposes
exactly five writable properties — `creationDate`, `location`, `favorite`,
`hidden` and `contentEditingOutput`. The last one writes a *derived rendition*
while keeping the original, which is why `revertAssetContentToOriginal` exists,
and why using it would make the library **grow**. The only way to reclaim space
is create-new, then delete-old.

**Only the System Photo Library is reachable.** `PHPhotoLibrary` has no
URL-based initialiser, so there is no way to point the tool at a scratch library.
Isolation therefore comes from restricting work to one album or one month.

## The safety model

`aplc` deliberately stops one step short of reclaiming space: it adds converted
copies and leaves deletion to you, in Photos.app.

- **The destructive calls are absent from `Sources/`, and a test keeps them
  absent.** `SafetyInvariantTests` greps the sources on every run and enforces
  three rules:
  1. No destructive PhotoKit calls anywhere — `deleteAssets`, `removeAssets`,
     `contentEditingOutput`, `revertAssetContentToOriginal`,
     `deleteAssetCollections`, and the collection-list equivalents
     (`deleteCollectionLists`, `removeChildCollections`,
     `replaceChildCollectionsAtIndexes`, `moveChildCollectionsAtIndexes`).
  2. Generated AppleScript may only `set` a `media item`'s keywords, name and
     description, and may contain no destructive verb. The single exception is
     `import`, allowed in one function and nowhere else; `delete`, `remove`,
     `duplicate`, `move` and `export` stay banned.
  3. No shared-library private API — `PHLibraryScopeChangeRequest`,
     `trashLibraryScopes`, `expungeLibraryScopes`. See
     [iCloud Shared Photo Library membership](#what-cannot-be-carried-over).
- **One file writes to the library.** `Importer.swift` creates assets, albums and
  folders, and puts things into them. It can do nothing else.
- **Album membership is one-way, and that is the accepted cost of rule 1.**
  Taking a photo out of an album needs `removeAssets`, which is banned — so the
  tool can fill an album and never unfill it. The alternative was to allow a call
  that could equally strip an album you built by hand. The same trade applies one
  level up to the workspace folders.
- **Every conversion must pass the gate** (below) or it is skipped with a
  recorded reason. Nothing is ever converted approximately.
- **Two commands can create assets, and both refuse to start if `verify` reports
  a problem.** `apply` is a dry run unless you pass `--confirm`; `convert` treats
  being invoked as the confirmation and takes `--dry-run` instead. Both are
  idempotent against the *library*, not merely against their own journal.
- **In month mode every command writes album membership**, putting existing
  photos into `Selected Originals`. That touches no photo and loses nothing, but
  it does mean `scan` and `calibrate` are not read-only with `--year`/`--month`.
  `--album` is the form that writes nothing at all.
- **Everything is journalled** to an append-only, `fsync`ed JSONL ledger before
  any library write, at
  `~/Library/Application Support/aplc/aplc_ledger.jsonl`. It is read leniently: a
  line left half-written by a hard stop is skipped and counted, never allowed to
  make the file unreadable.
- **The journal records; the library decides.** Every entry names the asset it
  created, and that claim is checked against the library before it is allowed to
  stop any work. Delete every copy you have made and the tool offers them all
  again — which is the right answer, and is why the journal is not consulted as
  an authority.

### The gate

A photo is converted only if it passes all of these. Checks 4–8 are
post-conditions, re-read off the HEIC that was actually written: the encoder is
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

The last is also what the quality search targets, so in automatic mode it is
satisfied by construction. It stays in the gate regardless, because `verify`
re-runs these checks against files it did not encode.

## Metadata

### What is carried across

PhotoKit's five writable properties cannot carry text metadata. Photos.app's
scripting interface can: its dictionary marks `keywords`, `name` (title) and
`description` (caption) as read-write on `media item`, and maps `id` to the same
`localIdentifier` PhotoKit uses.

So **keywords, title and caption are transferred**, then read back to confirm
they stuck. Anything that did not is reported rather than passed over, and the
ledger records what each new asset was meant to carry. Keywords are additionally
embedded in the HEIC as IPTC, which keeps them with the file outside Photos.

> Originals in a real library carry **stale** XMP `dc:subject` from old export
> cycles that disagrees with what Photos holds. `aplc` therefore always writes the
> authoritative keyword set, including an empty one, so old tags cannot come back
> from the dead.

This path needs the optional Automation consent. Without it, conversion proceeds
and says so.

### What cannot be carried over

**People assignments.** No supported route exists: PhotoKit has no API, and
Photos' AppleScript dictionary has no person or face class at all. In practice
this matters less than it sounds, because Photos assigns faces by recognition
rather than by hand, and recognition is exactly what runs again on the copy. This
has been confirmed in the field on converted HEICs, with one operational catch:
`photoanalysisd` only works while the Mac is **idle**, so nothing happens at
import time. Judge it after some idle time, not immediately.

**iCloud Shared Photo Library membership.** A converted copy is always created in
your **personal** library, even when the original was shared — measured, with
every original shared and every copy personal.

There is no supported way to set it. The public headers expose nothing,
`PHAssetCreationRequest` has no scope setter, and Photos' AppleScript dictionary
does not know the concept. Private API does exist — `PHLibraryScopeChangeRequest`
— and `aplc` deliberately does not use it, because the same class also exposes
`trashLibraryScopes:` and `expungeLibraryScopes:`, which act on an *entire*
shared library and so reach photos belonging to the other participants, which
they cannot restore. Those symbols are on `SafetyInvariantTests`' forbidden list,
so the choice is enforced rather than merely intended.

> This matters most at deletion time, which is the step `aplc` leaves to you:
> deleting a shared original removes it **for everyone it was shared with**, while
> your converted copy remains personal. Move the copies into the Shared Library in
> Photos.app *before* deleting anything.

**Edit history** and the original **date added** are likewise not transferable,
and photos with edits are refused by the gate for exactly that reason.

## Quality is chosen per photo

`--quality` is optional, and *omitting it is what asks for the search*: each
photo gets the cheapest encoder setting that still reaches `--min-ssim` (default
0.97), found by encoding it and measuring, not by guessing.

This inverts the usual arrangement. Normally you pick a quality up front and SSIM
is a veto applied afterwards, which throws the work away when it fails and
silently overpays when it succeeds by a wide margin. Here SSIM is the objective
and quality is only the means, so what you state is the thing you actually care
about: *this much fidelity, at the smallest size that delivers it*.

The search is possible because Apple's encoder is not continuous. Measured by
encoding one image at every hundredth from 0.40 to 1.00 and hashing the results,
61 values collapse to **26 distinct files** — and two images of different size,
aspect and content produced identical boundaries, so the quantisation belongs to
the encoder, not to the picture. `aplc` therefore searches a ladder of 20 real
rungs rather than a continuum, bisecting it and starting from the rung the
previous photos needed. Typically **two to three encodes per photo**.

Consequences:

- **Values between rungs round down.** `--quality 0.85` encodes exactly as 0.79
  does; the tool reports the rung it really used, not the number you typed.
- **Above roughly 0.95 the HEIC becomes larger than the JPEG** — at quality 1.0,
  more than twice the size — so the ladder stops below that.
- **A photo no rung can satisfy is skipped**, and the skip means *no quality
  would have worked*, not *the one you chose did not*.

Passing `--quality` explicitly still works and is the way to reproduce an old
run. Either way, use `calibrate` and **look at the files**: a target that reads
well as a number can still be visibly wrong on your own photographs, and SSIM
does not know what the picture is of.

## How the tool knows what is already converted

A library too large to convert in one go has to be worked through in pieces, and
the hard part is remembering where you stopped. `aplc` answers that from the
**library itself** rather than from any record it keeps: a JPEG counts as
converted when a HEIC exists with the same **filename stem** and the same
**creation second**. `apply` gives every new copy both, which is what makes the
pair findable later.

Three consequences:

- The answer survives everything done to the tool's own files — a deleted staging
  directory, a moved journal, copies moved into a Shared Library, or a conversion
  made before you installed the tool.
- It is load-bearing far from where it is written: it breaks the moment `apply`
  stops carrying the date, or stops deriving the HEIC name from the JPEG stem.
- The failure is **deliberately asymmetric**. A camera that saved the same shot
  as both a JPEG and a HEIC produces a genuine pair — same stem, same second —
  that this rule cannot distinguish from a conversion. Measured on a real
  library: of seven pairs found, one was such a photo, years older than the tool.
  The cost is a saving not taken, never a photo at risk. Anything that invites
  deletion uses a stricter test than the pairing alone.

Photos that reach you through an iCloud **Shared Album** are never offered, and
should not be: what a shared album holds is a downscaled copy belonging to
whoever posted it, not an original of yours to re-encode. A default
`PHFetchOptions` excludes them, which is the behaviour we want. Assets in a
Shared *Library* are a different thing — those are full originals, and they are
included.

## Duplicates are refused at the door

`apply` will not import a second copy of a photo it already imported, even when
its own journal has been moved aside or started fresh. Before creating an asset
it looks for the pair described above, and if it finds one:

| What it finds | What it does |
|---|---|
| the same image, byte for byte | skips it, and says so |
| a different image | asks: `[y/N/a=all/q=quit]` |
| a copy it cannot read | asks, saying it could not compare |

The comparison is dimensions first, which is free, then SHA-256 against the
digest the ledger already holds. It is **strictly offline**: needing to compare
is not a reason to pull a photo down from iCloud, so an existing copy that is not
on disk becomes a question rather than a silent decision.

Comparing bytes works because two things are true, both measured: the encoder is
**deterministic** — the same photo at the same quality produces the same file, to
the byte — and `PHAssetCreationRequest` stores the resource **verbatim**, so the
copy in the library still hashes to what the ledger recorded.

Not importing is the default answer, because the two mistakes do not cost the
same: a skip is undone by running the command again, a second copy is undone by
hand. With no terminal attached — in a script, or a cron job — there is nobody to
ask, so the question becomes a skip and is reported as one.

## Two import routes

An asset created through `PHAssetCreationRequest` belongs to no import session:
Photos records that in `ZASSET.ZIMPORTSESSION`, and with nothing there the copy
never appears under **Collections › Other › Imports**. PhotoKit offers no way to
set it — not in the public headers, and not in the framework's symbol table.

`--import-via-applescript` asks Photos.app to import the file instead, through
the `import` command in its scripting dictionary. Measured on a real library:

| | default (PhotoKit) | `--import-via-applescript` |
|---|---|---|
| **Under Imports** | no | **yes**, as one entry per run |
| In a Shared Library | no | no — unchanged |
| Filename | preserved | preserved, Photos does not rename |
| Capture date | exact | exact |

**That first row is the whole of the difference.** If the line you are missing
says *"Added to library by <a person's name>"*, that is Shared Library
membership, and **neither route sets it**; moving the copies in Photos.app is
still the only way.

The whole run is handed over in **one** `import` call, so a month's conversion
reads as a single import event. That is not a performance detail: one call is one
session, so importing photo by photo would fill the Imports view with a
single-photo entry per conversion — worse than leaving it alone. Results are
matched back to inputs by filename, never by position, since nothing in the
reply promises an order.

It is off by default. It makes the optional Automation consent mandatory, and it
hands Photos the reading of the filename, which the default route sets itself.

## iCloud

`--max-download-gb` caps what may be pulled from iCloud in a run (default 5 GB;
`0` refuses downloads entirely). Originals already on disk are always used
without touching the network — the export path tries offline first and only then
considers the network, so a run cannot quietly pull down hundreds of gigabytes.

## Build notes

The executable embeds an `Info.plist` in its `__TEXT` segment via linker flags.
Without it, TCC finds no usage description and kills the process on first access.
Consent is attributed to the terminal application that runs it.

The deployment target is **macOS 14**, not the SDK's 26, on purpose: anything
marked `API_AVAILABLE(macos(26.0))` — `PHAsset.contentType`, `PHAsset.addedDate`,
`PHAssetResourceCreationOptions.contentType` — then fails to compile rather than
crashing at runtime on an older system.

```
Sources/APLCCore/          testable core, no CLI
  ImageProbe.swift         structural + metadata facts about an image file
  Transcoder.swift         JPEG → HEIC preserving metadata and gain map
  QualityMetrics.swift     SSIM and PSNR, strip-processed to bound memory
  QualitySearch.swift      the encoder's real quality rungs, and the search
  CandidateSelection.swift what a month still has left to convert
  DuplicateCheck.swift     whether a staged file is already in the library
  WorkspaceLayout.swift    the folder and album names, in one place
  EligibilityGate.swift    the eight checks, as pure functions
  Ledger.swift             append-only journal, SHA-256 digests
  StagingArea.swift        the temporary directory and its lifetime
  PhotoLibraryAccess.swift authorisation, album and folder lookup, metered export
  PhotosScripting.swift    Apple Events for keywords, title and caption
  Importer.swift           the only code that writes to the library
Sources/aplc/              CLI subcommands
Tests/APLCCoreTests/       132 tests, no photo library required
```

`swift test` runs without a photo library: the gate is tested as pure functions,
the transcode path against synthetic JPEGs, and the generated AppleScript is
checked for escaping (quotes, backslashes, newlines in captions) then compiled
with `osacompile`, which resolves terminology without executing anything.
