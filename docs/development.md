# Developer Guide

How the plugin is built, tested and changed. User-facing setup is in the README.

## Repository layout

```
Genreator.lrplugin/      the plugin bundle — every Lua file flat in its root, Gr prefix
  Info.lua               manifest: menus, metadata provider
  GenreatorMetadata.lua  plugin metadata field definitions
  config.example.json    template for ~/.config/genreator/config.json
  model/                 the genre model: runtime (localgenres), model.json, taxonomy.json,
                         manifest.json with every file's SHA-256; encoders/ is in the
                         release zip, downloaded by `make install` in a source checkout
tools/model.lua          imports a model folder, verifies the bundle, packages the encoder and releases
licenses/                licence texts of bundled third-party components
tests/                   offline suite: run.lua, harness.lua, test_*.lua
  stub/                  doubles for the Lr* SDK namespaces
  fixtures/              fake-localgenres, a stand-in for the model runtime
docs/                    design documents (table at the end)
Makefile
```

## Commands

```bash
make test       # offline suite under LuaJIT: no Lightroom, no network (runs /bin/sh and the stand-in model)
make lint       # byte-compile every Lua file under LuaJIT
make install    # download the encoder if missing, symlink the bundle into Lightroom's Modules folder
make uninstall
make clean      # remove stale rendition temp directories
make model FROM=<folder>   # import a new model version (refused if a checksum differs)
make model-verify          # check every bundled model file against model/manifest.json
make encoder               # download the encoder release asset if missing (make install runs it)
make encoder-zip           # package the encoder with its licence, for a new encoder release
make release               # package the whole plugin, encoder included, for a plugin release (ADR-026)
```

**The encoder is not in git.** At 185 MB it exceeds GitHub's 100 MB file limit, so it is a
release asset tagged `encoder-<id>` and fetched by `make install` over HTTPS (with a
signed-in `gh` as the fallback, for a private fork), then verified against the manifest. A new model version reusing the same encoder needs no new release; a new encoder
does: `make encoder-zip`, then the `gh release create` line it prints. The import copies only
the runtime files; per-photo label files are private and never enter the bundle, and a local
path the model file records (where it was built) keeps only its last part
(`test_model_bundle.lua`).

**Installing from the source** (development only; users install a release zip, README):
`git`, `make` and `luajit` (`gh` only as the download fallback for a private fork);
`make install` downloads the encoder once and symlinks the bundle into Lightroom's
Modules folder. Then restart Lightroom.

**Releasing a plugin version:** bump `VERSION` in `Info.lua`, `make release`, then
`gh release create v<version> dist/Genreator-<version>.zip`. Users install it by hand; the
README's *Install* is the procedure to check on a downloaded copy.

`make test`, `make install`, `make release` and the model targets need `luajit` on the PATH
(`brew install luajit`); `make release` also uses `zip`, which macOS includes.

## Hard constraints

**Lightroom embeds Lua 5.1.4.** Use `unpack`, not `table.unpack`; no `goto`; no `\u{...}`
string escapes; no integer-division operator. `make lint` runs under LuaJIT, which catches
5.3-only syntax.

**Lightroom's runtime differs from its documentation and from LuaJIT.** The stubs reproduce
each of these, so a regression fails `make test`:

- SDK namespaces load only with the global `import 'LrX'`; `require` resolves plugin files only.
- Anything that yields must not run inside a plain `pcall` — use `LrTasks.pcall`. That
  includes **every catalog read** (`getRawMetadata`, `getFormattedMetadata`,
  `getPropertyForPlugin`, `keyword:getName`), not only `withWriteAccessDo`.
  Inside Lightroom a plain `pcall` there fails *silently*.
- An error inside `postAsyncTaskWithContext` is discarded unless the task registered
  `context:addFailureHandler`. Every task does.
- `get/setPropertyForPlugin` take the global `_PLUGIN`, not the id string;
  `catalog:findPhotosWithProperty` takes the id string (`_PLUGIN.id`).
- The embedded `os` has no `getenv` and no `remove` (use `LrFileUtils.delete`); `test_sdk_imports.lua`
  fails on an unguarded call.
