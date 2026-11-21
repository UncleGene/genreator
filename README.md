# Genreator

A Lightroom Classic plugin that suggests a **photographic genre** for each photograph, so
that its star rating has a defined context: a photograph that would be a weak landscape may
be a strong street photograph. You review the suggestions in Lightroom's own grids; only the
genres you accept become keywords. (Suggested descriptive keywords, an optional round of their
own, are added at once for you to vet.)

A genre is not a detected object. A cow is not a genre: what the photograph is *for* decides
the genre. Descriptive keywords (Reflection, Fog, Bird, Bridge, …) are a separate, optional
round with their own commands, from the same model's keyword vocabulary.

- **Genres** — every genre a photograph meaningfully works as, in priority order.
- **Primary Genre** — the one standard its star rating is judged by: the first of its
  genres, or **No genre** when none applies.

The genres are Street · Portrait · Event · Documentary · Landscape · Nature · Architecture ·
Object, as defined in [`docs/taxonomy.md`](docs/taxonomy.md).

Classification runs on a **local model bundled with the plugin**: your photographs never
leave your computer, and there is no account, key or service to set up.

> **The genres and the model are one photographer's opinion.** There is no correct answer to
> "is this street or documentary?". The definitions are the author's deliberately opinionated
> view, and the model learned the author's own judgements of the author's own catalog. On
> another photographer's catalog, or for another person's idea of the genres, expect
> different and probably worse suggestions. Treat them as a starting point for your review,
> not as an objective classification. See [About the model](#about-the-model).

---

## Requirements

- **Adobe Lightroom Classic** (developed on current versions; SDK 6 or later).
- **macOS 14 or later on Apple silicon.** The model runs on Core ML; Intel Macs and Windows
  are not supported.
- A network connection once, to download the plugin (about 175 MB).

## Install

1. Download `Genreator-<version>.zip` from the latest release:
   <https://github.com/UncleGene/genreator/releases/latest>.
2. Unzip it (double-click in Finder). It holds the plugin folder, `Genreator.lrplugin`, and
   its licence files.
3. Move `Genreator.lrplugin` to where it will stay — for example
   `~/Library/Application Support/Adobe/Lightroom/Modules/`, where Lightroom loads it by
   itself. Anywhere else, add it once in *File ▸ Plug-in Manager… ▸ Add*.
4. Let macOS run the bundled model program. A downloaded zip carries macOS's quarantine flag,
   and the program is not notarized, so macOS may refuse to start it. In Terminal, run once,
   with the folder's real location:

   ```bash
   xattr -dr com.apple.quarantine ~/Library/Application\ Support/Adobe/Lightroom/Modules/Genreator.lrplugin
   ```

   (Type `xattr -dr com.apple.quarantine ` and drag the folder onto the Terminal window to
   fill in its path.)

   If you skip this step, macOS shows *“localgenres” Not Opened* the first time the model
   runs, and Lightroom waits until you answer it. Click **Done**, not *Move to Trash* (that
   deletes the model program, and you would need to unzip the release again), then run the
   command above.

5. **Restart Lightroom Classic** fully (quit and reopen) and check:

   - *File ▸ Plug-in Extras ▸ **Check Model*** — the model is complete and runs.
   - *Help ▸ Plug-in Extras ▸ Show Genreator Diagnostics* — what loaded, and the settings.

**Updating:** quit Lightroom, replace the folder with the new release's, run step 4 again, and
reopen Lightroom. Your genres and review state live in the catalog and are kept.

No configuration is needed. To change a default (rendition size, photographs per model call,
log level, the Personal keyword, the personal floor, the rating bucket ratio), copy
`Genreator.lrplugin/config.example.json` to `~/.config/genreator/config.json` and edit it.

## Suggested workflow

### 1. Set up

*File ▸ Plug-in Extras ▸ **Set Up Review Collections*** creates the `Genreator` collection set,
and the **Personal keyword** if it does not exist yet: `#PERSONAL` at the top of the keyword
tree, or the keyword you name in the config file (`personalKeyword`, e.g. `"Me > Personal"`).

### 2. Tag your personal photographs — before classifying

A photograph is **personal** when it carries the Personal keyword **or any keyword nested
under it**. Apply it to personal photographs — of people you know, or of personal significance
(a keyword set or the Painter makes this quick). The model weighs a personal photograph
differently, and it cannot see from the pixels who someone is.

Nesting is how you decide what counts. Keep the people you know as keywords under the Personal
keyword (`#PERSONAL > Family > Anna`) and tagging them marks the photograph personal; keep a
person keyword elsewhere (a stranger you named, a performer) and it does not. A personal
photograph with nobody in it takes the Personal keyword itself.

A photograph without it is treated as **not personal**. Classify tells you how many
photographs of the run are personal before it starts.

Personal photographs are held to a **higher bar**: a genre is suggested on one only when the
model rates it at least its recommended floor (0.5 for the bundled model) as well as its
cut-off. Most family photographs then come out as No genre, and the personal photographs
left with a genre are real genre candidates — the `Personal Candidates` collection gathers
those awaiting review, and empties as you decide them or remove their last genre. To use the model's cut-offs alone, set `"personalFloor": "off"` in the config file,
then run *File ▸ Plug-in Extras ▸ Re-derive Personal Suggestions* on the photographs awaiting
review: it applies the setting from the stored ranking, without running the model again.

### 3. Optional: tag genres you already know

If you know a genre is present, apply the `Genre > X` keyword yourself before classifying. A
pre-tag says "this genre is present", not "this is the primary":

- it is always among the suggested genres, placed where the model ranks it;
- the model's ranking still decides the primary;
- if the model finds no genre at all, the pre-tag it ranks highest becomes the primary;
- classifying or reclassifying never removes it (you can, in review);
- the same goes for a genre keyword you add by hand later: the next suggestion includes it,
  and *Accept* keeps it.

The plugin's own genre keywords — written when you accepted or approved a decision — are not
pre-tags: reclassifying a decided photograph after a model update shows the new model's own
answer.

### Before writing genre keywords in bulk: pause sync

Lightroom's cloud sync carries keywords when the catalog's *Sync keywords* option is on
(*Preferences ▸ Lightroom Sync*); it does not carry the plugin's fields. So pause sync (cloud
icon, top right) before a command that writes genre keywords to many photographs — **Accept
Suggestion** on a grid, **Set Primary Genre…**, **Correct Genres…**, **Apply Approved
Genres…**, **Update Genre Keywords**, **Remove Genre Keywords** — and resume it afterwards if
you want. Classify, Add / Remove Genre in review and Clear Plugin Data write plugin fields
only and do not touch sync. The plugin cannot pause sync itself (the Lightroom SDK offers no
way to); Apply Approved Genres… reminds you in its confirmation.

