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
  level up to the workspace folders, and to their *order*: a new album is
  inserted at the position it should occupy, because the call that would move one
  afterwards is banned too. Folders built before an order existed keep theirs.
- **Every conversion must pass the gate** (below) or it is skipped with a
  recorded reason. Nothing is ever converted approximately.
- **Two commands can create assets, and both refuse to start if `verify` reports
  a problem.** `apply` is a dry run unless you pass `--confirm`; `convert` treats
  being invoked as the confirmation and takes `--dry-run` instead. Both are
  idempotent against the *library*, not merely against their own journal.
- **In month mode every command writes album membership**, putting existing
  photos into `Selected Originals`. That touches no photo and loses nothing, but
  it does mean `scan` and `calibrate` are not read-only with `--year`/`--month`
  — nor with a bare `--year`, which is twelve months of the same.
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

Membership can at least be *read*, and `apply` reads it so the manual step becomes
a select-all: the copies whose original was shared go into `Compressed Copies - to
Share`. There is no public API for that either — the SDK's Photos headers contain
no occurrence of `Scope`, and the scripting dictionary none — so this uses one
non-public property, `PHAsset.participatesInLibraryScope`, reached through the
Objective-C runtime and behind a `responds(to:)` check. It is a **read**: a test
asserts the file containing it names no change request of any kind, and the three
destructive scope calls above stay banned. If a future macOS withdraws the
property the answer becomes "unknown", and an unknown copy is left out of the
album and counted in the report rather than guessed into it.

The alternatives were weighed and rejected. Putting *every* copy in the album
needs no private API but invites moving personal photos into a shared library,
which publishes them to other people. Reading `ZASSET.ZLIBRARYSCOPE` from the
library's SQLite store is not private API, but needs a bundle path PhotoKit does
not expose, Full Disk Access, and a read of a write-ahead log Photos holds open —
more fragile, not less.

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
rungs rather than a continuum.

Two caveats on that, and they matter more the further you are from the machine it
was measured on. It was one ImageIO, on one Intel Mac; and the conclusion that
the boundaries belong to the encoder rests on two *images* agreeing, never on two
*encoders* agreeing. Another implementation — Apple Silicon's, a future macOS —
could quantise somewhere else entirely. Correctness does not depend on this:
every rung the search accepts has been measured against your target, whatever the
ladder claims. Efficiency does. **The ladder is the one part of this tool that is
calibration rather than logic**, and it is the thing most worth re-measuring on
new hardware.

At scale the ladder turned out to be well placed for the work. Across 1,997 real
conversions the chosen rungs clustered in the middle — 0.76 and 0.79 together
took a third of all photos — while both ends were barely used: 2.5% settled on
the bottom rung 0.40, and 0.2% went above 0.88. So the floor is mildly binding,
in that some of those photos still had SSIM to spare and might have passed lower
still; but they are by definition the *easy* photographs and therefore already
small, and all of them together are **0.88% of the bytes produced**. Extending
the ladder downwards would buy close to nothing.

### The search interpolates rather than bisecting

Every probe measures an SSIM, and bisection would reduce that number to a single
bit — did it clear the target? — and throw the rest away. That is wasteful,
because the value says *how far* off the rung was, not merely which side of the
line it fell on.

Measured on eight photographs across the whole ladder: every curve was monotone,
and in `log(1 − SSIM)` — distortion, which decays roughly exponentially — each
was nearly a straight line, r² between 0.90 and 0.999. So one probe supports an
extrapolation to where the curve crosses the target, and two support a secant
that corrects it with the photograph's own slope.

The result on a real month: **2.9 encodes per photo against 3.9**, reaching
exactly the same qualities and the same SSIMs. It then held at scale — over a
full year of 1,997 photographs across twelve months and several cameras the
average was **2.96, with no month outside 2.8–3.1**. The slope and the method
were derived from eight curves belonging to a single month; that they generalised
without one month drifting is the part worth trusting, more than the number.