- Unknown export-setting keys are silently ignored. A privacy setting is proven only by
  inspecting real output: during a large run, copy a JPEG out of the run's temp folder
  (`$TMPDIR/genreator-r-…`) and run `exiftool` on it.
- A metadata field whose definition changes needs **its own `version`** bumped as well as
  `schemaVersion`, or Lightroom refuses to upgrade the catalog. `test_metadata_schema.lua`
  holds a snapshot of every field; update it deliberately.
- `LrTasks.execute` blocks the calling task until the process exits; a second task
  (`startAsyncTask`) watches Cancel meanwhile and writes the model's cancel file.
- Lightroom does not notice files added to the plugin folder while it runs: a new `.lua` file
  means a restart.

**No external runtime** (ADR-006). No Python, no Node. The only process the plugin launches
is the bundled model runtime, `model/localgenres`, through `GrCli.lua`, with the request in a
temp file — never on the command line (ADR-021). JSON is `GrJson.lua`.

**Flat bundle.** `require` is reliably documented for the plugin root only. No Lua file goes in
a subdirectory; `model/` holds data and the runtime only.

## Architecture in one page

```
selection ─► GrClassifier ─► GrMetadata.inputsOf (Personal tag, genre pre-tags)
                 │        ─► GrRendition (LrExportSession → temp JPEGs, GPS stripped)
                 │        ─► GrModel.run (request file → GrCli → model/localgenres → response)
                 │        ─► GrModel.suggest (ranking + pre-tags → primary and genres)
                 └──────────► GrMetadata (suggestion fields, one write gate per chunk)

Suggest Ratings ─► GrRater ─► GrClassifier.scoreChunk (the same render → model step)
                         └──► GrMetadata.writeRating (rating fields only, ADR-029)

review menus ─► GrReviewCommand ─► GrReview (decisions) ─► GrKeywords (the only keyword writer)
                                   GrCollections (review smart collections)
approved file ─► GrApproved ─► GrReview.run
reports ─► GrReport (CSV, Quality Summary)
```

**Pure vs Lightroom-bound.** Business logic lives in modules with no `Lr*` dependency so it is
tested directly: `GrTaxonomy`, `GrJson`, `GrConfig.parse`, `GrLog.redact`, the request,
response and suggestion halves of `GrModel`, the pure halves of `GrReview`, `GrKeywords`
(`wanted`, `held`, `plan`), `GrCollections` (`specs`), `GrApproved`, `GrReport`, `GrRater`
(`plan`, `summaryText`), `GrKeywordTaxonomy`, and the plans, stored forms and judgements
parsing of `GrKeywording`.
Lightroom-bound code runs against `tests/stub/` and is verified by hand in Lightroom.

Details: [`architecture.md`](architecture.md) (the model contract, control flow, SDK facts),
[`data-model.md`](data-model.md) (keywords, fields, state machine, collections),
[`image-pipeline.md`](image-pipeline.md) (renditions and temp files).

## Invariants the tests enforce

If a change makes one of these fail, the change is wrong unless the requirement itself is
deliberately revised (with an ADR).