### 4. Classify a batch

Open `Genreator ▸ Not Classified`, select a batch and choose *Library ▸ Plug-in Extras ▸
**Classify Selected Photos***. You can cancel at any time; to continue later, classify the
same photographs again — finished ones are skipped and errors retried.

Classification writes **only suggestions** (plugin metadata). No keyword is written or
removed until you decide. Expect most of the time to go to rendering the photographs; the
model itself takes about 10 ms per photograph after a 2-second start per batch.

### 5. Review by genre

Open `Genreator ▸ Step 1 · Genres` and work through its grids in their numbered order: the
genres most often suggested wrongly come first. Each grid (`1 Object`, …) shows every
photograph with that genre among its suggested genres. Select the ones that do not belong and choose **Remove
Genre** — inside a genre grid it removes that genre without asking; where most are wrong, select all
and deselect the right ones. If a genre is missing, select the photographs and choose **Add
Genre…**.

These edits change only the suggestion under review. Removing a photograph's primary
promotes the next genre in priority order — usually the right primary — and removing its
last genre leaves **No genre**.

### 6. Review by primary genre

Open `Genreator ▸ Step 2 · Primary`. Each grid (`1 Street`, …) shows the photographs whose
suggested primary is that genre, in the order one genre wins over another when both apply,
and `9 No genre` (last) those with none.

