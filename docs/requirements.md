# Requirements

What the plugin must do, by area. Identifiers are stable and referenced from the code and the
other documents; missing numbers are withdrawn requirements. Items marked *(assumption)* are
design positions rather than user-facing requirements.

## R1 — Purpose

**R1.1** Each photograph gets a **primary photographic genre**, answering "by what
photographic standard should this image be judged?", so that Lightroom's single star rating
has a defined evaluation context.

**R1.2** The genres are **not** object recognition: they describe photographic intent and
composition, not detected objects. Descriptive keywords are a separate output of the same
model, from its own keyword taxonomy, by a command of their own (R10, ADR-030).

**R1.3** Classification is **AI-assisted, not autonomous**. Every result is a suggestion
until a person decides.

## R2 — Taxonomy

**R2.1** The genres are those of the bundled model, read from its taxonomy file
(`model/taxonomy.json`): Street, Portrait, Event, Documentary, Landscape, Nature, Architecture
and Object. `docs/taxonomy.md` holds their definitions (ADR-012).

**R2.3** **No genre** is a valid answer: a Primary Genre value with no genres. It never
becomes a keyword (ADR-022).

**R2.5** The genre list is not editable in the plugin; it changes only with a new model. Every
suggestion records the model version, so results from different models are never mixed.

**R2.6** A categorized photograph has **exactly one Primary Genre among one or more Genres**,
or No genre and no Genres. It never has genres without a primary; before classification it
may carry the user's genre keywords with none (ADR-022).

**R2.7** The genres are `Genre > X` keywords; the Primary Genre is the `primaryGenre` field
(ADR-019). A person's decision takes precedence over suggestions: reclassifying refreshes the
model's fields but never overrides a decision.

**R2.8** Genre names are never hard-coded outside the model's taxonomy file.

**R2.9** Genres are kept in priority order — the model's ranking of how likely each is the
primary. If the primary is removed in review, the next genre in that order becomes primary
(ADR-023).

## R3 — Classifier input

**R3.1** The model receives a JPEG rendered from the photograph's **current develop
settings**, never the original RAW, and one flag: whether the photograph is tagged Personal.

**R3.2** A photograph is personal when it carries the Personal keyword (configurable, default
`#PERSONAL`) or any keyword nested under it; Set Up creates the keyword when missing. Person keywords are not used for this (ADR-024). Classify reports how many
photographs of a run carry the tag before it starts.

**R3.3** The user may tag genres before classifying (`Genre > X`). A pre-tag means "present",
not "primary": it is always among the suggested genres, in ranking order; it becomes the
primary only when no genre reaches its cut-off and it is the pre-tag the model ranks highest.
Classification and reclassification never remove it (ADR-023).

**R3.4** On a personal photograph a genre is suggested only when it reaches its cut-off and
the model's recommended floor (`personal_floor` in its manifest; none when it has none); the
no-genre answer and pre-tags are unchanged, and other photographs keep the cut-offs. The user
can turn the floor off (`personalFloor`), and *Re-derive Personal Suggestions* applies a
changed setting from the stored ranking without the model. The Personal flag sent to the
model is kept with the suggestion and with each review decision, and *Personal Candidates*
stages the personal photographs awaiting review that keep a genre (ADR-028).

**R3.5** No keyword text, caption or location is given to the model or written outside the
catalog (ADR-013). The request file names each rendition by its path, which keeps the
original's file name; it stays in the run's local temp folder.

## R4 — The model

**R4.1** One classifier: the local genre model bundled with the plugin. No network service,
account or key (ADR-021).

**R4.2** The model's files are verified against a manifest of SHA-256 checksums when they are
packaged, installed or imported.

**R4.3** The offline test suite runs the whole pipeline against a stand-in for the model
runtime, with no model and no network.

**R4.4** A model answer naming a genre outside the taxonomy, missing a photograph, or made for
another taxonomy is an error, never mapped to a nearest genre.

## R5 — Lightroom storage

**R5.1** A confirmed genre is a hierarchical keyword under a `Genre` parent.

**R5.2** `Genre` keywords are created with `includeOnExport = false`: exported files carry no
genre. An existing keyword's setting is never changed.

**R5.3** Genre keywords are written **only on accept or correction**, or from an approved
genres file (R6.11). Unreviewed suggestions live solely in plugin metadata: a genre keyword
means *a person put it there*, never *guessed*.