| Invariant | Where |
|---|---|
| A classification suggestion writes **no** keyword and removes none (ADR-002, ADR-023) | `test_e2e.lua` |
| Classify writes no rating; Suggest Ratings writes the rating fields only — never a genre field, the review state, a keyword or the star rating; a malformed rating fails the rating alone (ADR-029) | `test_e2e.lua`, `test_model.lua`, `test_footprint.lua` |
| Pre-tags are fixed at the first suggestion and never include genres the plugin wrote for a decision; a hand-added genre after it is kept by Accept / Set Primary (ADR-023) | `test_metadata.lua`, `test_review.lua`, `test_e2e.lua` |
| Every command writes only the plugin's own fields, the `Genre > X` keywords of the taxonomy, the keywords at the keyword vocabulary's paths (and their parents, created only), its own `Genreator` collections and the Personal keyword it creates when missing; any other photo or catalog write — a rating, a flag, a title, a foreign keyword — fails (R5.6, ADR-030) | `test_footprint.lua` |
| Keywords (ADR-030): a separate command; suggested keywords at their vocabulary path from the root, not exported, existing ones reused, a specific keyword assigned with its general one; verified and golden photographs never changed by Suggest Keywords, golden never by Re-suggest; re-synchronising removes only the plugin's earlier suggestions; a malformed keyword answer fails the keywords alone; the rule, cap and agreement-only keywords as the model says | `test_keywords.lua`, `test_e2e.lua`, `test_footprint.lua` |
| A keyword judgements file is matched by UUID and file name; it sets exactly the judged vocabulary keywords; applying it twice changes nothing; a newer file yields to the user's later change (ADR-030) | `test_keywords.lua`, `test_e2e.lua` |
| Renditions are exported with `LR_removeLocationMetadata = true` (R8.3) | `test_rendition.lua`, `test_e2e.lua` |
| Renditions embed only copyright metadata: `LR_embeddedMetadataOption = 'copyrightOnly'` | `test_rendition.lua` |
| `LR_reimportExportedPhoto` is `false` — renditions never enter the catalog | same |
| Renditions are deleted right after the model call, including when the model fails (R8.2) | `test_e2e.lua` |
| No keyword text reaches the model; its only keyword-derived input is the Personal flag (ADR-013, ADR-024) | `test_model.lua`, `test_e2e.lua` |
| The Personal flag is the configured Personal keyword or a keyword under it, anchored at the root; a person keyword elsewhere does not count (ADR-024) | `test_metadata.lua`, `test_config.lua`, `test_e2e.lua` |
| A model answer outside the taxonomy, for another photograph or for another taxonomy is an **error**, never a nearest match (R4.4) | `test_model.lua` |
| The suggestion: genres reaching their cut-off plus pre-tags, in ranking order — only the pre-tags when the model's no-genre output reaches its cut-off; the first is primary; none is No genre (ADR-022, ADR-023) | `test_model.lua`, `test_e2e.lua` |
| On a personal photograph a genre must also reach the floor in the bundled manifest (none when it has none, or with `personalFloor = off`); the no-genre answer and pre-tags are unchanged; re-deriving from the stored ranking gives the same suggestion as the model's answer and never touches a decision (ADR-028) | `test_model.lua`, `test_review.lua`, `test_e2e.lua` |
| A suggestion records the Personal flag the model was given, and a review decision the flag of the suggestion it answered (ADR-028) | `test_e2e.lua`, `test_approved.lua` |
| The Primary Genre is always first among the Genres; No genre has none and no keyword (ADR-022) | `test_review.lua` |
| Genre keywords are written only by `GrKeywords` (ADR-019): `Genre` for every genre, the primary included, created without Include on Export, and no other genre keyword; non-taxonomy keywords never touched. The Primary Genre / Secondary Genres fields are written in the same gate from the same result | `test_review.lua` |
| Smart-collection criteria are exactly Review state, Primary Genre, Secondary Genres, Suggested rating and Keyword review plus the fields the plugin's own collections search; the Library filter is Review state, Primary Genre, Suggested rating and Keyword review | `test_collections.lua` |
| The Metadata panel shows exactly the ADR-020 fields, in order, all `readOnly` except Secondary Genres; `GrMetadata.FIELDS` equals the declared fields | `test_metadata_schema.lua` |
| Reclassify never overrides a human decision (R2.7) | `test_review.lua`, `test_e2e.lua` |
| Genre names come only from the model's taxonomy file; a file that fails validation changes nothing | `test_taxonomy.lua` |
| An approved genres file is matched by UUID and file name, never guessed; applying it twice changes nothing (ADR-025) | `test_approved.lua` |
| Catalog write access is taken once per chunk, not per photo | `test_e2e.lua` |
| Arguments to the model runtime are quoted; photograph data never appears on its command line | `test_cli.lua` |
| Only runtime files enter the bundle; no label file; the bundled taxonomies refer to no record of the model's making; the committed model files match the manifest; a keyword model is bundled only on its own genre model, runtime and encoder | `test_model_bundle.lua` |

## Design principles

Settled decisions; change one only on new evidence, recorded as a new ADR in
[`decisions.md`](decisions.md).

