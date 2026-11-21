# Calibration and Testing

Two separate questions, deliberately not conflated:

1. **Is the model any good on this catalog?** — agreement against the user's decisions.
2. **Are the genres any good?** — whether they can be applied consistently at all.

The model was trained and measured on its author's catalog (`docs/model.md`). On any
other catalog, question 1 is answered only by the user's own decisions, here.

## Validation and write-back

Every model response passes `GrModel.parseResponse` before it can touch the catalog:

| Check | On failure |
|---|---|
| The response file is readable JSON with an `items` list | the call fails; the run stops (`bad_response`) |
| `taxonomy_version` equals the plugin's taxonomy | the call fails; the run stops (`model_mismatch`) |
| An answer exists for each photograph, matched by `request_id` **and** `photo_id` | that photograph: error, `no_answer` |
| The runtime reported an error for the photograph | that photograph: error, `model_error` (or left unclassified when `Canceled`) |
| Every ranked genre is in the taxonomy | that photograph: error, `unknown_genre` — **never mapped to a nearest match** |
| Every genre is ranked exactly once, with an applicability and a cut-off | that photograph: error, `bad_response` |
| A `no_genre` answer, when present, has a probability and a cut-off | that photograph: error, `bad_response` |

**A failed validation never produces a guess.** The photograph gets `reviewState = error`
and is visible in the review collection.

Write-back is batched into one `catalog:withWriteAccessDo` per chunk. On suggestion, only
plugin metadata is written (ADR-002). Keywords are written only through `GrReview` by
`GrKeywords`, whose pure `plan` is the single place the keyword invariants are enforced
(ADR-019).

## How quality is measured

```
1.  Select a batch from Not Classified (a real-distribution sample, R7.5) and classify it.
2.  Review in grids (R6.8–R6.10): genres first, then the primary. Judge the photograph,
    not the suggestion.
3.  Genre Quality Summary — per model version: primaries kept, genre lists edited, the
    most common primary changes, genres removed and added (R7.8).
```

The decisions are the ground truth (R7.4): `humanGenre` / `humanGenres` record them, and
`decisionModelVersion` the model version each answered — the Quality Summary counts a decision
under it, so reclassifying with a newer model does not move old decisions. `userGenres` and
`laterUserGenres` tell the user's pre-selections from genres added afterwards.
Decisions applied from an approved genres file had no suggestion to judge, so the summary
counts them apart.

### Signals worth watching

| Signal | Reading |
|---|---|
| A repeated primary change (e.g. Portrait → No genre) | A systematic difference between the model's author and you; correct in review, and expect it on similar photographs |
| Many genre-list edits, mostly removals | The cut-offs favour extra genres by design (0.18 per photograph on the author's held-out photographs, `docs/model.md`); a much higher rate means the catalog differs from the training one |
| Documentary missing where you see it | Expected, and not by itself a model error: Documentary often depends on context the image does not carry (the event, the series), which the model cannot see. Documentary is rare in the evaluation photographs (`docs/model.md`). Read a Documentary addition in the Quality Summary as context you supplied, not as a miss |
| No genre wrong in either direction, mostly on personal photographs | Expected: on held-out photographs the model found No genre on 68 of 77 that have it, and 68 of its 96 No-genre answers were right |
| Personal photographs judged as strangers' | The Personal tag is missing |
| Personal photographs often given a primary by hand (Set Primary Genre…) | Expected under the personal floor (ADR-028): the author's primary was left out on 33 of 50 held-out personal photographs, against 32 with the cut-offs alone |

The plugin has no way to retune the model; what it offers is a faithful record of where the
user disagreed with it, per model version, for whoever trains the next one.

## Offline test suite

Runs under LuaJIT (Lua 5.1-compatible, matching Lightroom's embedded 5.1.4) with no
Lightroom and no network:

```bash
make test          # or: luajit tests/run.lua
```

`tests/stub/` provides minimal `Lr*` doubles; `tests/fixtures/fake-localgenres` stands in for
the model runtime and answers in its format, so the whole pipeline runs without the model.

`tests/run.lua` lists every suite; the main ones:

| Suite | Covers |
|---|---|
| `test_taxonomy.lua` | The genres from the model's file, short forms, No genre never a genre, a file that cannot be trusted is refused |
| `test_model.lua` | The request (Personal flag, no keyword text), every validation row above, the stored ranking, the suggestion rule and the personal floor, one real process call |
| `test_e2e.lua` | Classification end to end: confirmation, renditions deleted, chunked calls and writes, No genre, pre-tags, failures, cancel and retry |
| `test_review.lua` | Accept / correct / No genre, Add / Remove Genre in priority order, Set Primary Genre, re-deriving a personal suggestion, the keyword invariants, multi-photo writes, cancel |
| `test_approved.lua` | Approved genres files: validation, matching by UUID and file name, idempotence, a newer file |
| `test_report.lua` | CSV columns; Quality Summary outcomes, versions, changes, genre-list tallies |
| `test_collections.lua` | Review collection definitions in Lightroom's criteria syntax, setup and repair |
| `test_footprint.lua` | Every menu command writes only the plugin's own fields, Genre keywords, collections, the Personal keyword it creates and the vocabulary's keywords (R5.6, ADR-030) |
| `test_metadata.lua` | The model's inputs from keywords; the fields written |
| `test_keywords.lua` | Keyword suggestion, re-synchronisation, verification, judgements files (ADR-030) |
| `test_model_bundle.lua` | What ships in `model/`, checksums, no label files, the import tool and the encoder download |
| `test_config.lua` | Config parsing and defaults |

### Requires manual verification in Lightroom

What the offline suite cannot prove is listed once, in `development.md` (*Verifying in
Lightroom*).