**R5.4** Provenance — suggested primary and genres, the model's ranking, the user's pre-tags,
model and model version, timestamp, the decision's source — and the review state are plugin
custom metadata. The Metadata panel shows only what review and filtering need (ADR-020); the
rest is in the CSV report.

**R5.5** The primary is not a keyword: it is the `primaryGenre` field (a genre or `No genre`),
and the other genres are listed in priority order in the `secondaryGenres` field (ADR-019).
Changing the primary never removes another genre. A photograph with No genre is found with
Primary Genre *is* No genre.

**R5.6** Existing keywords, star ratings, flags, colour labels, develop settings and all
unrelated metadata are never modified. The exceptions are the plugin's own keywords: the
`Genre > X` keywords (R5.1) and the keywords at the keyword taxonomy's paths (R10.2).

## R6 — Workflow

**R6.1** The plugin operates on the **current Lightroom selection**; there is no catalog-wide
sampling.

**R6.2** Review happens **natively in Lightroom** — grid and Loupe, review fields in the
Metadata panel, smart collections — with decisions applied by menu commands on the selection.

**R6.3** Outcomes:
- **Accepted** — the suggestion (with no review edits) was right; keywords are written.
- **Corrected** — a person changed the primary or the genre list; keywords are written.
Either may be No genre, which writes no keyword.

**R6.5** Already-classified photographs are skipped by default; reclassification is a
separate command.

**R6.6** *(assumption)* No auto-accept: nothing measured says which suggestions are safe to
accept unseen, and the plugin keeps no confidence (ADR-004).

**R6.7** Revert commands exist: clear the plugin's data for the selection, and remove the
genre keywords the plugin wrote.

**R6.8** Review is **by exception, in grids**: one smart collection per suggested Primary
Genre and one for No genre (correct the odd ones out, then accept the rest at once), and one
per genre anywhere in the suggestion (to find photographs wrongly given it). A person still
decides every photograph.

**R6.9** Review runs in two steps: **1. the genres, 2. the primary.** Step 1, in the genre
grids: **Remove Genre** (inside a genre grid it removes that genre with no dialog) and **Add
Genre…** edit only the genres under review (`reviewGenres`, and the primary `reviewGenre`);
the photograph stays awaiting review and no keyword is written. They never fail on the list:
adding a listed genre or removing an absent one changes nothing; an added genre takes its
place in priority order; removing the primary promotes the next genre in priority order;
removing the last leaves No genre. Step 2, in the primary grids: Accept writes the genres as
edited, recorded as `corrected` when anything changed. A reclassification starts a new review.

**R6.10** **Set Primary Genre…** makes the chosen genre the primary of every selected
photograph (adding it if missing); the old primary stays as a genre and each photograph keeps
its own list. Choosing No genre clears the genres. It decides at once. **Correct Genres…**
gives every selected photograph the same full answer, and says so.

**R6.11** **Apply Approved Genres…** applies a file of the user's own genre decisions
(photo UUID, file name, primary, genres) as decided photographs, overriding their genres.
Photographs are matched by UUID and file name; anything else is skipped and reported.
Applying the same file again changes nothing; a newer file updates what differs (ADR-025).

**R6.12** **Suggest Ratings** is a command of its own, separate from classifying: it writes
the model's suggested rating — a bucket from 0 (likely 0★) to 3 (a candidate for 3★ and above)
under the user's bucket-ratio setting, with its score and provenance — to plugin fields only,
whatever the review state, and never the star rating (R5.6, ADR-029). Classifying writes no
rating; rating changes no genre and no review state.

## R7 — Measuring quality

**R7.4** "Truth" is the person's decision — an accepted or supplied answer, or an approved
genres file. Decisions from such a file had no suggestion to judge and are counted apart.

**R7.5** The test set is whatever the user selects — an unstratified, real-distribution
sample. Reports state sample sizes so small cells are not over-read.

**R7.8** The **Quality Summary** counts review decisions across the catalog per model version:
primaries kept, genre lists edited, primaries changed (with the most common changes), and the
genres removed and added.

## R8 — Privacy and security

**R8.1** Nothing leaves the computer: classification makes no network connection.

**R8.2** Renditions go to a per-run temporary directory and are deleted right after the model
call that reads them, and the directory on every exit path, including error and cancel.

