# UI and Workflow

## Principle

Lightroom is already an excellent image-review application. The plugin does not
reimplement it. A Lua dialog gives small fixed thumbnails, no zoom, no comparison, and
blocks the UI — the wrong tool for judging photographic intent. So review happens in the
**grid and Loupe at full size**, with the review fields in the **Metadata panel** and decisions
applied by **menu commands on the selection** (R6.2).

## Menu

The SDK allows only a title, a script and an enabled-when condition per item — no submenus,
no documented separators, and no right-click (context) menu at all — but offers three menus.
Daily work is in Library, set-up and reports in File, diagnostics in Help. The
dividers are greyed-out do-nothing items (`──────────`): Lightroom draws `-` as an ordinary
item, not a separator.

```
Library ▸ Plug-in Extras                 (greyed out without a selection)
  Classify Selected Photos
  Reclassify Selected Photos
  Pick Photos to Review…                 temporary: N picks, an equal share per suggested primary (GrPick)
  ──────────
  Remove Genre                           step 1: genres
  Add Genre…
  ──────────
  Set Primary Genre…                     step 2: primary
  Accept Suggestion
  ──────────
  Correct Genres…                        full control
  ──────────
  Suggest Ratings                        a rating round, separate from the genres (ADR-029)
  ──────────
  Suggest Keywords                       a keyword round (ADR-030): written at once, then vetted
  Mark Keywords Verified
  Re-suggest Keywords                    verified photographs, after a new model

File ▸ Plug-in Extras
  Set Up Review Collections
  Apply Approved Genres…
  Apply Keyword Judgements…
  Genre Quality Summary
  Export Report (CSV)
  ──────────
  Check Model
  ──────────
  Re-derive Personal Suggestions         the personalFloor setting, without the model
  Update Genre Keywords
  Remove Genre Keywords
  Clear Plugin Data

Help ▸ Plug-in Extras
  Show Genreator Diagnostics
```

Commands marked `…` open a dialog; the rest act on the selection and report a summary. Keeping decisions as plain commands means they are assignable to keyboard
shortcuts via the OS, which matters when working a few hundred photographs.

## The review loop

Before classifying, tag personal photographs with the Personal keyword (default `#PERSONAL`)
or a keyword under it (ADR-024) and, if you
like, apply the `Genre > X` keywords you already know (ADR-023): the Personal tag is the
model's one input besides the image; pre-tags join its suggestion.

Review is **by exception, in grids** (R6.8): a batch is too large to judge photo by photo, so
each grid shows one suggestion and you act only on the odd ones out. `Set Up Review
Collections` (File ▸ Plug-in Extras) creates the `Genreator` collection set and the
Personal keyword when missing; re-running it adds what is missing, repairs collection rules
and removes the plugin's own collections an earlier version made under other names.

Lightroom lists sub-sets before collections, each by name; the steps and their grids are
named for the order of the work (ADR-027):

```
Genreator/
  Step 1 · Genres/       1 Object … 8 Street                (taxonomy reversed)
  Step 2 · Primary/      1 Street … 8 Object, 9 No genre    (taxonomy order)
  Awaiting Review        every undecided suggestion; Accept here, once, at the end
  Errors
  Not Classified         where the next batch comes from
  Personal Candidates    personal photographs awaiting review that still have a genre
  Suggested Keywords/    1 Keywords to Verify, 2 Keyword Errors
  Suggested Rating/      1 Candidates for 3★, 2 Maybe 2★, 3 Maybe 1★, 4 Likely 0★
```

Within a step the order of the grids does not change how many commands the review takes; it
makes the judgements easier. Step 1 starts with the genres most often suggested wrongly
(Object, Architecture) and keeps those that pass for each other together. Step 2 follows the
order in which one genre wins over another when both apply — the taxonomy's — with No genre
as the last fallback.

**Personal photographs** are held to a higher bar (ADR-028): a genre is suggested on one only
when the model rates it at least its recommended floor as well as its cut-off, so most of them
come out as No genre and the ones left with a genre are real genre candidates. `Personal
Candidates` stages them — personal, awaiting review, with a genre under review — for a look of
their own. Review them like any other: a decision, or removing the last genre, takes a
photograph out, so the collection is empty when they are done. Each decision records that it
was on a personal photograph (`decisionPersonal`). Decided personal genre photographs are found
with a smart collection on *Classified as personal* and *Primary Genre*.

