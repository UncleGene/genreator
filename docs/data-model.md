# Data Model

Three stores, each with a defined job. The one deliberate copy: the genre fields
(`primaryGenre`, `secondaryGenres`) restate the keywords for smart collections, and are
written only together with them (ADR-019).

| Store | Holds | Durability |
|---|---|---|
| Keywords | The genres a person put there — decided, or pre-tagged; the Personal keyword tree; the keyword vocabulary's keywords, written when suggested (ADR-030) | Portable — XMP, sidecars; not exported (R5.2) |
| Plugin custom metadata | Suggestion and its ranking, review state, the decided primary; the suggested rating; the keyword review | Catalog-only (ADR-001) |
| Log file | Per-run counts, timings, errors | `~/.config/genreator/logs/` |

## 1. Keywords

One genre branch (ADR-019), the user's Personal keyword tree (ADR-024), and the keyword
vocabulary's tree (ADR-030). The genre names come from the model's taxonomy, so the tree
follows it:

```
Genre                    (parent, includeOnExport = false)   — every genre, the primary included
├── Street
├── Portrait
├── Event
├── Documentary
├── Landscape
├── Nature
├── Architecture
└── Object
#PERSONAL                the Personal keyword (config personalKeyword); it and everything under
└── Family …             it mark a photograph personal. Read only; created by Set Up when missing
Visual Features          a category of the keyword vocabulary (ADR-030), at the root
├── Visual Structure     a subcategory: a parent only, never assigned
│   ├── Reflection       a keyword: suggested and assigned
│   └── …
Objects and Transportation
└── Transportation
    └── Boat             a general keyword …
        └── Sailboat     … with its specific form nested under it; both are assigned together
…                        (6 categories, 75 keywords at vocabulary v0.14, from model/keyword-taxonomy.json)
```

The vocabulary's keywords are written by the keyword commands alone (`GrKeywording`): created
at their path from the root, `includeOnExport = false`, an existing keyword on the path (a
top-level one named like a category included) reused unchanged; recognised on a photograph by
their full path, compared case-insensitively. Categories and subcategories are never assigned;
a specific keyword is assigned with its general one (Lightroom's parent filters miss a
photograph tagged only with the child, checked 2026-11-06). Any keyword off those paths — the same name
elsewhere included — is not the plugin's and is never touched. Unlike genre
keywords, suggested keywords are assigned when suggested; the keyword review state says whether
they are vetted.

The primary and the other genres are plugin fields, not keywords (`primaryGenre`,
`secondaryGenres`): a smart collection's Keywords rule matches names, so it cannot tell a
primary `Street` from a secondary one. The fields can.

- Created lazily on first write, via `catalog:createKeyword(name, {}, false, parent, true)` inside `withWriteAccessDo`. `returnExisting = true` so an existing tree is adopted rather than duplicated.
- **`No genre` is never a keyword.** It is a Primary Genre value only (ADR-022).
- **Invariants, enforced in one place on write (`GrKeywords`):** one `Genre > X` per genre, the primary included, and no other genre keyword; no other keyword is touched, including a user's own child of `Genre`. The genre fields are written in the same gate from the same result (`GrKeywords.wanted`).
- Written on accept or correction, or from an approved genres file (ADR-002, ADR-025). A suggestion writes none and removes none: genre keywords the user applied before classifying are pre-tags (ADR-023).

## 2. Plugin custom metadata

Declared in `GenreatorMetadata.lua`, registered via `LrMetadataProvider` in `Info.lua`.
Plugin fields are offered for filtering only where a person needs them or the review
collections do (ADR-019):

- **Library Filter** (`browsable = true`): Review state, Primary Genre (including
  `No genre`), Suggested rating, Keyword review. A genre in any role is in the Keyword column (`Genre > X`); "a genre, but not
  as the primary" is a smart collection on Secondary Genres.
- **Smart-collection criteria** (`searchable = true`): those four plus Secondary Genres,
  and what the review collections search: `reviewGenre`, `reviewGenres`, `personal`.
  `test_collections.lua` holds both lists to that.

**Metadata panel** (ADR-020): every shown field but Secondary Genres is `readOnly`, so only
the plugin's commands change them; Secondary Genres stays editable because Lightroom cuts a
read-only value off at one line. Shown, in order: Review state, Primary Genre, Secondary
Genres, Under review: primary genre / genres, Error, Classified as personal, Suggested
rating, Keyword review. The other fields have no title, so they
are hidden; the CSV report, Diagnostics and Correct read them.

**`dataType` is `string` or `enum` only — the SDK has no number type**, so numeric values
are stored formatted.