The same run shows the search is not overshooting, which is where the saving
actually comes from. Against a target of 0.97, accepted encodes averaged **SSIM
0.9724**; 12% of photographs landed within 0.0005 of the bar and the highest sat
at 0.9858. Exactly one photograph in 1,998 could not be satisfied by any rung and
was skipped rather than degraded — at the top of the ladder it still measured
0.9632.

Two things about the method are worth stating plainly:

- **It is interpolation, not prediction.** Nothing is learned, nothing is stored
  between photos, and there is no model of your library. The one global constant
  — the average slope — is used only for the first jump, and only ever decides
  *where to look*, never what to accept.
- **A statistical predictor was tried and rejected.** The obvious one is the
  source JPEG's bytes per pixel, since an already-compressed file is smoother and
  cheaper to re-encode. Across 93 real conversions that correlates at r = 0.42:
  at 0.15 bytes per pixel the right rung ranged from 0 to 7. Not usable.

The guarantee is unchanged, and it is a measurement rather than an estimate: the
search stops only once it has measured a rung that passes *and* the rung below it
failing, so the answer is the same one an exhaustive scan would give.

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

## Several photos at once

The two halves of a probe use the machine in opposite ways, and that asymmetry
is the whole reason `transcode` converts more than one photo at a time.

Measured on 20–22 MP JPEGs on a six-core Intel machine, timing each phase against
the process's own CPU time to see how many cores it really occupied:

| phase | wall | cores used |
|---|---|---|
| encode to HEIC (ImageIO) | 1.2–1.5 s | **4.4–4.8** |
| measure fidelity (decode + SSIM) | 1.8–2.3 s | **1.00** |

The fidelity check is 60% of every probe and it is one core for all of it, because
the SSIM is ordinary scalar code. A sequential run therefore alternates between a
phase that fills the machine and a phase that leaves five sixths of it idle.

### The SSIM itself, and what exactness costs

The mean SSIM is a separable box blur over five planes, and the blur used to
finish one column before starting the next — reading every value `width` floats
from the last, so each read was its own cache line and nothing vectorised.
Sliding a whole row of accumulators down the image instead is **2.6× on that
pass**, and computing the three product planes through `vDSP` rather than one
interleaved loop is **5.3× on that part**. Together, **1.37× on the whole
metric**.

Both rewrites are *exact*, not approximate: the SSIM they produce is identical to
the last digit, verified on real photographs and pinned by a test that
reconstructs the old column-at-a-time pass and demands equality. That mattered
more than the speed. A `Float` accumulator would have been about twice as fast
again, but the sliding sums run across thousands of elements and in single
precision the rounding drifts into the 1e-5 range — which would break the
guarantee that computing the SSIM in strips gives the same answer as computing it
whole. The striping is meant to be an exact decomposition, not an approximation,
so that trade was refused.

Two dead ends, recorded so nobody pays for them twice: `vDSP_conv` is the wrong
tool for a box blur and measured **34% slower** than the scalar sliding sum,
which is already O(1) per pixel whatever the radius; and folding the two updates
into `sum += entering - leaving` breaks the bit-identity, because floating-point
addition is not associative.

**A 1.37× metric is not a 1.37× run**, and the gap is the interesting part. The
same twelve photos, the two versions measured back to back:

| | before | after | |
|---|---|---|---|
| `--jobs 1` | 112.6 s | 101.4 s | 1.11× |
| `--jobs 3` | 77.1 s | 74.5 s | **1.03×** |

Run one photo at a time and the fidelity check is on the critical path, so making
it faster shows. Run three at once and it is already hidden behind the encoder,
which cannot be shared — so the same improvement is worth almost nothing. The two
optimisations overlap: whichever is done second gets the smaller half.

What that leaves is a single bottleneck to aim at. The encoder is serial and
every probe pays for one, so the remaining lever is **doing fewer encodes**, not
doing any of the work faster.

### The encoder does not parallelise, and cannot be made to

The obvious inference — run several encodes at once — is wrong, and it was worth
measuring before designing around it. Six encodes of the same image:

| | total | per encode |
|---|---|---|
| one after another | 7.98 s | 1.33 s |
| six at once, on six threads | 7.76 s | 1.29 s |