**Step 1 — genres** (`Step 1 · Genres`, R6.9). In each grid, in order, select the
photographs that do not belong and choose **Remove Genre** (inside a genre grid it removes
that genre with no dialog); where most are wrong, select all and deselect the right ones.
**Add Genre…** adds a missing one. These edit only the genres under review
(`reviewGenres` / `reviewGenre`); the photograph stays awaiting review and no keyword is
written. Removing the primary promotes the next genre in priority order (the model's
ranking); removing the last leaves No genre. An added genre takes its place in that order.
Most wrong primaries are put right this way: the right one is usually already in the
suggestion.

**Step 2 — primary** (`Step 2 · Primary`). In each grid, select the odd ones out and
choose **Set Primary Genre…** (each keeps its own other genres, R6.10; *No genre* clears them
— quicker than removing each genre in step 1). The photograph is decided at once and leaves
the grids.

**Last — accept** (`Awaiting Review`). When every grid has been through steps 1 and 2,
select all and **Accept Suggestion**, once: it writes the genres as edited in step 1.

Judge **the photograph**, not the suggestion. The Metadata panel shows the primary and
genres under review (ADR-020).

### The outcomes (R6.3)

| Command | Meaning | Keywords written | Recorded |
|---|---|---|---|
| **Accept Suggestion** | Right, with any step-1 edits | `Genre > …` for each genre; the primary and the other genres go to the Primary Genre / Secondary Genres fields. No genre: no keyword, Primary Genre = No genre | `accepted`, or `corrected` when edited |
| **Set Primary Genre…** | The primary is wrong; keep the rest | as above, with the chosen primary (or No genre) | `corrected` (or `accepted` if it equals the suggestion) |
| **Correct Genres…** | Full control: one primary + a genre list for the whole selection | as above | `corrected` / `accepted` |
| **Apply Approved Genres…** | Decisions you made elsewhere, in a file | as above, for each photograph the file names | `accepted`, source `approved` |

The reverts **Remove Genre Keywords** (keywords and the genre fields that copy them) and
**Clear Plugin Data** (the other fields) are in File ▸ Plug-in Extras. **Update Genre
Keywords** rewrites a selection's genre keywords and fields from its `Genre` keywords and
recorded primary, repairing hand edits; running it again changes nothing (ADR-019).
Reclassify never overrides a decision (R2.7).

**Quality Summary** (File ▸ Plug-in Extras) reads every decision in the catalog and counts,
per model version, how often the suggested primary and genre list were kept (R7.8).

## Filtering the library by genre

| You want | Library Filter ▸ Metadata | Smart collection rule |
|---|---|---|
| Street as the primary | **Primary Genre** column ▸ Street | Primary Genre *is* Street |
| No genre | **Primary Genre** column ▸ No genre | Primary Genre *is* No genre |
| Street in any role | **Keyword** column ▸ Genre ▸ Street | *match any*: Primary Genre is Street, Secondary Genres contains Street |
| Street, but not as the primary | — | Secondary Genres *contains* Street |
| Reviewed or not | **Review state** column | Review state |

The Keyword column is hierarchical, so it tells `Genre > Street` from other keywords named
Street. A smart collection's Keywords rule matches names only, which is why the primary and
secondaries are plugin fields (ADR-019). Photos under review are browsed in the `Genreator`
collections. The Metadata panel shows the review fields; the suggestion's provenance is in
the CSV report (ADR-020).

## Classification commands

**Classify Selected Photos** — skips video, offline originals without a Smart Preview, and already-classified
photographs (R6.5); retries photographs left in error. Confirms every run, saying how many
photographs are personal and how many have genre pre-tags. Shows a progress bar
with a working cancel.

**Reclassify Selected Photos** — same, but ignores existing state. Overwrites the model's
fields; never removes a keyword, and never overrides a decision.