| Field id | Type | Values / format | Purpose |
|---|---|---|---|
| `reviewState` | enum | `unclassified`, `suggested`, `accepted`, `corrected`, `error` | Drives the review smart collections |
| `primaryGenre` | string | a genre, `No genre`, or empty | "Primary Genre": the decided primary as the keywords stand (ADR-019); written only with them |
| `secondaryGenres` | string | comma-separated, priority order | "Secondary Genres": every decided genre but the primary |
| `reviewGenre` | string | a genre or `No genre` | "Under review: primary genre" (R6.9): starts as `aiGenre`; Remove Genre on it promotes the next genre in priority order. Its presence marks a photo prepared for genre review. The primary grids search it |
| `reviewGenres` | string | comma-separated, priority order | "Under review: genres" (R6.9): starts as `aiGenres`, edited by Add / Remove Genre; Accept applies it; the genre grids search it |
| `errorText` | string | free | Set when `reviewState = error` |
| `personal` | string | `yes`, `no`, or empty | "Classified as personal": the Personal flag the model was given (ADR-024, ADR-028); the personal floor and Personal Candidates go by it. A string, not an enum, so Clear Plugin Data can blank it |
| `aiGenre` | string | a genre or `No genre` | *Hidden.* The suggested primary |
| `aiGenres` | string | comma-separated, priority order | *Hidden.* The suggested genres; includes `aiGenre` |
| `aiRanking` | string | e.g. `Por*+ Str* Eve Doc Lan Nat Arc Obj floor=0.5`, or `-* Por Str …` | *Hidden.* Every genre in the model's order, `*` where it reaches its cut-off, `+` after it where it also reaches the model's personal floor; a leading `-*` when the model's no-genre output reaches its cut-off; a last `floor=<n>` when the model has a floor (ADR-004, ADR-022, ADR-023, ADR-028) |
| `userGenres` | string | comma-separated | *Hidden.* The user's pre-tags: genre keywords present at the first suggestion, not written by the plugin; unchanged by reclassification (ADR-023) |
| `laterUserGenres` | string | comma-separated | *Hidden, temporary while the model is tuned.* Genre keywords the user added by hand after the first suggestion, outside review (ADR-023). A record of what the user added: it keeps a genre that Correct Genres… or an explicit No genre later dropped |
| `humanGenre` | string | a genre or `No genre` | *Hidden.* The decided primary — the truth the Quality Summary counts against (R7.4) |
| `humanGenres` | string | comma-separated | *Hidden.* Every decided genre; includes `humanGenre` |
| `decisionSource` | string | `review`, or `approved:<fingerprint>` | *Hidden.* Where the decision came from (ADR-025) |
| `decisionModelVersion` | string | a model version, or empty | *Hidden.* The model version the decision answered; empty for an approved genres file. The Quality Summary counts a decision under it; a review decision made before it existed counts as `(unknown)` |
| `decisionPersonal` | string | `yes`, `no`, or empty | *Hidden.* Whether the suggestion the decision answered was for a personal photograph (`personal` at the time); empty for an approved genres file. Decisions on personal photographs are feedback on the model, not training examples (ADR-028) |
| `ratingBucket` | string | `0`–`3` or empty | "Suggested rating": the model's rating bucket under `ratingRatio`, 0 = likely 0★ to 3 = a candidate for 3★ and above (ADR-029). Written by Suggest Ratings only, never by Classify. Searchable and in the Library filter; the `Suggested Rating` grids search it. Never the star rating. Empty until rated |
| `ratingRatio` | string | e.g. `1.5` | *Hidden.* The bucket ratio `ratingBucket` is under (ADR-029) |
| `ratingScore` | string | e.g. `1.623` | *Hidden.* The model's rating score (ADR-029) |
| `ratingBuckets` | string | e.g. `1.5=3 2.0=2` | *Hidden.* The bucket under every ratio the model ships, so Suggest Ratings re-derives the bucket after a change of the `ratingRatio` setting without the model (ADR-029) |
| `ratingModelVersion` | string | a model version | *Hidden.* The model version that rated; Suggest Ratings does not render a photograph this version already rated (ADR-029) |
| `keywordState` | string | `suggested`, `verified`, `golden`, `error`, or empty | "Keyword review" (ADR-030): `suggested` = the plugin's keywords await vetting (Keywords to Verify), `verified` = vetted (Mark Keywords Verified), `golden` = the user's judgements file applied, `error` = the last suggestion failed on a photograph without keywords from the plugin. Searchable and in the Library filter. A string so Clear Plugin Data can blank it |
| `keywordSuggestion` | string | `v1\|<keyword model version>\|<vocabulary version>\|<rule>\|<UTC>\|<ids>\|<agreed ids>\|<implied ids>` | *Hidden.* The last suggestion, keyword ids comma-separated in the model's order; re-synchronisation removes what it suggested and no longer does (ADR-030) |
| `keywordDecided` | string | `v1\|<verified or golden:fingerprint>\|<UTC>\|<ids>` | *Hidden.* The decision: the vocabulary keywords present when verified, or those a judgements file set; a newer file yields to a change made since (ADR-030) |
| `keywordError` | string | free | *Hidden.* The last keyword error |
| `model` | string | the model id | *Hidden.* Model that answered |
| `modelVersion` | string | e.g. `2026.10.27-13f2e23b-1b97b2` | *Hidden.* The bundled model's version; segregates incomparable results |
| `classifiedAt` | string | ISO 8601 UTC | *Hidden.* When |
| `runId` | string | `r-<timestamp>-<rand>` | *Hidden.* Which run wrote the suggestion (also in the log) |
| `pickReason` | string | e.g. `pick-v3:close,cut-off:6/500`, `pick-v3:none:212/500` | *Hidden, temporary.* How Pick Photos to Review… chose the photograph: its signals, and how many of the sample shared its suggested primary (to weight measures back to the sample); kept across a reclassification. Earlier picks: `pick-v2:random:…` / `pick-v2:score:…` |
| `reviewTrail` | string | e.g. `1793000000 rm:Object n=14 @Step 1 · Genres/1 Object; 1793000300 accept n=212 @Awaiting Review` | *Hidden, temporary (ADR-027).* Every review command since the suggestion: UTC seconds, command, selection size, the grid it was chosen in; the last 30 kept. A new suggestion starts it afresh; a reclassified decision keeps it |