**No gain at all.** ImageIO's HEIC encode goes through VideoToolbox's tile
compression, which behaves as a single process-wide resource: concurrent callers
serialise inside it. Since one encode already spreads itself over most of the
cores, there is nothing left to win.

What does parallelise is the other 60%. Six fidelity checks at once took 4.12 s
against roughly 11 s one at a time. So the whole gain comes from measuring one
photo while another is encoding, and the encoder sets the floor.

Measured on a real month — the same twelve photos each time, on six cores:

| `--jobs` | wall | encodes per photo | |
|---|---|---|---|
| 1 | 113.0 s | 3.2 | |
| 3 | 76.7 s | 3.9 | **1.47×** |
| 6 | 88.1 s | 4.4 | 1.28× |

**More workers was not better, and the third column is why.** Each search starts
from the rung earlier photos needed; the more photos start at once, the more of
them start before anything has finished, and so start cold. At `--jobs 6` that
was 4.4 encodes per photo against 3.2 — nearly 40% more encoding — and encoding
is exactly the part that cannot be done in parallel.

That penalty no longer exists: the interpolating search barely depends on the
seed, and now costs 2.8, 2.9 and 2.9 encodes per photo at one, three and six
workers. Re-measured, the three settings finish within about 3% of each other,
which is noise. So `--jobs` is a flat curve now rather than a peak, and the
default of half the cores is kept because it reaches the flat part while leaving
the machine usable for anything else.

The general lesson survives the specific numbers: **a second worker helps only
while there is idle time to fill, and past that point extra workers can only add
work to the serial encoder.** Measure "encodes per photo" from the summary rather
than wall time — it is exact, and immune to whatever else the machine is doing.

### Blocking work does not go on the cooperative pool

A conversion may not run on a Swift concurrency task group's own threads. The
encode blocks inside `VTTileCompressionSessionEncodeTile` waiting on a semaphore,
and Swift's cooperative pool holds exactly one thread per core and will not grow
to replace a blocked one — so six concurrent encodes in a task group fill the
pool with blocked threads and **never return**. Measured; the run hangs, it does
not fail.

Two details of that finding were surprises, and both are load-bearing:

- Putting the encoder behind a lock does **not** fix it. The threads waiting for
  the lock are cooperative threads too, so the pool is just as full.
- The identical work on an ordinary GCD queue is fine, because that pool
  overcommits and replaces a blocked thread.

So the blocking half runs on a GCD queue and the cooperative threads only ever
await it. That is what `BlockingWork` is for, and anything added later that calls
ImageIO or VideoToolbox from more than one photo at a time has to go through it.

### What the parallelism does not change

- **The workers only compute.** Every library read happens first, in album order,
  so nothing running in parallel touches PhotoKit. Every journal write, printed
  line and running total belongs to the one task that collects results — which is
  why there is not a lock anywhere in it.
- **Results are reordered back into album order** before they are reported or
  journalled, so two runs of the same month stay comparable line by line and the
  journal reads as it always did. The cost is that one slow photo holds back the
  lines of the photos behind it.
- **The seed becomes timing-dependent.** Each search starts from the rung earlier
  photos needed, and which photos have finished depends on the machine. So the
  number of encodes per photo varies between runs, and in the rare non-monotonic
  case the chosen rung can differ by one. The guarantee does not move: the rung
  finally returned has always been measured against the target itself, so a
  different seed can cost a rung of saving and never fidelity.

## A year is a loop, not a wider net

`--year` without `--month` covers all twelve months, and it does so by running
each month in turn rather than by fetching a year at once. That distinction is
the whole design:

- **The unit of work stays the month.** Same `YYYY-MM` folder, same albums, same
  fetch bounded by one month's dates. A year of work is indistinguishable from
  twelve invocations, which is what makes it safe to interrupt: what has been
  done is already in the library, and the next run finds it there.
- **Staging is per month, and `convert` cleans up before starting the next.** So
  the peak on disk is one month's worth however long the run is. It also has to
  be that way: the journal is scoped to a run by staging path, so a shared
  directory would have December re-verifying January's files.
- **A failing month does not abort the year.** It is recorded, the run continues,
  and a summary at the end names every month and how it ended; the exit code is
  non-zero if any failed. An hour lost to one bad file should not cost the other
  eleven months.