- **Primary is wrong?** Select those photographs and choose **Set Primary Genre…**. The genre
  you pick becomes the primary directly; each photograph keeps its other genres. Choosing
  *No genre* clears them.
- **Not a genre photograph at all?** *Set Primary Genre… ▸ No genre* clears its genres in one
  step.
- **The rest are right:** when every grid is done, open `Genreator ▸ Awaiting Review`, select
  all and choose **Accept Suggestion** — once for everything left. This writes the keywords,
  with your step-5 edits.

**Correct Genres…** gives full control (a primary plus a genre list) but applies the same
answer to every selected photograph.

Tip: every command can get a keyboard shortcut in *System Settings ▸ Keyboard ▸ Keyboard
Shortcuts ▸ App Shortcuts* (use the exact menu title).

### 7. Use the result

| You want | Library Filter ▸ Metadata | Smart collection rule |
|---|---|---|
| Street as the primary | **Primary Genre** column | Primary Genre *is* Street |
| Photographs with no genre | **Primary Genre** column ▸ No genre | Primary Genre *is* No genre |
| Street in any role | **Keyword** column ▸ Genre ▸ Street | *match any*: Primary Genre is Street; Secondary Genres contains Street |
| Street, but not as the primary | — | Secondary Genres *contains* Street |
| Reviewed or not | **Review state** column | Review state |

What is written on a decision:

- `Genre > X` keyword for every genre, primary included. It is **not exported**: exported
  files carry no genre. To export the genres, tick *Include on Export* on the `Genre` keywords
  (Keyword List ▸ right-click ▸ Edit Keyword Tag).
- **Primary Genre** (a genre, or *No genre*) and **Secondary Genres** (the other genres, in
  priority order) plugin fields. Plugin fields live only in the catalog.

Nothing else in your catalog is touched: no ratings, flags, labels, develop settings or other
keywords.

### Rating with the suggested rating

Rating is a separate round from the genres. Select a batch and choose *Library ▸ Plug-in
Extras ▸ **Suggest Ratings***: the model rates each photograph, whatever its review state,
into a **Suggested rating** field — a bucket from `0` (likely 0★) to `3` (a candidate for 3★
and above), from a score trained on the author's own star ratings (see [`docs/model.md`](docs/model.md)).
Classify never writes it, and Suggest Ratings never touches the genres or their review. It is
a suggestion in a plugin field; your star rating is never written. Tag personal photographs
first: the Personal flag is an input to the rating too.

*Set Up Review Collections* adds a `Suggested Rating` set with one grid per bucket, candidates
first: start a rating round in `1 Candidates for 3★`, and look at `4 Likely 0★` last, if at
all. The Library filter's *Suggested rating* column and smart collections on the field work
too. The buckets' sizes follow a ratio (each star bucket 1/ratio the size of the one below):
the model's default is 2, about one photograph in fourteen (taken from 2025 on) as a
candidate; `"ratingRatio": 1.5` in the config file makes it about one in eight, `3` about one
in thirty. Older years get fewer candidates, as they hold fewer good photographs. Running Suggest Ratings again skips
photographs this model already rated and, after a change of `ratingRatio`, re-derives their
bucket from the stored ones without the model. A new model rates them afresh.

### Keywording with suggested keywords

Keywording is a round of its own too. Select a batch and choose *Library ▸ Plug-in Extras ▸
**Suggest Keywords***: the model suggests up to three keywords per photograph from its fixed
vocabulary (75 keywords in 6 categories, see [`docs/model.md`](docs/model.md)) and adds them **as keywords at
once**, under their categories at the root of your keyword list — for example `Visual Features
› Visual Structure › Reflection`, or `Objects and Transportation › Transportation › Boat ›
Sailboat` (a specific keyword comes with its general one, here Boat, so filtering by Boat
finds it). They are left out of exports. Genres, ratings and your other keywords are untouched.

