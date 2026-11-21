# Architecture

## Shape

A single Lightroom Classic plugin bundle, pure Lua (ADR-006), with one native program bundled
beside it: the genre model runtime, `model/localgenres` (ADR-021).

All plugin Lua files are **flat in the bundle root** with a `Gr` prefix. `require` is
reliably documented for the plugin root but not for subdirectories, and the prefix avoids
colliding with Lightroom's own module names. `model/` holds data and the runtime only.

```
Lightroom selection
        │
        ▼
  GrClassifier.lua ──── GrConfig.lua       (sizes, chunk, timeout)
        │          ├─── GrMetadata.inputsOf (Personal tag, genre pre-tags — via GrKeywords)
        │          │
        ├──► GrRendition.lua               LrExportSession → temp JPEGs, GPS stripped
        │
        ├──► GrModel.lua                   request file → GrCli → model/localgenres → response
        │        buildRequest / parseResponse / suggest are pure;
        │        GrTaxonomy.lua: the genres, from model/taxonomy.json
        │
        └──► GrMetadata.lua                plugin metadata write (suggestions)

  GrRater.lua (Suggest Ratings, ADR-029): its own selection and confirmation, then the same
        render → model step (GrClassifier.scoreChunk) → GrMetadata.writeRating (rating fields only)
  GrKeywording.lua (the keyword commands, ADR-030): the same render → model step, then
        GrModel.deriveKeywords → one gate creating the vocabulary's keywords (GrKeywordTaxonomy:
        model/keyword-taxonomy.json, paths) → one gate assigning them and the keyword fields
                        │
                        ▼
              GrReview.lua                 accept / correct / set primary / add-remove genre
                        │                     → GrKeywords.lua keyword write
                        │             GrReviewCommand.lua: the menu shell (dialogs, progress, log)
                        │             GrCollections.lua:   review smart collections and grids
                        │             GrApproved.lua:      approved genres files → GrReview.run
                        ▼
              GrReport.lua                 CSV export; Quality Summary (decisions per model version)
```

## Layering rule

**Pure modules** take no `Lr*` dependency and are unit-testable under LuaJIT:
`GrTaxonomy`, `GrJson`, `GrConfig` (its `parse`), `GrLog` (its `redact`), the request,
response and suggestion halves of `GrModel`, the pure halves of `GrReport`, `GrReview`,
`GrKeywords` (`wanted`, `held`, `plan`), `GrCollections` (`specs`), `GrApproved`,
`GrKeywordTaxonomy`, and the plans, stored forms and judgements parsing of `GrKeywording`.

**Lightroom-bound modules** touch the SDK: `GrRendition`, `GrMetadata`, `GrClassifier`,
`GrCli`, `GrModel.run`, the Lightroom halves of `GrReview`, `GrKeywords`, `GrReport`,
`GrCollections` and `GrApproved`, the commands of `GrKeywording`, `GrReviewCommand`, and the
menu entry points. Their pure
helpers are tested directly; the rest runs against the doubles in `tests/stub/` offline — the
model call against `tests/fixtures/fake-localgenres` — and is verified by hand in Lightroom.

## The model contract

`GrModel.run(items, workDir, cfg, cancelFile)` is the plugin's one classifier call:

```lua
items = { { requestId = 'p1', photoId = 42, imagePath = '/…/DSC_0042.jpg', personal = true }, … }
-- returns
results = { p1 = { ranked = { { genre = 'Portrait', applies = true }, … } },   -- every genre
            p2 = { error = 'model_error', message = '…' } }, modelId
-- or nil, code, message when the call as a whole failed (the run stops)
```

The request file (`request.json`, schema 1, task `genres`) lists each rendition's path, the
Personal flag as `known_person`, `orientation = "AB"` (renditions are upright) and the cancel
file. `localgenres infer request.json response.json model/model.json` runs through `GrCli`
with a hard timeout. The response ranks every genre by how likely it is the primary, with an
`applicability` and the model's `cutoff`; `applies` = applicability ≥ cutoff. A model with a
no-genre class adds `no_genre { probability, cutoff }`; `noGenre` = probability ≥ cutoff.
Answers are matched by `request_id` and `photo_id`, never by position.

`GrModel.suggest(ranked, preTags, noGenre, useFloor)` turns that into the suggestion
(ADR-023): every genre that applies or is pre-tagged, in ranking order — only the pre-tags
when `noGenre`; the first is the primary; none is No genre. With `useFloor` (a personal
photograph, the `personalFloor` setting at `recommended`, and a model whose manifest has a
`personal_floor`; ADR-028) a genre applies only when its applicability also reaches the floor
(`GrModel.markFloor` sets `overFloor`).
`GrModel.rankingText` stores the ranking as `aiRanking` (`Por*+ Str* Eve … floor=0.5`), and
`GrModel.parseRanking` reads back the genres, the no-genre answer and the floor, so
`GrReview.rederiveDecision` can derive the suggestion again without the model.