- Pure Lua; the bundled model runtime is the one native program (ADR-006, ADR-021).
- One classifier, local; nothing leaves the computer (ADR-021).
- Suggestions never touch the keyword tree (ADR-002).
- Genres as keywords, not exported; the primary as a catalog field (ADR-001, ADR-019).
- The genres are the model's; genre names are never hard-coded (ADR-012).
- No keyword text reaches the model; Personal is the user's tag (ADR-013, ADR-024).
- No confidence number; the model's ranking instead (ADR-004).
- No genre is an answer (ADR-022).
- Review natively in Lightroom, by exception, in grids — no custom review dialog (R6.2, R6.8).
- The user's decisions are the only ground truth (R7.4).
- No auto-accept (R6.6).

## Conventions

- **Never hard-code a genre name.** Code reads `GrTaxonomy.genres`; tests use the bundled
  taxonomy's names.
- **Errors are explicit.** A photograph that fails gets `reviewState = error` and an error
  string, so it is visible in the `Errors` collection rather than silently absent.
- **Never guess on bad data.** A response that does not validate is an error, not a nearest
  match.
- **Comments explain why, not what.** The SDK has several non-obvious constraints (no number
  type in plugin metadata; `waitForRender` needs a task; JPEG quality is 0..1) — those are
  worth a comment.
- **One writer per store.** Keywords: `GrKeywords`. Plugin fields: `GrMetadata`. The model's
  request: `GrModel.buildRequest`.

## Updating the model