Then vet them in `Genreator ▸ Suggested Keywords ▸ 1 Keywords to Verify`: remove the keywords
that are wrong, add the ones that are missing (anywhere in the vocabulary's tree), select the
grid and choose ***Mark Keywords Verified***. The photographs leave the grid, and what they
then carry is your decision: Suggest Keywords never changes a verified photograph. Mark the
grid before running Suggest Keywords on it again: on a photograph still awaiting
verification, a rerun removes the plugin's earlier suggestions the model no longer makes
(keywords you added stay), which can undo a removal you have not marked yet.

After a new model, ***Re-suggest Keywords*** on verified photographs adds its new suggestions,
removes nothing, and sends them back to the grid. `"keywordRule": "recall_first"` in the
config file suggests more keywords, more of them wrong. Before keywording a large batch, pause
cloud sync if Lightroom syncs this catalog (as for genre keywords, above). Keywords outside the
vocabulary's paths are never touched.

### 8. Check quality now and then

*File ▸ Plug-in Extras ▸ **Genre Quality Summary*** counts your review decisions per model
version: how often you kept the suggested primary and genre list, and the most common
changes.

## Advanced

Tools for reviewing a large catalog in samples and for applying decisions you keep outside
Lightroom. The everyday workflow above does not need them.

### Picking photographs worth reviewing (temporary)

*Library ▸ Plug-in Extras ▸ **Pick Photos to Review…*** asks for N. From the unclassified
photographs of the selection it draws a random sample about five times N — at most 500, or N
itself if larger — scores it with the model, and gives suggestions to N of them (criteria
`pick-v3`):

- **an equal share for each suggested primary genre**, No genre included, rarest first: the
  rare genres are the ones the model gets wrong most often, so they get as many reviews as the
  common ones; a genre with too few photographs leaves its share to the others;
- **within each, where the model is least sure first**: its no-genre score is between 0.2
  and 0.8, its top two candidates for the primary are within 0.15 of each other, or some genre
  is within 30% of its cut-off.

The rest of the sample stays unclassified. The picks join the other suggestions in
`Genreator ▸ Awaiting Review`; if earlier picks are still waiting there, the confirmation says
how many. Why each was picked, and how common its suggested primary was in the sample, are in
the CSV report (`pick_reason`, e.g. `pick-v3:close,cut-off:6/500`).

### Applying genres you have already decided

If you have a file of your own genre decisions for specific photographs (photo UUID, file
name, primary and genres, as JSON), *File ▸ Plug-in Extras ▸ **Apply Approved Genres…***
applies them as decided photographs, replacing whatever genres they had. Photographs are
matched by Lightroom's UUID and must have the file name the file gives; anything else is
skipped and reported. Applying the same file again changes nothing; a newer file updates
what changed. Classifying again never overrides these decisions.

### Applying keyword judgements

If you have a file of your own keyword judgements (photo UUID, file name, keywords, as JSON),
*File ▸ Plug-in Extras ▸ **Apply Keyword Judgements…*** gives each matched photograph exactly
those keywords of the vocabulary and marks it judged; applying the same file again changes
nothing, and a newer file keeps any change you made since. Pause cloud sync first if Lightroom
syncs this catalog.

## Commands

| Menu | Command | What it does |
|---|---|---|
| Library ▸ Plug-in Extras | Classify / Reclassify Selected Photos | Suggest genres. Reclassify refreshes the suggestion but never overrides your decision |
| | Pick Photos to Review… *(temporary)* | From the unclassified photographs of the selection, score a random sample about five times N (at most 500, or N if larger) and give suggestions only to N of them: an equal share per suggested primary genre, the model's edges first (see below) |
| | Remove Genre · Add Genre… | Edit the genres under review |
| | Set Primary Genre… · Accept Suggestion | Decide |
| | Correct Genres… | Set one primary and genre list for the whole selection |
| | Suggest Ratings | Suggest a rating bucket (0–3) in the *Suggested rating* field; genres and star ratings untouched |
| | Suggest Keywords | Add the model's suggested keywords at their vocabulary paths; the photographs await verification |
| | Mark Keywords Verified | Record the vocabulary keywords a photograph now has as your decision |
| | Re-suggest Keywords | Add a new model's suggestions to verified photographs, removing nothing |
| File ▸ Plug-in Extras | Set Up Review Collections | Create or repair the `Genreator` collection set (genre review, suggested rating and keyword grids) and the Personal keyword |
| | Apply Approved Genres… | Apply a file of your own genre decisions |
| | Apply Keyword Judgements… | Apply a file of your own keyword judgements |
| | Genre Quality Summary | Your genre decisions per model version |
| | Export Report (CSV) | Every plugin field of the selection: genre suggestions and decisions with the model's ranking, the suggested rating, the keyword review |
| | Check Model | Check the bundled model is complete and runs |
| | Re-derive Personal Suggestions | Apply a changed `personalFloor` setting to personal photographs awaiting review, without the model |
| | Update Genre Keywords | Rewrite genre keywords and fields from the photograph's `Genre` keywords (repairs hand edits) |
| | Remove Genre Keywords | Remove the genre keywords and fields |
| | Clear Plugin Data | Clear every plugin field of the selection — genre review, suggested rating, keyword review — back to unclassified; keywords untouched |
| Help ▸ Plug-in Extras | Show Genreator Diagnostics | What loaded, the model, the settings, the selection |

The Metadata panel shows the review fields (read-only, except Secondary Genres, which stays
editable so long text wraps). Provenance — the original suggestion, its ranking, the model
version — is in the CSV report.

## About the model

The suggestions come from a small genre model running on top of an image encoder, both
bundled with the plugin.

**How it works.**

1. **Image encoder:** SigLIP2 base patch16/256 (Google, Apache-2.0), a general-purpose
   pretrained vision model, used as published (converted to Core ML). It turns a 1024 px
   rendition of the photograph, read at 256 × 256, into 768 numbers describing its content.
2. **Genre model:** a small neural network (one hidden layer of 256 units) trained on the
   author's judgements. Its inputs are those 768 numbers and one flag, *personal*. For each
   genre it gives how likely that genre is the primary, and how likely it applies at all; and
   separately, how likely the photograph has no genre.
3. **Cut-offs:** each genre, and "no genre", has a tuned cut-off. They were tuned so that
   missing the primary costs most, missing a secondary genre less, and an extra genre least —
   an extra is removed in one click in the genre grids, a missing one goes unnoticed.
   Suggesting genres for a photograph with no genre counts too, and on personal photographs a
   miss counts less than on others.

The plugin suggests every genre that reaches its cut-off, most likely primary first, plus
your pre-tags (step 3). On a personal photograph a genre must also reach the model's
recommended floor (step 2). When "no genre" reaches its cut-off, or no genre does, the suggestion
is **No genre** — or your pre-tags, if you tagged any.

**Training and accuracy.** What the model learned from, how well it does on the author's
catalog (genres, the suggested rating and the suggested keywords), and how it was measured:
[`docs/model.md`](docs/model.md).

**Assumptions and caveats.**

- **Subjective by design.** The genres, their boundaries and every training label are one
  photographer's, for a catalog of mostly family photographs in the early years, landscape
  and nature in the middle years and street photography most recently. A catalog that looks
  different, or a different view of the genres, will see worse results than the figures in [`docs/model.md`](docs/model.md).
- **The figures are small-sample.** 200 photographs; per-genre counts are smaller still, so a
  difference of a few photographs is noise. Portrait, after the re-judging, has 20 held-out
  examples and only 33 in training: it is weakly learned (4 of 20 found) until more deliberate
  portraits are judged.
- **Personal must be tagged.** The model relies on the Personal flag; an untagged personal
  photograph is judged as a stranger's. The model was trained with the flag set from person
  keywords (named faces). When the Personal keyword's tree holds exactly the people you know,
  the two agree; on a personal photograph with nobody in it, or a person keyword under the
  Personal keyword who does not make a photograph personal, expect less certain answers.
- **Extra genres are rare in this version** (0.18 per photograph, 0.30 on photographs that
  are not personal), and so are secondary genres: the model mostly answers one genre or none.
  Remove extras in the genre grids; add a missing secondary there too.
- **Documentary is rare** in the training catalog (9 training examples) and weakly learned:
  the one held-out photograph that has it was not found. It is also often a matter of context the image does not show —
  what the event was, what the series is about — so adding Documentary by hand is normal, not
  a sign the model failed. Treat its suggestions, and its absence, with care.
- **No genre is now the usual answer on personal photographs.** The model finds 68 of the 77
  held-out No-genre photographs, but about three in ten of its No-genre answers are
  photographs the author gave a genre, nearly all personal ones: a family photograph with a
  real genre (a street scene, an event, a deliberate portrait) often comes back as No genre.
  Check the No genre grid of `Step 2 · Primary` with that in mind, and expect to set the
  primary yourself on personal photographs.
- **It sees only the image and the Personal flag** — not dates, places, captions, keywords or
  the photographs taken just before and after.
- **The definitions do not steer it.** The model learned from examples, not from the text in
  [`docs/taxonomy.md`](docs/taxonomy.md); that text explains the genres to you. Disagreeing with
  a definition means correcting suggestions in review, not editing a file.
- **No confidence is shown.** The model's probabilities are not calibrated for your catalog;
  the plugin keeps only the ranking and which genres reach their cut-off.
- **The genre list is fixed by the model.** The eight genres cannot be renamed or extended
  without a new model.

## Privacy

**Nothing leaves your computer.** The model runs locally on Core ML; the plugin makes no
network connection. (Downloading the release is the only download.)

For each batch, the plugin renders JPEGs of the photographs — 1024 px, with GPS, face regions
and all embedded metadata except copyright removed — into a temporary folder, writes a request
file listing them with a true/false Personal flag, runs the model, and deletes the renditions
right after. Suggest Keywords sends every photograph as not personal. No keyword text, name, caption or
location is written anywhere outside the catalog. Logs record counts, timings, genres and error codes only. Details:
[`docs/privacy-security.md`](docs/privacy-security.md).

## Troubleshooting

- **Menu items missing or greyed out** — Library items need a selection. After installing or
  updating, restart Lightroom fully.
- **"The model is not installed"** — the plugin folder is incomplete: download and unzip the
  release again; *Check Model* says what is missing.
- **"The model does not run"**, or **"“localgenres” Not Opened"** from macOS — the
  quarantine flag: click *Done* in macOS's message, run the command *Check Model* shows
  (Install, step 4), then *Check Model* again.
- **New fields or collections do not appear** — restart Lightroom; then run *Set Up Review
  Collections* again.
- **Photographs in `Errors`** — the Metadata panel's Error field says why; classifying them
  again retries.
- Logs: `~/.config/genreator/logs/genreator.log` (never contains image data or keywords).

## Further reading

| Document | For |
|---|---|
| [`docs/taxonomy.md`](docs/taxonomy.md) | The genres and their definitions |
| [`docs/model.md`](docs/model.md) | What the model learned from, and how well it does |
| [`docs/workflow.md`](docs/workflow.md) | Review loop and commands in detail |
| [`docs/privacy-security.md`](docs/privacy-security.md) | What is stored where, logs, failure handling |
| [`docs/development.md`](docs/development.md) | **Developers:** installing from the source, building, testing, releasing, conventions |

## Licence

[MIT](LICENSE) for the plugin, the genre model and its runtime. The runtime
(`model/localgenres`, the one program the plugin runs) is a prebuilt program; its source is
not published. The image encoder the model uses (SigLIP2 by Google) is Apache-2.0; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
