# Decision Record

Short ADRs: context, decision, alternatives rejected, consequences. Each states the decision
as it stands; when a decision changes, the ADR is rewritten (or a new one replaces it), so
nothing here is superseded. Numbers are stable identifiers referenced from the code; missing
numbers are withdrawn decisions.

---

## ADR-001 — Keywords for the genres, plugin metadata for everything else

**Context.** The genres must be durable and portable; the suggestion and the review state
must be visible during review. Lightroom offers keywords and plugin custom metadata. Verified
against the SDK:
- Keywords are written to XMP and sidecars; whether one goes into *exported* files is its
  `includeOnExport` setting, chosen at creation.
- **Plugin custom metadata is stored only in the catalog.** It cannot be linked to XMP or
  written into files; it survives catalog backups, not catalog loss.
- A field with `searchable = true` is a smart-collection criterion; with `browsable = true`
  it is also a Library filter column.

**Decision.** Every genre a decision confirms is a `Genre > <Name>` keyword, created with
`includeOnExport = false`: the genres organise the catalog, they are not part of the delivered
picture, and a recipient has no use for them. The primary genre, the provenance of the
suggestion and the review state are plugin metadata (ADR-019, ADR-020).

**Rejected.** Genres in plugin metadata only — not portable, lost with the catalog, invisible
to Lightroom's keyword tooling. A flat `Genre:Street` keyword — loses the hierarchy. Colour
labels or collections as the carrier — five colours; collections are not metadata.

**Consequences.** The genres survive catalog loss through XMP; provenance does not. Exported
files carry no genre. Include on Export is a property of the keyword, so a person who wants
the genres exported ticks it on the `Genre` keywords; the plugin never changes it on an
existing keyword. Plugin metadata has no number type (`string`, `enum`, `url`), so anything numeric
is stored formatted.

---

## ADR-002 — Suggestions never touch the keyword tree

**Context.** Unreviewed model output could be written as keywords immediately, or held until
someone decides.

**Decision.** Classification writes **only** plugin metadata, with `reviewState = suggested`.
Keywords are written on accept or correction, or from an approved genres file (ADR-025).
Classification never removes a keyword either: genre keywords the user applied before
classifying are pre-tags (ADR-023).

**Consequences.** A genre keyword means "a person put this here". Abandoning a batch needs
no cleanup. Review filtering therefore uses smart collections over plugin metadata.

---

## ADR-004 — No confidence number; the model's ranking instead

**Context.** The model returns, for every genre, a probability that it is the primary and a
probability that it applies, with a tuned cut-off per genre. Nothing has measured what a given
probability means in accuracy on a catalog, and every rule the plugin applies needs only the
order and whether each genre reaches its cut-off.

**Decision.** No confidence is stored or shown. The plugin keeps the ranking: every genre in
the model's order of "most likely primary", with `*` where the genre reaches its cut-off, in
short form (`aiRanking`, e.g. `Por* Str* Eve Doc …`; ADR-023). The suggestion, the primary of
pre-tagged photographs and the place of an added genre all derive from it.

**Rejected.** Probabilities as text — no use without a measured meaning, and a smart
collection cannot compare text as numbers. High / medium / low buckets — the cut-offs would
be guesses.

**Consequences.** There is no "least sure first" review order and nothing to threshold, which
is consistent with no auto-accept (R6.6). Adding a confidence later means storing the
probabilities again, from a reclassification. The personal floor (ADR-028) is kept the same
way: a `+` mark where a genre also reaches it, not a number.

---

## ADR-005 — Renditions via `LrExportSession`, not `requestJpegThumbnail`

**Context.** `photo:requestJpegThumbnail` serves the preview cache: sizes are minimums,
quality is whatever the cache holds, and it is slow when previews are missing.
`LrExportSession` runs the real export pipeline with exact size, quality, colour space and
metadata-stripping controls.

**Decision.** `LrExportSession` into a per-run temp directory.

**Consequences.** Full control over size, quality, sRGB, an upright image, and
`LR_removeLocationMetadata`. Rendering, not the model, is most of the time per photograph.

---

## ADR-006 — Pure Lua; the bundled model is the one native program

**Context.** A Python or Node sidecar would make JSON and metrics easier, and the genre model
needs a native runtime to run an image encoder.

**Decision.** Everything the plugin does is Lua inside the bundle. JSON is `GrJson.lua`,
written in-house rather than vendored. The single exception is the bundled model runtime,
`model/localgenres`, launched through `GrCli` under ADR-021's constraints: a prebuilt program
whose source is not published (README, *Licence*).

**Rejected.** A sidecar process or service — an install step, version skew and a second
language at run time.

**Consequences.** Metrics are hand-written Lua (simple counting). Code must respect Lua 5.1.4.
Nothing needs installing besides the plugin and its model files.

---

## ADR-008 — An optional config file for settings

**Context.** The plugin has a few tunables (rendition size, chunk size, timeout, log level) and
no secrets: it needs no keys or accounts.