- The expansion lives in exactly one place — the option group that resolves
  `--year`/`--month`/`--album` into scopes. Everything downstream still receives
  a single month and is unchanged by the year existing.

Measured on a full year: 1,998 photographs examined, 1,997 converted, one skipped
at the gate, no failures, and `verify` clean in all twelve months. **Encoding is
the whole cost at this scale too** — selecting, scanning, importing and verifying
twelve months together came to a rounding error against 166 minutes of
transcoding, which is the same conclusion reached at one month, now at a hundred
times the size. Per-month failure isolation was never needed, and remains the
kind of thing that has to exist before the run that needs it.

## The shape of the workspace, and the order of what is in it

The tree is `aplc workspace` > `2019` > `2019-07` > four albums. The year level
exists because the month level does not scale: a whole library is two hundred and
fifty sibling folders without it.

The four albums appear in the order you work through them — `Selected Originals`,
`Compressed Originals`, `Compressed Copies`, `Compressed Copies - to Share` —
rather than alphabetically, which would put them in an order matching nothing.

**Photos shows a folder's children in the order the collection holds them, and
takes no notice of their names.** Measured on 2026-08-09 against a real month with
all four albums present, and confirmed one level up for the month folders
themselves. It was worth measuring because the alternative is not exotic: had
Photos sorted by title, none of the machinery below would do anything visible.

Since Photos puts a newly created album at the end, the order can only be set as
the album is born: `Importer` works out the position from the folder's current
contents and **inserts** rather than appends. That is also the only chance there
is, because moving an album afterwards needs a call on the forbidden list — so a
month folder created before this order existed keeps the order it was built in,
and is rearranged by dragging in Photos.app or not at all.

Two smaller properties fall out of the same rule. An album you made yourself is
not in the list, so it ranks last and keeps its place: a workspace album is
inserted above it rather than shuffling anything you arranged. And the rule is a
pure function of album titles, so it is tested without a photo library like the
rest of the core.

The **folders** obey the same rule and get the same treatment, ranked by date
instead of by workflow: a month converted out of sequence is inserted in its
chronological place rather than appended, and so is a year. Their names are
zero-padded (`2026-02`) so that comparing them as text *is* comparing dates —
useful wherever the names are read, but not what orders the sidebar.

### Two layouts, accepted on purpose

A folder cannot be moved out of its parent — `PHCollection` has exactly one, and
the calls that would change it are forbidden. So month folders created before the
year level existed are **still directly under `aplc workspace`**, and no migration
the tool could run would fix that.

Rather than pretend otherwise, lookup accepts both: `aplc workspace > 2019 >
2019-07` first, then `aplc workspace > 2019-07`. Two consequences worth stating:

- **The search happens before anything is created.** Creating first would give one
  month two folders — an empty `2019` beside a working `2019-07` — and split its
  albums across both, permanently, since neither can be removed afterwards.
- **Dragging a folder into its year in Photos.app is a complete migration.** The
  nested lookup starts finding it, the fallback stops being consulted, and nothing
  had to be renamed, because the month keeps its full `YYYY-MM` name inside the
  year folder for exactly this reason.

Doing nothing is equally valid, and this is not a deprecation on a timer.

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
  WorkspaceLayout.swift    the folder and album names and their order, in one place
  LibraryScope.swift       reads shared-library membership, and only reads it
  EligibilityGate.swift    the eight checks, as pure functions
  Ledger.swift             append-only journal, SHA-256 digests
  StagingArea.swift        the temporary directory and its lifetime
  PhotoLibraryAccess.swift authorisation, album and folder lookup, metered export
  PhotosScripting.swift    Apple Events for keywords, title and caption
  Importer.swift           the only code that writes to the library
Sources/aplc/              CLI subcommands
Tests/APLCCoreTests/       179 tests, no photo library required
```

`swift test` runs without a photo library: the gate is tested as pure functions,
the transcode path against synthetic JPEGs, and the generated AppleScript is
checked for escaping (quotes, backslashes, newlines in captions) then compiled
with `osacompile`, which resolves terminology without executing anything.