A model with a rating head (ADR-029) adds `ranked.rating { score, bucket = { [ratio] = 0–3 },
default_ratio }`; `parseResponse` reads it beside the genres as `rating`, and a malformed one as
`ratingError`, which fails Suggest Ratings for that photograph and never a classification.
`GrModel.ratingRatio` chooses the ratio from the manifest's `rating` block and the setting,
`ratingSuggestion` takes the bucket under it, and `rederiveBucket` reads it back from the stored
buckets without the model.

A bundle with the keyword model (ADR-030; `make model … KEYWORDS=…`) adds `ranked.keywords
{ cap, cutoffs = { balanced, recall_first }, member_cutoffs = { rule = { zero_shot, probe } },
agreement_only = {names}, implied = { specific = general }, ranked = { {keyword, score,
zero_shot, probe} } }`; `parseResponse` reads it as `keywords`, validated against
`model/keyword-taxonomy.json` (a name outside it is that photograph's `keywordError`), only when
the bundle has that file. `GrModel.deriveKeywords(keywords, rule)` applies the model's rule:
keywords at or over the rule's cut-off in ranking order up to the cap, an agreement-only one
only when both members reach their own cut-offs (otherwise it uses no slot); `agreed` and
`implied` are recorded apart. The bundle's manifest keeps the genre model's version and adds
`keywords { version, model_id, taxonomy_version }`.

A response naming a genre outside the taxonomy, a ranking missing a genre, an answer for
another photograph, or a response for another taxonomy is an **error** — for that photograph,
or for the whole call when it concerns the response — never a partial or nearest-match result.

## Control flow of a classification run

1. Menu command starts `LrFunctionContext.postAsyncTaskWithContext` — `LrTasks.execute` and
   `waitForRender` both require a task.
2. Load config; check the model's files (`GrModel.check`); abort early with a clear message.
3. Read the selection. Filter: skip video, skip already-classified unless reclassifying.
4. Read each photograph's Personal tag and genre pre-tags; confirm the run, with the count of
   Personal photographs and, when it applies, the personal floor.
5. Create a per-run temp directory under `LrPathUtils.getStandardFilePath('temp')`.
6. For each chunk of photographs (`chunkSize`, default 50):
   a. Export the renditions; a failed render is recorded for that photograph.
   b. One model call for the chunk; a second task turns Cancel into the cancel file meanwhile.
   c. **Delete the chunk's renditions.**
   d. Derive each suggestion; record per-photograph errors; a cancelled photograph is left
      unclassified.
   e. Write the chunk's results in one `catalog:withWriteAccessDo`.
7. A model that fails as a whole (missing, crashed, wrong taxonomy) stops the run; the
   remaining photographs stay unclassified, not errors.
8. Delete the temp directory in the function-context cleanup handler, so it happens on
   error and cancellation paths too (R8.2).
9. Log the run's counts; show a summary dialog.

### Resumability

There is no separate run state. Classify skips photographs that already have a suggestion and
retries those in `error`, so classifying the same selection again continues an interrupted
run (R9.3). State lives in plugin metadata only.

## Error handling

Explicit, never silent:

- **Config errors** (unreadable file, bad value) — abort before any work, name the file.
- **Model missing** — abort before any work; *Check Model* names the missing file.
- **Rendition failures** — per photo; recorded, run continues.
- **Per-photograph model errors** (unreadable image, a genre outside the taxonomy) — recorded
  for that photograph, run continues.
- **Model call failures** (non-zero exit, timeout, unreadable response, wrong taxonomy) — the
  run stops; the photographs of the chunk and after stay unclassified.
- **Write failures** — surfaced; earlier chunks are already written.

A photograph that errors gets `reviewState = error` plus the error string, so failures are
visible in the smart collection instead of silently absent.

## Lightroom SDK facts this design depends on

Checked against the Lightroom Classic SDK reference and, where marked, observed in Lightroom.
Re-verify after an SDK update.

| API | Fact |
|---|---|
| `LrExportSession{photosToExport, exportSettings}` | Iterate `for _, rendition in session:renditions()` — the first value is an index. `renditions()` starts rendering itself; do **not** also call `doExportOn*Task()` ("can not call twice on same session"). *Observed in Lightroom.* |
| `rendition:waitForRender()` | Returns `(success, pathOrMessage)`. `rendition.destinationPath` may not exist yet. |
| `LR_collisionHandling = 'rename'` | Two photographs of a chunk with the same file name get distinct rendition files; the path comes from `waitForRender`. *To verify in Lightroom.* |
| `catalog:createKeyword(name, synonyms, includeOnExport, parent, returnExisting)` | Must run inside `withWriteAccessDo`; the keyword is not usable until that call returns. |
| `photo:addKeyword(kw)` / `photo:removeKeyword(kw)` | Write-access gated. |
| `photo:setPropertyForPlugin(_PLUGIN, key, value)` | Plugin metadata write; write-access gated. First argument must be the global `_PLUGIN` object — the toolkit id string is rejected. *Observed in Lightroom.* |
| `photo:getPropertyForPlugin(_PLUGIN, key)` | Read. |
| `catalog:createKeyword(name, synonyms, includeOnExport, parent, returnExisting)` | Repeating the lookup of the same existing keyword within one multi-photo command returned **nil** (photo 3 of 4, `Genre > Portrait`). Look each keyword up once per command and pass the objects on; GrKeywords does. *Observed in Lightroom.* |
| `catalog:createSmartCollection(name, searchDesc, parent, canReturnPrior)` | Criteria on a plugin field — *is*: `{ criteria = "sdk:<plugin id>.<field>", operation = "==", value = … }`; *contains*: `{ criteria = "sdktext:<plugin id>.<field>", operation = "any", value = …, value2 = "" }` (`sdk:` with `any` matches nothing); *is empty*: `{ criteria = "sdk:<plugin id>.<field>", operation = "==" }` with no value; `combine = "intersect"` or `"union"`. A nested group — a table of criteria with its own `combine` — is an element of the rule (accepted by Lightroom 2026-11-03; no collection uses one now). Not in the SDK reference; *read from smart collections built by hand in Lightroom.* `canReturnPrior` returns an existing collection unchanged — `collection:setSearchDescription` rewrites its rule. |
| `LrTasks.execute` (working directory) | A launched process inherits Lightroom's working directory (likely the home folder); a process that lists it reaches `~/Library/Containers`, and macOS repeatedly asked whether Lightroom may "access data from other apps". GrCli therefore `cd`s into the run's directory first. *Observed in Lightroom.* |
| `LrTasks.execute` (blocking) | Blocks the calling task until the process exits; another task (`LrTasks.startAsyncTask`) keeps running, so it can watch Cancel. *To verify in Lightroom.* |
| `catalog:findPhotoByUuid(uuid)` | The photograph with that UUID, or nil (Apply Approved Genres…). A catalog read. *To verify in Lightroom.* |
| `LrDialogs.runOpenPanel{…}` | Returns an array of chosen paths, or nil when cancelled. |
| Info.lua menu items | Only `title`, `file`, `enabledWhen`; no submenus; no right-click menu. A `-` title is drawn as an ordinary item, but `'──────────'` with `enabledWhen = 'videosSelected'` reads as a greyed divider. Three menus: `LrLibraryMenuItems`, `LrExportMenuItems` (File), `LrHelpMenuItems`. *Observed in Lightroom.* |
| `catalog:getActiveSources()` | The sources the grid shows: collections, folders, or special-source strings. Remove Genre reads the grid's name and its set (`getParent`) from it; the review trail records both (ADR-027). *Observed in Lightroom; `getParent` 2026-11-02.* |
| `catalog:findPhotosWithProperty(pluginId, key)` | Every photograph with the plugin field set (Quality Summary). Takes the toolkit id **string** (`_PLUGIN.id`), unlike get/set. *Observed in Lightroom.* |
| `catalog:batchGetRawMetadata(photos, keys)`, `catalog:batchGetPropertyForPlugin(photos, pluginId, fields)` | One read for a whole selection, a table keyed by photo; Classify reads format and review state this way, since one read per photo takes minutes on thousands. The plugin form takes the id **string**. *To verify in Lightroom.* |
| `photo:checkPhotoAvailability()` | Whether the original is reachable. Task-only. There is no `isMissing` raw-metadata key ("Unknown key"). *Observed in Lightroom.* |
| Plugin metadata | **Catalog-only** — cannot be linked to XMP or written into files. `dataType` ∈ `string`/`enum`/`url` — **no number type**. `searchable = true` → smart collections; `browsable = true` → grid filter. |
| Lua version | **5.1.4** — `unpack` not `table.unpack`, no `goto`. |

Learned by running the plugin inside Lightroom Classic. The offline stubs reproduce each of
these, so a regression fails `make test`:

| Behaviour | Consequence |
|---|---|
| SDK namespaces load only via the global `import 'LrX'`; `require` resolves plugin files only | `require 'LrApplication'` → "Could not load toolkit script" |
| Changing a metadata field's definition (e.g. `dataType`) needs that **field's own `version`** bumped, not just `schemaVersion` | "Could not upgrade your catalog for plug-in metadata"; guarded by `test_metadata_schema.lua` |
| The embedded `os` library has no `getenv` | Environment overrides are test-only and optional |
| An enum plugin field refuses a value it does not declare, `''` included; the error comes when the write gate closes and undoes the whole command | Clear Plugin Data sets Review state, never blanks it; the photo stub refuses undeclared enum values |
| An error inside `postAsyncTaskWithContext` is discarded silently | Every task registers `context:addFailureHandler` |
| Yielding calls — `withWriteAccessDo`, `LrTasks.execute`, `waitForRender`, and **catalog reads** (`getRawMetadata`, `getFormattedMetadata`, `getPropertyForPlugin`, `keyword:getName`) — cannot run inside a plain `pcall` | Use `LrTasks.pcall`; plain `pcall` reports "must be called from within an LrTask" |

## Cost model

Nothing per photograph: the model runs on the Mac. The model itself takes about 10 ms per
photograph after a start of about 2 s per call (measured on an Apple M4); rendering the
photographs in Lightroom takes longer. Review time, not run time, is the binding constraint.