**Decision.** One optional JSON file, `~/.config/genreator/config.json`. Every value has a
default, so the plugin works without it; keys it does not know (from earlier versions) are
ignored.

**Rejected.** A settings dialog — more UI for values almost nobody changes. `LrPrefs` — hidden
inside Lightroom's preferences.

**Consequences.** Logs and reports live next to the file, under `~/.config/genreator/`.

---

## ADR-012 — The model's taxonomy; several Genres plus one Primary Genre

**Context.** A single genre per photograph forced artificial merges (Landscape with Nature,
Architecture with Object) to avoid ambiguity. The bundled model was trained on one fixed set
of genres and decides from the image alone: it never reads the definitions.

**Decision.**
- The genres, their order and the taxonomy version come from the model's own file,
  `model/taxonomy.json`. They are not editable: a renamed or added genre would be a genre the
  model has never seen. The definitions are documentation (`docs/taxonomy.md`); a different
  definition needs new judgements and a new model.
- A photograph has one Primary Genre among one or more Genres, or No genre (ADR-022).
- Genre fields are text, not enums, so a new model taxonomy needs no Lightroom schema change.
- Every suggestion records the model's version (`modelVersion`), so results from different
  models are never mixed.

**Alternatives.** `Genre > Primary > X` / `Genre > Secondary > X` keywords — a genre would
live in two branches, so "all Street photographs" stops being one filter. Editable
definitions — they no longer change what the model does, so editing them would mislead.

**Consequences.** Agreement has two levels: the primary (exact) and the genre list (set
overlap). Genre names are never hard-coded in the plugin; they are read from the taxonomy.

---

## ADR-013 — No keyword text reaches the model

**Context.** Keywords routinely carry real names and private context. The model was trained
on the image and one flag; nothing else would help it.

**Decision.** The model receives only a rendition of the photograph and the Personal flag
(ADR-024). Keywords are read locally for two things only — the Personal keyword tree and the user's
genre pre-tags (ADR-023) — and no keyword name is written to the request, the log or any
file outside the catalog.

**Consequences.** Nothing about a photograph leaves the computer; the request file in the
run's temp folder holds rendition paths and a true/false per photograph, and is deleted with
the folder.

---

## ADR-019 — One genre keyword branch; primary and secondaries as fields

**Context.** People search their photographs two ways: by primary genre, and by whether a
genre is present at all. A smart collection's Keywords rule matches keyword *names*, so it
cannot tell a primary genre from a secondary one, and it also matches any unrelated keyword
with the same name. The Library filter's Keyword column is hierarchical, so `Genre > Street`
answers "Street is present" exactly. A single text field holding the whole genre list would
appear in the filter as every combination of genres.

**Decision.**
- **Keywords.** One branch: `Genre > X` for every genre, the primary included, not exported
  (ADR-001). No keyword marks the primary or the secondaries, and No genre has no keyword.
- **Fields** `primaryGenre` (a genre, or `No genre`) and `secondaryGenres` (in priority
  order). Both are smart-collection criteria; Primary Genre is also a Library filter column.
  They are written only by `GrReview.run`, in the same write gate as the keywords and from the
  same `GrKeywords.wanted` result. Clear Plugin Data leaves them, as it leaves the keywords;
  Remove Genre Keywords empties them.
- **Update Genre Keywords** rewrites a selection's genre keywords and fields from its own
  `Genre` keywords and recorded primary, repairing hand edits. Running it again changes
  nothing.

**Alternatives.** A primary keyword branch — matched by name like any other, so it does not
solve the smart-collection problem, and duplicates the field. A `Secondary Genre` keyword
branch — a second copy of the decision that can drift. One field per genre with Primary /
Secondary values — fields are declared statically, while the genres come from the model.

**Consequences.** The primary does not survive the loss of the catalog. Smart collections:
"Primary Genre is Street"; "Primary Genre is No genre"; "Secondary Genres contains Street";
any role is the `Genre > Street` keyword in the Library filter. The fields restate the
keywords, so they can drift if keywords are edited by hand; Update Genre Keywords repairs them.

---

## ADR-020 — Metadata panel: only what a person uses, read-only

**Context.** Every plugin field with a title appears in the Metadata panel and, unless
`readOnly`, is editable there. A hand edit cannot be kept consistent: Review state set to
Accepted writes no keywords; an edited Primary Genre no longer matches the keywords; an edited
decision record falsifies quality measurement (R7.4).

**Decision.**
- **Shown, in this order:** Review state, Primary Genre, Secondary Genres, Under review:
  primary genre, Under review: genres, Error, Classified as personal (ADR-028: Personal
  Candidates searches it, and a search criterion needs a title), Suggested rating (ADR-029),
  Keyword review (ADR-030). "Under review" because after a decision these fields keep the
  last suggestion.
- **Read-only**, except Secondary Genres: Lightroom shows a read-only value on one line and
  cuts it off, and only an editable field wraps. Update Genre Keywords rewrites a hand-edited
  Secondary Genres from the keywords.