**Re-derive Personal Suggestions** (File ▸ Plug-in Extras) — after changing `personalFloor`
in the config file, applies it to the selection's personal photographs awaiting review, from
the stored ranking: no rendering, no model call. Decided photographs, photographs that are not
personal, and rankings stored before the model had a floor (Reclassify those) are skipped
with the reason. A changed suggestion starts its review afresh.

**Suggest Ratings** (ADR-029) — the model's suggested rating, a separate action from
classifying: renders the selection (video and offline originals without a Smart Preview
skipped), runs the model, and writes only the rating fields — the *Suggested rating* bucket
(`0`–`3` under the `ratingRatio` setting), its ratio, the score, the bucket under every shipped
ratio and the model version. Review state and genres are untouched, whatever the review state;
the star rating is never written. Photographs this model already rated are not rendered again:
after a change of `ratingRatio` their bucket is re-derived from the stored ones, otherwise they
are skipped. A photograph whose rating fails keeps what it had and is counted in the summary;
running the command again retries it. A model without a rating head is reported and nothing
is done.

**Suggest Keywords** (ADR-030, R10) — a keyword round, separate from genres and ratings:
renders the selection (video, offline originals without a Smart Preview, and photographs whose
keywords are verified or judged skipped), runs the model, and adds the suggested keywords as
Lightroom keywords at their vocabulary paths (`Category > Subcategory > [general >] Keyword`
from the root, not exported), with the keyword review state `suggested`. On a photograph still
awaiting verification it re-synchronises: the plugin's earlier suggestions the model no longer
makes are removed if present, new ones added, the user's own kept. A failed photograph keeps
its keywords; a new one is marked `error` (in `Keyword Errors`), one awaiting verification
keeps its state with the error recorded. Creates the `Suggested Keywords` collections when
missing.

**Mark Keywords Verified** — each selected photograph awaiting verification records the
vocabulary keywords it now has as the decision (`verified`); no keyword changes; the others are
counted and left alone. **Re-suggest Keywords** — Suggest Keywords for verified photographs
only: adds new suggestions, removes nothing, back to `suggested`. **Apply Keyword
Judgements…** (File) — a file of the user's own judgements: exactly those vocabulary keywords,
the state `golden`, matched by UUID and file name; the same file twice changes nothing, and a
change the user made since an earlier file is kept and reported.

**Sync.** Lightroom's cloud sync carries keywords (when *Sync keywords* is on), not plugin
fields. Commands that write genre keywords in bulk — Accept, Set Primary Genre…, Correct
Genres…, Apply Approved Genres…, Update / Remove Genre Keywords, and the keyword commands —
are best run with sync
paused (cloud icon, top right); Classify, Add / Remove Genre and Clear Plugin Data do not touch
it. The SDK has no way to pause sync; Apply Approved Genres… reminds you in its confirmation.

## Progress and cancellation

`LrProgressScope` with per-chunk captions (`Rendering 51–100 of 150`, `Classifying 51–100 of
150`). Cancel is checked between photographs while rendering, and passed to the running model
through its cancel file, which stops it before the next photograph. On cancel: temp files
removed, completed results kept; classify the same photographs again to continue (finished
ones are skipped).

## Settings

There is nothing to set up: the model is bundled. `Check Model` (File ▸ Plug-in Extras)
confirms the model is complete and runs. The few tunables — rendition size, photographs per
model call, timeout, log level, the Personal keyword, the personal floor, the rating
bucket ratio and the keyword rule — are in the
optional config file (ADR-008). `Show Genreator
Diagnostics` (Help ▸ Plug-in Extras) shows the model, the settings and the selection.

## Deliberately not built

| Idea | Why |
|---|---|
| Auto-accept | Nothing measured says which suggestions are safe unseen; no confidence is kept (R6.6, ADR-004) |
| Custom modal review dialog | Lightroom's Loupe is strictly better for this judgement |
| HTML review page with write-back | Second source of truth; the report already covers the analysis need |
| Catalog-wide sampling | Selection is the input (R6.1) |
| Keywords outside the model's vocabulary, or a user-edited vocabulary | The model knows its own keywords only; a new one needs judgements and a new model (ADR-030) |