**R8.3** Renditions are exported with location metadata stripped and embedded metadata
limited to copyright, so even the temporary files carry no GPS.

**R8.4** Logs record counts, timings, genres and error codes — never image bytes, file paths,
captions or keywords.

**R8.5** Approved genres files hold per-photograph data from a catalog; they are never part of
the repository.

## R9 — Engineering

**R9.1** Simple architecture, minimal dependencies, explicit error handling, documented
decisions.

**R9.2** Pure Lua, no external runtime beyond Lightroom (ADR-006); the bundled model runtime is
the one native program (ADR-021).

**R9.3** Interrupted batches can be continued: classifying the same selection again skips
finished photographs and retries errors.

**R9.4** Business logic is unit-testable outside Lightroom: pure modules take no `Lr*`
dependency and run under LuaJIT with stubs.

## R10 — Keywords

The model's keyword head suggests descriptive keywords from its own keyword taxonomy, a fixed
list of leaf keywords in categories and subcategories (ADR-030), with its categories at the root
of the keyword list.

**R10.1** **Suggest Keywords** is a command of its own, separate from classifying and rating:
it renders the selection, runs the same model call and writes the suggested keywords at once as
Lightroom keywords, with the photograph's keyword state `suggested`. Genres, the genre review,
the rating and the star rating are untouched. Videos and photographs whose keywords are
verified or golden are skipped.

**R10.2** The keyword tree is the taxonomy's: each keyword at `Category > Subcategory >
Keyword` from the root of the keyword list, a keyword with a general form nested under it
(`… > Boat > Sailboat`). Keywords are created without Include on Export; an existing keyword
on the path, a top-level one named like a category included, is reused unchanged. A specific
keyword is assigned together with its general keyword (Sailboat with Boat), since Lightroom's
filters by a parent keyword miss a photograph tagged only with the child; categories and
subcategories are never assigned. Only keywords at the taxonomy's paths are read or written;
any other keyword is untouched. Keyword names are never hard-coded: they come from the keyword
taxonomy.

**R10.3** The suggestion follows the model's rule: walk its ranking, take each keyword whose
score reaches the cut-off of the rule (`balanced`, or `recall_first` by the `keywordRule`
setting) up to its cap; an agreement-only keyword needs both members over their own cut-offs
and otherwise uses no slot. The keywords both members agree on (the agreed tier) and the
implied general keywords are recorded with the suggestion. No keyword is a valid answer. An
answer naming a keyword outside the taxonomy, or malformed, is that photograph's error.

**R10.4** Review is in a grid: *Keywords to verify* holds the `suggested` photographs; the
user removes wrong keywords and adds missing ones, then **Mark Keywords Verified** records the
taxonomy keywords present as the decision (`verified`), and the photograph leaves the grid.
Suggest Keywords on a `suggested` photograph re-synchronises it: a keyword the plugin
suggested before and no longer suggests is removed if still present, new suggestions are
added, keywords the user added are kept.

**R10.5** **Re-suggest Keywords** brings verified photographs back after a model or taxonomy
change: it adds the current suggestions not present, removes nothing, and returns them to
`suggested`. It never changes a golden photograph.

**R10.6** **Apply Keyword Judgements…** applies a file of the user's own keyword judgements
(photo UUID, file name, keywords): a matched photograph gets exactly the listed taxonomy
keywords (`[]` means none) and the state `golden`. Photographs are matched by UUID and file
name; anything else is skipped and reported. Applying the same file again changes nothing; a
newer file updates a photograph unless the user changed its taxonomy keywords since the last
application, which is kept and reported as a conflict.

**R10.7** Provenance is in plugin fields: the keyword state, the suggestion (keywords in the
model's order, the agreed ones, the implied ones, model and version, keyword taxonomy version,
rule, time), the decision (source and the keywords present) and the last error. Clear Plugin
Data blanks them and leaves the keywords; the CSV report carries them.

## Out of scope

Auto-accept; video; catalog-wide sampling; writing provenance to XMP;
publish services; keywords outside the model's keyword taxonomy, and a user-edited keyword
list; writing a star rating, and genre-specific
rating criteria. The plugin decides the standard a photograph is rated by (R1.1); the rating
stays the person's (R5.6). A *suggested* rating in plugin fields is in scope (R6.12).