- **Hidden** (no title; still written, and read by the CSV report, Diagnostics and Correct):
  every other field `GenreatorMetadata.lua` declares — the suggestion and its ranking, the
  decision and its provenance, the rating's and the keyword review's details.
- Every searchable or browsable field keeps a title. `test_metadata_schema.lua` holds the
  panel list, its order, the read-only rule and `GrMetadata.FIELDS` equal to the declared
  fields.

**Alternatives.** Everything shown but read-only — cluttered, and long values are cut off.
Clearing the "under review" fields on decision — loses the record of what was suggested.

**Consequences.** Decisions are changed only through the menu commands. The suggestion, the
ranking, the model and its version are in the CSV report.

---

## ADR-021 — One classifier: the bundled local genre model

**Context.** Vision-language models prompted with written definitions could not hold the
boundaries one photographer draws between genres: rewording a definition moved the errors
rather than removing them. A small model trained on that photographer's own judgements, on
top of a general-purpose image encoder, learns the boundaries from examples instead; it runs
on the Mac in about 10 ms per photograph, and needs no network, account or key.

**Decision.**
- The plugin has one classifier: the bundled model in `Genreator.lrplugin/model/` — a native
  runtime (`localgenres`, macOS 14+, Apple silicon), the trained model (`model.json`), the
  taxonomy (`taxonomy.json`), a manifest with every file's SHA-256, and the image encoder
  (SigLIP2 base patch16/256, converted to Core ML).
- One process call per chunk of photographs: the plugin writes the request to a file in the
  run's temp folder (rendition paths, the Personal flag), runs `localgenres` through `GrCli`
  (quoted arguments, a fixed PATH, a hard timeout, its own working directory), and reads the
  response file. Cancel is passed to the running model through a cancel file.
- A response that names a genre outside the taxonomy, misses a photograph, or answers for
  another taxonomy is an error — never a nearest match. A model that fails as a whole stops
  the run; the remaining photographs stay unclassified.
- The encoder (185 MB) is larger than GitHub accepts in git, so it is a release asset that
  `make install` downloads (over HTTPS, a signed-in `gh` CLI as the fallback) and
  verifies against the manifest for a development install; a release zip includes it
  (ADR-026). Everything else is committed.
  `make model` imports a new model version and refuses one whose checksums differ.
- The model is subjective by design: trained on one photographer's judgements of one catalog
  (README, *About the model*).

**Rejected.** Ollama, subscription CLIs and cloud APIs as classifiers or cross-checkers — they
need the boundaries in words, take seconds per photograph, and (for the cloud) the
photographs leave the computer.
The encoder in Git LFS — a tool every clone needs, and a monthly bandwidth quota. A smaller or
8-bit encoder to fit in git — a re-export and a new accuracy measurement for a packaging
concern.

**Consequences.** No account or key; Check Model verifies the bundled model. The plugin needs
Apple silicon and macOS 14. A new model is a new set of files in `model/` (and a new release
only when the encoder changes). Its accuracy figures describe its author's catalog, not anyone
else's.

---

## ADR-022 — No genre is an answer

**Context.** Many photographs — ordinary family records, reproductions, informational shots
— have no photographic genre. Forcing one inflates the genres; leaving the photograph
undecided hides it from every filter.