A model folder holds `manifest.json` (every file's SHA-256), `localgenres`, `model.json`,
`taxonomy.json` and `encoders/`. `make model FROM=<folder>` checks every checksum, copies only
those runtime files into `Genreator.lrplugin/model/` (any other file — notes, label files —
stays out) and writes the bundle's own manifest. `taxonomy.json` goes in its published form:
the version, the genres and their current text, without the record of how the text was
arrived at (source, status, earlier wordings, record ids such as `(C30)`); a reference the
import cannot remove without rewording stops it, to be cleaned where the model is built.
With the keyword model (ADR-030), `make model FROM=<genre folder> KEYWORDS=<keyword folder>`
also checks the keyword folder's checksums, that its `genres_model_id` is the genre folder's
`model_id`, and that its runtime and encoder are the genre folder's; it then bundles the keyword
folder's `model.json` (genres, rating and keywords in one call) and its taxonomy as
`keyword-taxonomy.json` (version and keywords only), and the manifest gains a `keywords`
block. Without `KEYWORDS` the bundle has no keyword head. When the genre model moves on before
a keyword model is published on it, importing the genre folder alone drops the keyword head
until one is. Then:

1. `make test` — a new taxonomy can change genre names; `test_taxonomy.lua` and the suites that
   use genre positions follow the file.
2. If the encoder id changed: `make encoder-zip` and publish the release it names.
3. Update the figures in `docs/model.md` (and its *Suggested keywords* section from
   the keyword model's description) and `docs/taxonomy.md` from the new model's description.
4. Restart Lightroom; *Check Model*.

The runtime contract the plugin relies on: `localgenres infer REQUEST RESPONSE MODEL`, request
schema 1, task `genres`; the response ranks every genre with `applicability` and `cutoff`;
per-item errors; exit status non-zero with a message on stderr when the call fails as a whole.
A model with a rating head also answers `ranked.rating` (ADR-029), and its manifest carries a
`rating` block that the import keeps in the bundle's manifest.

## Changing plugin metadata

1. Edit `GenreatorMetadata.lua`; bump the field's `version` and `schemaVersion`.
2. Update the snapshot in `tests/test_metadata_schema.lua` (and the panel list if a title
   changes).
3. Keep `GrMetadata.FIELDS` equal to the declared fields.
4. Restart Lightroom fully; new or changed fields appear only after a restart.

A field without a `title` is hidden from the Metadata panel but still readable and writable;
every searchable or browsable field needs a title.

## Verifying in Lightroom

What the offline suite cannot prove; check by hand after changes in these areas:

- **A release zip (ADR-026)**, downloaded through a browser and installed by the README's
  *Install*: without the `xattr` step, macOS shows *“localgenres” Not Opened* and *Check
  Model* waits; after *Done* it shows the quarantine command with this folder's path; after
  the command, the model is ready. Uninstall a development symlink first:
  two copies with one plugin id conflict.
- The plugin loads; *Check Model* reports the model ready; Diagnostics shows the model and
  settings; the fields appear in the Metadata panel.
- Classify on a real selection: suggestions written; the confirmation counts the Personal
  tags; Cancel during a large chunk stops the model (cancel file); renditions sharing a file
  name get distinct files (`LR_collisionHandling = 'rename'`). The batched selection reads
  (`batchGetRawMetadata`, `batchGetPropertyForPlugin`) skip videos and classified photographs.
- *Pick Photos to Review…* on a selection of thousands: the sample bar appears at once and the
  confirmation follows within seconds.
- Renditions have the expected size and **contain no GPS**; the temp directory is gone after
  success, error and cancellation.
- Pre-tagged `Genre > X` keywords survive Classify and Reclassify and appear in the
  suggestion.
- Accept writes `Genre` keywords (created without Include on Export) and the genre fields; an
  exported JPEG carries no genre.
- Accepting No genre writes no keyword and Primary Genre = No genre; the Library filter's
  Primary Genre column and a smart collection on it find those photographs.
- *Apply Approved Genres…*: `catalog:findPhotoByUuid` finds the photographs; the file name
  check matches; a second run changes nothing.
- Correcting an already-accepted photograph keeps the primary first among the genres and the
  genre fields matching the keywords.
- The personal floor (ADR-028), after a full restart: the Metadata
  panel shows *Classified as personal* last; Diagnostics shows the floor and `personalFloor`;
  Classify's confirmation names the floor; on personal photographs a genre under the floor is
  not suggested and the ranking ends `floor=0.5`. *Set Up Review Collections* rewrites `Personal Candidates` to its
  staging rule; after a classification on this version it shows the personal photographs
  awaiting review that still have a genre, and no others ("contains" with several words
  matching any of them); Accept, or removing the last genre, takes a photograph out. With
  `"personalFloor": "off"`, *Re-derive Personal Suggestions* restores the cut-off genres
  without rendering, and back again; Accept on a personal photograph writes
  `decision_personal = yes` in the CSV report.
- The suggested rating (ADR-029), after a full restart: the Library
  menu ends with *Suggest Ratings*; the Metadata panel shows *Suggested rating* last; *Check
  Model* names `2026.11.06-6466afd6-4bdd6c` and says "Suggested rating: yes, bucket ratio 2.0";
  Diagnostics shows the rating head and `ratingRatio`; Classify leaves the field empty; Suggest
  Ratings fills it with `0`–`3` on classified and unclassified photographs alike, leaves the
  review state and genres as they were, and the CSV report carries `rating_bucket`,
  `rating_ratio`, `rating_score`, `rating_buckets` (`1.5=3 2.0=2`) and `rating_model_version`;
  run again it renders nothing; with `"ratingRatio": 2` it re-derives the ratio-2 bucket
  without rendering; *Set Up Review Collections* adds `Suggested Rating` with four grids,
  candidates first, the candidates grid showing the bucket-3 photographs whatever their review
  state; the star rating is untouched.
- Lightroom's Undo reverts a plugin write.
- Ratings, flags, labels, develop settings and other keywords are untouched.
- The review collections match what the Library filter shows for the same criteria.
- Cancelling a review command part-way changes nothing.
- Remove Genre reads the genre from the grid being viewed in `Step 1 · Genres`
  (`catalog:getActiveSources()`, the grid's `getParent()`), and asks
  in a `Step 2 · Primary` grid of the same name.
- Set Up Review Collections: the Collections panel shows `Step 1 · Genres`, `Step 2 · Primary`,
  then `Awaiting Review`, `Errors`, `Not Classified`; the grids in their numbered order with
  names not cut off; collections an earlier version set up and no longer uses are gone
  (`LrCollection:delete`, `LrCollectionSet:delete`, `getChildCollections`); a collection of
  your own in the set stays.
- After a review command, the CSV report's `review_trail` names the command and the grid.
- Keywords (ADR-030), after a full restart, in a catalog copy with cloud sync stopped (a copy
  keeps syncing):
  - *Check Model* says "Suggested keywords: yes, 75 keywords, keyword taxonomy 0.14 (rule:
    balanced)"; Diagnostics shows the keyword head and `keywordRule`.
  - **Parent filter** — filtering by `Boat` does not find a photograph tagged
    only `Sailboat`, so the plugin assigns both (ADR-030). Check: a photograph the model
    suggests a specific keyword for (or a judged one) carries the general keyword too, and the
    Boat filter finds it.
  - Suggest Keywords on a few photographs: the keywords appear at the root under their
    categories, not exported (Keyword List: *Include on Export* off); *Keyword review* shows
    `suggested`; `Genreator ▸ Suggested Keywords ▸ 1 Keywords to Verify` shows them; genres,
    their review, the rating and the star rating are unchanged.
  - Remove one keyword and add another of the vocabulary by hand; Mark Keywords Verified: the
    grid empties, *Keyword review* says `verified`, and the CSV report's `keywords_decided` lists
    exactly the vocabulary keywords present.
  - Suggest Keywords again on them: nothing to do. Re-suggest Keywords: they return to the grid
    with nothing removed.
  - Apply Keyword Judgements… with a judgements file: matched photographs get exactly the
    judged keywords and `golden`; applied twice, nothing changes.
  - Undo right after a run reverts keywords and fields together (several gates may merge).
  - A keyword outside the vocabulary's paths, deleted or added, leaves the plugin's keywords
    unaffected.

## Planned

Work committed to next; the maintainer picks each session's work.

Nothing at present.

## Not built

Ideas kept open, none in progress:

- **Auto-accept** — only once something measured on the catalog separates right from wrong
  suggestions; the plugin keeps no confidence today (ADR-004).
- **A confidence for review order** — "least sure first" would need the model's probabilities
  stored and calibrated on the user's decisions.
- **A new encoder** — taken through `make model`, a new encoder release (`make encoder-zip`),
  the Lightroom checklist and the figures in `docs/model.md`, by rating slice.
- **Rating with classifying** (ADR-029) — Suggest Ratings is separate for now; writing the
  rating in the same pass as Classify would save a render per photograph. No "0★ → No genre"
  labelling: measured wrong on older photos.
- **Showing the agreed keyword tier** (ADR-030) — recorded in `keywordSuggestion` and the
  report, not shown; a colour label or a grid would make it visible.
- **Keywords with classifying** (ADR-030) — Suggest Keywords is separate, as ratings are; one
  pass would save a render per photograph.
- **A settings dialog** — the few settings are in the optional config file.

## Temporary tools

- **Pick Photos to Review…** (`GrMenuPick.lua`, `GrPick.lua`, the pick mode of
  `GrClassifier`, the `pickReason` field): chooses
  photographs for review — an equal share per suggested primary genre, the model's edges first
  within each (pick-v3) — so the rare, most often wrong genres get reviewed. Each pick records
  its primary's share of the sample, so measures can be weighted back to it. The
  criteria are versioned (`GrPick.VERSION`); change the version whenever they change. Remove
  the command, module and field writes when it is no longer needed (the field
  stays declared until a schema clean-up). `test_pick.lua` covers it.
- **The review trail** (`reviewTrail`, written by `GrReview.run` from `GrReviewCommand`):
  every review command per photograph with its grid and selection size, to revisit the
  collections' order (ADR-027, *Revisiting*: at 300 decided photographs with a trail, 20 per
  suggested primary). Remove the writes once the order is settled. `test_review.lua` and
  `test_footprint.lua` cover it.

## Documentation map

| File | Contents |
|---|---|
| [`taxonomy.md`](taxonomy.md) | The genres, their definitions, and how they change |
| [`model.md`](model.md) | What the model learned from, and how well it does |
| [`requirements.md`](requirements.md) | Requirements, by area |
| [`decisions.md`](decisions.md) | ADRs — what was decided, what was rejected, and why |
| [`architecture.md`](architecture.md) | Module layout, the model contract, control flow, SDK facts |
| [`data-model.md`](data-model.md) | Keywords, plugin metadata, review state machine, collections |
| [`image-pipeline.md`](image-pipeline.md) | Renditions, resolution, temp-file lifecycle |
| [`workflow.md`](workflow.md) | Menus, the review loop, filtering |
| [`calibration.md`](calibration.md) | Validation, quality measurement, test suite |
| [`privacy-security.md`](privacy-security.md) | What is stored where, logging, failure modes |