**Clear Plugin Data and pre-tags.** Clearing resets the record of whose genres are whose but
leaves the keywords, so the next classification treats every genre keyword on the photograph —
including ones the plugin wrote for an earlier decision — as the user's pre-tags.

### Review state machine

```
unclassified
     │ classify
     ▼
 suggested ──── accept ────► accepted    (Genre > each genre; primary, secondaries → fields;
     │                                    No genre: no keyword, Primary Genre = No genre)
     │     ──── correct ───► corrected   (keywords from the user's choice; = accepted if it
     │                                    equals the suggestion)
     │
     └──── model/render failure ────► error

any state ── Apply Approved Genres ──► accepted (the approved genres; decisionSource approved)
accepted | corrected ── reclassify ──► SAME state; the model's fields refreshed only (R2.7)
suggested ── Re-derive Personal Suggestions ──► suggested (personal: the suggestion from the
                                    stored ranking under the current personalFloor; ADR-028)
any state ── Clear Plugin Data ──► unclassified   (fields only; keywords untouched)
any state ── Remove Genre Keywords ──► same state  (keywords only)
```

The keyword review (ADR-030) has its own state, `keywordState`, independent of the genres':

```
(none) | error ── Suggest Keywords ──► suggested   (keywords added at once)
suggested ── Suggest Keywords ──► suggested         (re-synchronised: the plugin's dropped
                                                     suggestions removed, new ones added)
suggested ── Mark Keywords Verified ──► verified    (the keywords present recorded)
verified ── Re-suggest Keywords ──► suggested       (new suggestions added, nothing removed)
any state ── Apply Keyword Judgements ──► golden    (exactly the judged keywords)
any state ── Clear Plugin Data ──► (none)           (fields only; keywords untouched)
```

`humanGenre` / `humanGenres` are set on **accept** (= the suggestion), on **correct** (= the
user's choice), and from an approved genres file.

### Smart collections for review

Created by `Set Up Review Collections` (`GrCollections`, R6.8; names and order ADR-027):
`Step 1 · Genres` with one grid per genre on `reviewGenres` (genre list, taxonomy reversed,
`1 Object` …), `Step 2 · Primary` with one grid per genre and one for No genre on `reviewGenre`
(primary, taxonomy order, No genre last), `Awaiting Review` (`suggested`), `Errors`, and
`Not Classified` (`reviewState` empty or `unclassified`), and `Personal Candidates` (`suggested`,
`personal` is `yes`, and any genre name in `reviewGenres`; ADR-028). The `Suggested Rating` set holds one grid per bucket
(`ratingBucket` is `3`, `2`, `1`, `0`; candidates for 3★ first), whatever the review state (ADR-029). The `Suggested Keywords` set holds `1 Keywords to Verify`
(`keywordState` is `suggested`) and `2 Keyword Errors` (`error`), made by Set Up and by the
keyword commands when missing (ADR-030). This is why `searchable = true` is mandatory; without it a field
cannot be a smart-collection criterion. The criteria syntax is in `architecture.md`.

## Identity and joins

`photo.localIdentifier` is the join key everywhere — log ↔ plugin metadata ↔ report.
It is stable within a catalog and carries no personal information.

## What is deliberately *not* stored

- **Probabilities** — ADR-004; the ranking with cut-off and floor marks is kept instead.
- **Request/response files** — deleted with the run's temp folder; the derived suggestion is enough.
- **Anything in XMP beyond the genre and vocabulary keywords** — plugin metadata cannot go to XMP anyway (ADR-001).