**Decision.** `No genre` is a Primary Genre value with no genres and no keyword. The model
suggests it when its no-genre output reaches its cut-off, or no genre reaches its cut-off, and
the user tagged none (a pre-tag is present by the user's word, so it stands); Remove Genre on the
last genre under review leaves it; Set Primary Genre… and Correct Genres… offer it; an
approved genres file can record it. A decided No genre photograph is filterable: Primary
Genre *is* No genre. Every review ends in a genre or No genre.

A photograph never has genres without a primary once categorized. Before it is classified it
may carry the user's genre keywords with no primary; that state is transient.

**Rejected.** A Reject outcome ("wrong, but I cannot say what is right") — a rejected
photograph would be neither a genre nor findable as No genre. An `Unresolved` keyword — "no
genre" is not a genre.

**Consequences.** The value contains a space, so it can never collide with a genre (letters
only). The Quality Summary counts a change to or from No genre as a changed primary.

---

## ADR-023 — Genres in priority order; the user's pre-tags

**Context.** The model ranks every genre by how likely it is the primary, and says for each
whether it reaches its cut-off. Users know some genres before classifying, but a tag means
"this genre is present", not "this is the primary".

**Decision.**
- The suggested genres are those reaching their cut-off **plus** the genres the user tagged
  (`Genre > X` keywords present when classifying), in the model's ranking order — only the
  tagged ones when the model's no-genre output reaches its cut-off; the first is
  the primary. On personal photographs a genre must also reach the model's recommended floor
  (ADR-028). So a pre-tag the model ranks as the most likely primary is the primary even
  when other genres apply; when nothing reaches a cut-off, the pre-tag the model ranks highest
  is the primary; with no pre-tags either, the suggestion is No genre.
- Genre lists keep that order: removing the primary under review promotes the next genre in
  it; Add Genre places a genre by it (`aiRanking`). Without a ranking, taxonomy order applies.
- Classification and reclassification never remove a genre keyword. The user's pre-tags are
  the genre keywords present at a photograph's **first** suggestion (`userGenres`), never
  changed by a reclassification; genre keywords the plugin wrote for a decision are never
  pre-tags, so a reclassification after a model update shows the new model's own answer, not
  the earlier decision fed back.
- A genre keyword the user adds by hand after the first suggestion, outside review, is a
  *later* user genre (`laterUserGenres`, kept while the model is tuned, to tell corrections
  from pre-selections). It joins the next suggestion like a pre-tag, and Accept and Set
  Primary Genre… keep it — becoming the primary when the decision was No genre — so it is
  never removed silently. Correct Genres… (an exact list), an explicit No genre, and Remove
  Genre in review are the user's word and may drop it.
- The user may still remove a pre-tag in review.

**Rejected.** Pre-tags always winning the primary — tagging a minor genre (Object for a
detail) would force it to primary, and a pre-tag would stop meaning "present". A separate hint
keyword branch — two trees with the same names, and hints left behind after acceptance.

**Consequences.** A pre-tagged, unreviewed photograph already has Genre keywords; "reviewed" is
the Review state, not the presence of a keyword.

---

## ADR-024 — Personal is the user's tag, and the model's known-person input

**Context.** Whether a photograph is personal — of people the photographer knows, or of
personal significance — changes how it is judged, and cannot be seen in the pixels. Lightroom
person keywords are not a reliable signal: named strangers make a photograph no more personal,
and personal photographs often have no person in them.

**Decision.** A photograph is personal when it carries the Personal keyword or any keyword
nested under it. The keyword is configurable (`personalKeyword`, a name or a path such as
`Me > Personal`, anchored at the top of the keyword tree), default `#PERSONAL` — the root the
training data kept its known people under. Set Up Review Collections creates it
when missing; the plugin otherwise only reads it, never assigning or removing it. The flag is
the model's one input besides the image (its "known person" flag). Classify reports how many
photographs of the run are personal and asks to confirm, since an untagged photograph is
treated as not personal. A person keyword counts only through where it sits in the tree.

**Rejected.** Person keywords (`keywordType = person`) as such — wrong in both directions, as
above. A fixed plugin keyword (`Genreator > Personal`) — a parent holding one child, and blind
to a tree the user already keeps. A plugin field set by a menu command — slower than a keyword
set or the painter, and invisible to the Keyword filter.

**Consequences.** The user controls "personal" by where keywords sit: known people under the
Personal keyword, everyone else outside it; a personal photograph with nobody in it carries
the keyword itself. The model was trained with this flag set from person keywords; where the
two disagree, its answers are less certain than its measured accuracy suggests. The README
says so. With the default, the flag matches the training input, plus the photographs tagged
`#PERSONAL` or a non-person keyword under it.

---

## ADR-025 — Approved genres files

**Context.** A photographer may already have judged photographs outside the plugin — for
example the judgements a model was trained and tested on. Re-reviewing them in Lightroom
would repeat work and could drift from the originals.

**Decision.** *Apply Approved Genres…* reads a JSON file of `{photo_uuid, file_base, primary,
genres}` items and applies each as a decided photograph (`accepted`, with keywords and genre
fields), overriding whatever genres it had. A photograph is matched by its Lightroom UUID and
must have that file name; anything else is skipped and reported, never guessed. A file for
another taxonomy is refused. The decision's source is `approved:<fingerprint of the file>`:
applying the same file again changes nothing, and a newer file updates exactly what differs.

**Rejected.** Matching by local photo ID — it changes when a catalog is rebuilt. Keeping the
user's later changes over a newer file — the file is the user's own considered judgement,
and the user chose for it to win.

**Consequences.** Such files hold per-photograph data from a catalog; they stay on the user's
computer and are never part of the repository. The Quality Summary counts these decisions
apart: no suggestion was judged.

---

## ADR-026 — One release zip per plugin version; the user clears quarantine

**Status.** Accepted 2026-10-28; built 2026-11-20 for the public release.

**Context.** Users should not need a developer's toolchain (`git`, `make`, `luajit`, the GitHub
CLI) to install a Lightroom plugin. Shipping the whole plugin — the model and its encoder
included — as one release file removes it. But a zip downloaded in a browser is quarantined,
and so is everything unzipped from it; `localgenres` is not notarized, so macOS may refuse to
run it when Lightroom launches it. A `git clone` sets no quarantine.

**Decision.**
- Each plugin release is one zip, `Genreator-<version>.zip` (the version from `Info.lua`): the
  complete `Genreator.lrplugin` (Lua files, `model/` with the encoder) with `LICENSE`,
  `THIRD_PARTY_NOTICES.md` and `licenses/` beside it. Users unzip it and install the folder
  by hand; the README says how. `make release` builds it from a bundle whose every file,
  the encoder included, matches the manifest.
- After unzipping, the user removes the quarantine flag once with
  `xattr -dr com.apple.quarantine Genreator.lrplugin`. The README gives the command, and Check
  Model names it, with the plugin's own path, when the runtime does not start.
- `make install` is for development only, and its requirements are in `docs/development.md`.
  It takes the encoder from a release of its own, tagged `encoder-<id>` (ADR-021), not from a
  plugin release: any commit then installs the encoder its manifest names, and the encoder is
  uploaded only when it changes.

**Alternatives.** Notarizing the runtime — the clean fix, but it needs an Apple Developer
account and has to happen where the runtime is built; revisit when the runtime can be notarized
where it is built. The plugin clearing the flag itself — it would launch a second program
(`xattr`), loosening "the model runtime is the only process" (ADR-006), and teach a habit of
silently overriding Gatekeeper. Developers taking the encoder from the latest plugin release —
one kind of release, but a commit whose encoder differs from the latest release could not
install until a new release is out.

**Consequences.** One manual Terminal command per installed release, documented. About 175 MB
per release, the encoder repeated in each; the Releases page also lists the encoder releases.
Whether macOS blocks the runtime of a browser-downloaded zip is checked by hand
(`development.md`, *Verifying in Lightroom*).

## ADR-027 — Review collections in the order of the work; a review trail to revisit it

**Status.** Accepted 2026-11-02. To be revisited on the trail's data (below).

**Context.** Lightroom sorts a collection set's contents by name, so the review collections
showed alphabetically: Awaiting Review, Errors, Not Classified, Review by Genre, Review by
Primary Genre, with `Primary: No genre` in the middle of the genres. Within a step the order of
the grids does not change how many commands the review takes — a wrong genre costs one Remove
Genre in whichever grid it is removed, and each photograph is in one primary grid — but it
does change how easy each judgement is. What does change the count is the order of the steps
and where Accept is chosen. Measured on the 2,204 decisions of 2026-11-02 (the model and picks of that date):

- Wrong genres are extras, not misses: genres were removed about 1,300 times, added 18 times.
  The extras are mostly the low-precedence genres on photographs whose primary is a higher
  one (Portrait 186, Object 176, Architecture 135 removed where the primary was Street).
  Object loses 75% of its suggestions in review, Architecture 67%, Portrait 61%; Street 27%.
- Of 202 wrong suggested primaries, the right one was already in the suggestion for 147
  (73%): removing the wrong genres promotes it, with no dialog. 39 were No genre.
- When two genres both apply, the user's primary follows Street → Portrait → Event →
  Documentary → Landscape / Architecture → Nature → Object (e.g. Street over Architecture
  78:14, Portrait over Event 34:17, Documentary over Object 28:0, Landscape over Nature 34:12)
  — the taxonomy's own order. About 1,300 of those decisions are acceptances, which can pull
  this toward the model's ranking.

**Decision.**
- Lightroom lists a set's sub-sets before its collections, each by name (seen 2026-11-02), and
  the panel is narrow. The steps are sets named for their place, `Step 1 · Genres` and
  `Step 2 · Primary`; each grid is named by its number and genre only (`1 Object`), the set
  saying what it is for. Remove Genre knows a genre grid by its set. The overview collections
  keep their plain names (`Awaiting Review`, `Errors`, `Not Classified`): their order does
  not matter to the work.
- Step 1's grids are the taxonomy reversed (`1 Object` … `8 Street`): the grids
  most often wrong first, while attention is fresh, and the genres that pass for each other —
  things and places, then people — side by side.
- Step 2's grids are the taxonomy order, the user's fallback sequence, with No genre last
  (`1 Street` … `9 No genre`): each grid asks whether nothing earlier in the
  sequence should win.
- Accept is chosen once, at the end, in `Awaiting Review`, rather than once per primary grid.
- Both orders come from the taxonomy file (ADR-012). Set Up Review Collections removes the
  plugin's own smart collections whose names are no longer current (its rule searches only
  plugin fields), and a set it leaves empty; the user's collections are never touched.
- **A review trail** (hidden field `reviewTrail`, temporary): each review command on a
  photograph — `rm:X`, `add:X`, `primary:X`, `correct:X`, `accept` — with its time, the size
  of the selection it ran on and the grid it was chosen in. A new suggestion starts it
  afresh. It is in the CSV report (`review_trail`).

**Alternatives.** Numbering the overview collections too (`1 Not Classified` … `5 Errors`) —
tried first: Lightroom puts the sets above them anyway, and their order mattered to no one.
Grid names with the step in them (`1 Genre: Object`) — cut off in the panel. Alphabetical with
only No genre moved last — keeps the step-2 fallback
sequence broken. Grids ordered by how often each genre is corrected — computed at set-up and
changing between runs, and it saves no command. The same order for both steps — step 1 is
about extras, which cluster at the low end of the precedence, step 2 about precedence itself.
A precedence order of the user's own in the config — premature while the measured one equals
the taxonomy's.

**Revisiting.** When at least 300 photographs have been decided with a trail, and at least 20
for each suggested primary, export the CSV report and measure, against this ADR's figures:
1. Commands per decided photograph — trail entries grouped by time, command and `n`, so one
   command on a selection counts once — per grid and overall.
2. The fallback rate: wrong suggested primaries put right by removals alone (no `primary:` or
   `correct:` entry), against the 73% above.
3. The precedence table again, on `corrected` decisions only (an acceptance anchors to the
   model): a pair with at least 15 photographs where the user's winner differs from the
   taxonomy order at 70% or more.
4. Whether the grids are worked in their numbered order (trail times), and where Accept is
   chosen (`@` of `accept`).
Change the order only if the data shows a different one would save at least 10% of the
commands, or the precedence differs from the taxonomy's; record it as a new ADR replacing
this one. Then remove the trail writes (the field stays declared until a schema clean-up).

**Consequences.** Existing review collections are replaced on the next Set Up; a smart
collection holds no photographs of its own, so nothing is lost. Remove Genre recognises a
genre grid only by its set and numbered name. The trail adds one field write per photo
per review command, inside the command's existing write gate.

---

## ADR-028 — A higher bar for genres on personal photographs

**Status.** Accepted 2026-11-03, with model version `2026.11.03-0dd9ce57-338394-2`. Model
version `2026.11.05-6466afd6-2ad389` keeps the floor at 0.50, re-measured on the re-judged
held-out personal photographs (`docs/model.md`): that model already answers No genre
on most personal photographs, so the floor now changes little (suggested genres right 67%
against 62%, 30 against 34 suggestions on 124 photographs). The table below is the 2026-11-03
measurement that motivated the rule.

**Context.** Genres on personal photographs serve a different purpose from genres on the
rest of the catalog. Their tagging is looser; the point is not to miss the few personal
photographs that are real candidates for a genre, and most older ones lack the capture
quality to be one. The model's cut-offs were tuned for the whole catalog, where an extra genre
is cheap; on personal photographs they suggest many genres that are not there. The model now
comes with a recommended **floor** for personal photographs (`personal_floor` in its
manifest, 0.50 for this version), measured on its author's judgements of photographs held out
of training (124 personal photographs, person keywords standing in for the Personal flag):

| On personal photographs | Model's cut-offs | Floor 0.50 |
|---|---|---|
| Suggested genres that are right | 57% (119 of 210) | 85% (101 of 119) |
| Author's genres found | 88% | 75% |
| Genres suggested per photograph | 1.69 | 0.96 |
| Author's primary not suggested | 7 of 105 | 15 of 105 |
| No-genre photographs given no genre | 7 of 19 | 11 of 19 |

These figures are the model's at acceptance; the current model's are in `docs/model.md`.

**Decision.**
- On a photograph classified as personal (ADR-024), a genre is suggested only when its
  applicability reaches its cut-off **and** the floor; the primary is the first genre left in
  ranking order, and with none left the suggestion is No genre. The no-genre answer comes
  first, unchanged: when it reaches its own cut-off the suggestion is No genre whatever the
  genres score; the floor never applies to it. Pre-tags still count (ADR-023). Photographs
  that are not personal keep the model's cut-offs.
- The floor is the model's, read from the bundled manifest of the version in use, never
  written in code; `make model` carries it over and refuses one that is not a number from 0
  to 1. A model without a floor has none, and its cut-offs apply.
- One setting, `personalFloor` in the config file: `recommended` (default) or `off` (the
  model's cut-offs alone).
- The ranking keeps what re-deriving needs without storing a number (ADR-004): `+` after `*`
  where a genre also reaches the floor, and a last token naming the floor it was marked for
  (`Por*+ Str* Eve … floor=0.5`). It is written whatever the setting. *Re-derive Personal
  Suggestions* applies a changed setting to the selection's personal photographs awaiting
  review, from the ranking, without the model; a decision stands (R2.7), and a ranking stored
  before the model had a floor needs Reclassify.
- The Personal flag the model was given is kept: `personal` (`Classified as personal` in the
  Metadata panel, searchable), and with each review decision `decisionPersonal`. Decisions on
  personal photographs stay identifiable: they are feedback on the model, not new training
  examples. Review itself is unchanged.
- *Personal Candidates*, a staging collection in the Genreator set: classified as personal,
  awaiting review, with a genre in the list under review — the real genre candidates among
  the personal photographs. Like the review grids it empties as they are decided (or lose
  their last genre); decided ones are found by *Classified as personal* and Primary Genre.

**Alternatives.** A floor in the plugin's own config — the floor belongs to the model it was
measured on, and a new model may bring another. Storing the applicabilities in the ranking —
re-deriving needs only "over the floor", and numbers without a measured meaning are what
ADR-004 keeps out. A floor on every photograph — the cut-offs were tuned for the rest of the
catalog, where missing a genre costs more than an extra one. Personal Candidates searching
the Personal keyword — the rule would name the keyword the config names, and the floor went
by the flag sent to the model, not the keyword now. Personal Candidates as a
lasting filter that also keeps decided photographs (tried first) — it could never be emptied,
so it did not work as a step of review. Re-deriving inside
Reclassify — Reclassify re-renders on purpose (develop changes alter the rendition).

**Consequences.** Fewer genres to remove on personal photographs, and more left for Set
Primary Genre…; with the current model the floor changes little (`docs/model.md`), and Set
Primary Genre… is the usual route on personal photographs. Personal
photographs classified before this version have no floor marks: Reclassify them to apply the
floor. The flag recorded is the one the model was given; a photograph tagged or untagged
Personal since needs Reclassify for the flag and the floor to follow. Two fields added
(schema 18).

## ADR-029 — A suggested rating, by its own command, in plugin fields, never the star

**Status.** Accepted 2026-11-05. Model `2026.11.05-6466afd6-2389c1` is the first with a rating
head; schema 19. Model `2026.11.06-6466afd6-4bdd6c` (2026-11-06) retrains the head on 32,687
photographs from 2005 on, ships a third ratio (3) and makes 2 the default; the plugin reads
both from the manifest, so it took the model with `make model` and no code change.

**Context.** The model's producer now ships, in the same model file and the same call as the
genres, a rating head: a score trained on the author's own star ratings under their current
rating convention, and a bucket from 0 (likely 0★) to 3 (a candidate for 3★ and above) under
geometric bucket sizes, each star bucket 1/ratio the size of the one below. Every ratio the
model ships has its thresholds in the model file, and the model names a default ratio (its
current figures: `docs/model.md`). 1★ against 2★ is weak. It is a personal-taste
model: it imitates one author's ratings and nothing else. A rating could be written with
every classification.

**Decision.** Rating is **a separate action**, *Suggest Ratings*, at least for now: Classify
and Reclassify write no rating, and Suggest Ratings changes no genre suggestion, review state
or decision. It renders the selection and runs the same model call (`GrClassifier.scoreChunk`),
whatever the review state, and reads only the rating from the answer; a malformed rating fails
that photograph's rating, never a classification. The suggestion lives in plugin fields and
never touches the Lightroom star rating, as the genres never touch anything but their keywords
(ADR-001, R5.6): `ratingBucket` (shown as *Suggested rating*, searchable and in the Library
filter: `0`–`3` under the chosen ratio), and hidden `ratingRatio`, `ratingScore`,
`ratingBuckets` (the bucket under every shipped ratio, `1.5=3 2.0=2`) and `ratingModelVersion`.
Clear Plugin Data blanks them; the CSV report carries them. The bucket ratio is the user's
setting `ratingRatio` (`recommended` = the model's default, or a ratio the model ships); a
ratio the model does not ship falls back to the default, said in the confirmation and the log.
A photograph the bundled model already rated is not rendered again: its bucket is re-derived
from `ratingBuckets` when the ratio changed, else it is skipped; a new model rates it afresh. A
failed rating leaves the fields as they were and is counted in the summary, not marked in the
review state, which belongs to the genres. *Set Up Review Collections* adds a `Suggested
Rating` set with one grid per bucket, candidates first, that ignores the review state. The
bundle's manifest keeps the rating head's identity (`rating`: default ratio, shipped ratios
with thresholds, training identity), so *Check Model*, Diagnostics and Suggest Ratings read it
without the large model file; the import refuses a rating block whose default ratio is not
among its thresholds.

**Alternatives rejected.** Writing the rating with every classification: a rating round and a
genre round are different work on different selections, and coupled, rating an
already-classified photograph would take Reclassify, which refreshes its genre suggestion too.
Writing the star rating (the plugin's rule is suggestions only; the author rates). Marking a
failed rating in the review state (it belongs to the genres). Reading the thresholds from
`model.json` in the plugin (large file, and the runtime already answers the bucket per ratio).
Restricting the rating grids to photographs awaiting review (ratings are wanted on decided
photographs too). A rating-ordered collection (a smart collection cannot sort by a plugin
field; the per-bucket grids give the order).

**Consequences.** Five fields added (schema 19), a new menu file: a full Lightroom restart.
Rating a photograph costs a render and a model call of its own, even right after classifying
it. A new model brings new thresholds, and the figures in `docs/model.md` are the producer's
out-of-fold figures.

## ADR-030 — Keyword suggestions, written as keywords at the taxonomy's paths, with a review state

**Status.** Accepted 2026-11-06; schema 20.

**Context.** The model's producer publishes a keyword model beside the genre model: the same
genre and rating heads plus a keyword head, answered in the same runtime call, with its own
keyword taxonomy (75 leaf keywords in 6 categories at v0.14, in `Category > Subcategory >
Keyword`) and the author's own keyword judgements of 570 photographs (562 used in training).
The author decided to bring keywording into this plugin, with the keyword categories at the
root of the Lightroom keyword list. Keywords differ from genres on purpose: a keyword is a
descriptive fact the author vets in a grid by editing keywords, not a judgement with one right
answer; the vetted keyword set is what a later model learns from.

**Decision.**
- **Bundle.** The plugin bundles the keyword model's `model.json` in place of the genre
  model's, so one call serves genres, rating and keywords, while the keyword model's genre
  model id equals the genre model's. `make model FROM=<genre folder> KEYWORDS=<keyword
  folder>` checks both folders' checksums, that pairing, and that both use the same runtime and
  encoder; it keeps the genre folder's taxonomy, floor, rating block and version, and adds a
  `keywords` block (version, model id, keyword taxonomy version) and a published
  `keyword-taxonomy.json` (version and keywords: id, name, category, subcategory, general
  form, definition; nothing of the model's making). The judgements file is never bundled.
  Without `KEYWORDS` the bundle has no keyword head and the keyword commands say so.
- **Commands** (Library menu, after Suggest Ratings): *Suggest Keywords*, *Mark Keywords
  Verified*, *Re-suggest Keywords*; File menu: *Apply Keyword Judgements…* (R10).
- **Written at once.** Suggested keywords are assigned as Lightroom keywords when suggested,
  unlike genres (R5.3): the review is editing keywords in a grid and marking it verified.
  Per photograph: `keywordState` (`suggested`, `verified`, `golden`, `error`; a string, not an
  enum, so Clear Plugin Data can blank it; shown as *Keyword review*, searchable, in the Library
  filter), and hidden `keywordSuggestion` (`v1|<keyword model version>|<taxonomy version>|<rule>|<time>|
  <ids>|<agreed ids>|<implied ids>`, ids comma-separated in the model's order),
  `keywordDecided` (`v1|<source>|<time>|<ids>`, the source `verified` or
  `golden:<fingerprint>`) and `keywordError`.
- **Suggest Keywords.** No state or `error`: add the suggested keywords not present. `suggested`:
  re-synchronise (R10.4). `verified`, `golden`: skipped and counted. A per-photograph error
  leaves keywords unchanged and records the message; it sets `error` on a photograph without a
  keyword state (or already in error), while one awaiting verification or verified keeps its
  state, so a failed rerun never drops it from its grid or its decision. Keywords are created in one
  gate per chunk before a second gate assigns them (a keyword created in a gate cannot be
  assigned in it; a repeated `createKeyword` in one gate can return nil), the state re-read
  inside the gate so a photograph decided meanwhile is skipped. The Personal flag is not read:
  the keyword head reads the image only.
- **Tree.** Keywords at their taxonomy path from the root, not exported, existing ones reused
  unchanged. A specific keyword is assigned **with its general keyword** (Sailboat with Boat):
  checked in Lightroom on 2026-11-06, filtering by the general keyword does not find a
  photograph tagged only with the specific one, so the plugin assigns both — on suggestion,
  re-suggestion and from judgements (which list only the specific one) — and re-synchronising
  removes both when the suggestion goes. Categories and subcategories are never assigned.
- **Collections.** *Set Up Review Collections* and Suggest Keywords create a `Suggested Keywords` set in
  the `Genreator` set with *Keywords to verify* (`keywordState` is `suggested`) and *Keyword
  errors*.
- **Judgements.** As ADR-025 for genres, except that a newer file yields: matched by
  UUID and file name, `schema_version` 1 and the bundled keyword taxonomy's version; exactly
  the listed taxonomy keywords; source `golden:<fingerprint of the file>`; the same file again
  changes nothing; a newer file yields to a change the user made since the last application.
- **Setting** `keywordRule`: `balanced` (default, the model's best-F1 rule) or `recall_first`.

**Alternatives rejected.** Suggestions staged in plugin fields until accepted, as for genres:
the author vets keywords by editing them in a grid, which a staged list would turn into a
second editor beside the Keyword List. Keywords with Classify: a keyword round, a genre round
and a rating round are different work on different selections (as ADR-029). One plugin root
above the categories: hides the author's own structure; rejected by the author. Remembered
removals and a per-catalog state file: the vetted set carries the same
signal, and exclusions would fight re-synchronisation. Two model calls, one per bundle: twice
the encoder work for identical genre heads.

**Consequences.** A new requirement area (R10) and a revised R1.2 and R5.6; four fields
(schema 20) and four menu files, so a full Lightroom restart. The footprint grows by the
keywords at the keyword taxonomy's paths. A keyword deleted in the Keyword List is created again
at the next suggestion; stopping a keyword is the model's job. Unverified photographs collect in
*Keywords to verify* until marked; a `suggested` photograph edited but not marked is
re-synchronised by the next Suggest Keywords, which can undo an unmarked removal — mark the
grid before running it again. A genre model update without a matching keyword model drops the
keyword head until the producer publishes one.
