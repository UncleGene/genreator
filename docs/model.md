# The model

What the bundled model learned from and how well it does. How it works, and the caveats to
keep in mind while reviewing, are in the README (*About the model*).

## What it learned from

The author judged 841 photographs of their own catalog by hand:
random photographs from each period of the catalog, photographs an earlier model was least
sure about, and photographs chosen for rare genres. In November 2026 the author re-judged 597
of them under two tightened rules: a photograph that is not personal may have no genre, and
Portrait means a deliberate portrait, not any recognisable person — so most personal
photographs now carry No genre and Portrait is rare. 623 were used to train it; 200, drawn at
random in the catalog's proportions, were held back to measure it. This version trained on
the author's judgements only; the genres kept, added or removed in Genreator's review are
feedback on the model, not training examples. No AI-generated labels were used. Near-duplicate
photographs were kept on the same side, so it was never measured on a near-copy of a training
photograph.

## How well it does

On the author's catalog, against the author's judgements:

| Measure | All 200 | The 76 that are not personal |
|---|---|---|
| Primary genre right (No genre counts when both say No genre) | 73.5% (95% range 68.0% to 79.5%) | 82.9% |
| Genres the author chose that the model also suggests | 69.1% | 93.6% |
| Extra genres suggested per photograph | 0.18 | 0.30 |
| No genre: photographs the author judged No genre that the model also calls No genre | 68 of 77 (88%) | 2 of 3 |
| No genre: the model's No-genre answers the author agrees with | 68 of 96 (71%) | — |

These are best-case figures for anyone else's catalog: the 200 come from the same catalog and
judge as the training photographs, and they were also used to choose this model over a
candidate with a different image encoder, which flatters the one chosen.

The figures are not comparable with earlier versions', which were measured against the earlier
judgements. For comparison, when the author judged 40 of those photographs a second time,
blind, the primary matched their own earlier judgement 95% of the time.

These figures are for the model's cut-offs. **On personal photographs**, the default floor
trades genres found for genres that are right — measured on the 124 held-out personal
photographs (person keywords standing in for the Personal flag). Under the re-judged labels
the model already answers No genre on most of them, so the floor changes little:

| On personal photographs | Cut-offs only | Recommended floor (0.5) |
|---|---|---|
| Suggested genres that are right | 62% (21 of 34) | 67% (20 of 30) |
| Genres the author chose that the model also suggests | 36% | 34% |
| Genres suggested per photograph | 0.27 | 0.24 |
| The author's primary not among the suggested genres | 32 of 50 | 33 of 50 |
| No genre photographs given No genre | 68 of 74 | 69 of 74 |

So most personal photographs come back as No genre, and the ones that keep a genre are real
candidates; the author's primary on a personal photograph is missed more often than not, so
*Set Primary Genre…* is the normal route for them.

| Genre | Found where it applies | Right as primary | Extra suggestions |
|---|---|---|---|
| Street | 27 of 35 | 22 of 31 | 10 |
| Portrait | 4 of 20 | 4 of 20 | 1 |
| Event | 10 of 17 | 7 of 15 | 5 |
| Documentary | 0 of 1 | — | 0 |
| Landscape | 25 of 29 | 22 of 27 | 3 |
| Nature | 18 of 21 | 17 of 19 | 4 |
| Architecture | 4 of 5 | 4 of 5 | 2 |
| Object | 6 of 8 | 3 of 6 | 11 |

## Suggested rating

Since model `2026.11.05-6466afd6-2389c1` the model also suggests a
rating: a score of the same 768 numbers (plus the *personal* flag) trained on the author's own
star ratings, and a bucket from 0 (likely 0★) to 3 (a candidate for 3★ and above). Model
`2026.11.06-6466afd6-4bdd6c` trained it on 32,687 photographs taken from 2005 on (the years
before 2025 at half weight), under the author's current rating convention. The buckets have
geometric sizes, each star bucket 1/ratio the size of the one below; the default ratio 2
makes about 7% of a pile from 2025 on candidates (ratio 1.5: 12%, ratio 3: 3%). Measured out
of fold by capture day: 92% of the author's 3★ photographs land in the top 40% of scores (83%
on 2025–2026); at ratio 2, 590 of the 1,205 good (3★ and above) photographs reach the
candidate bucket and 57 are left in the 0★ bucket, and the bucket equals the star exactly on
55% of photographs from 2025–2026 (80% on older years). It tells 0★ from the rest and
3★-and-above from 1★-and-below well, and 1★ from 2★ poorly. It is a personal-taste model: generic "aesthetic" signals do not
know this taste. *Suggest Ratings* writes it to the plugin's *Suggested rating* field only;
your star rating stays yours (ADR-029).

## Suggested keywords

With the keyword model (`2026.11.06-017101a3-85849b`, vocabulary
v0.14) the same call also suggests keywords: 75 keywords in 6 categories (Visual Features,
People and Activities, Objects and Transportation, Animals, Plants and Natural Subjects, Places
and Built Environment), each a visual characteristic, a recognisable subject or an observable
activity, never photographic quality. A keyword head on the same 768 numbers averages two
members: one built from the keyword's words alone, and one trained on the author's own
judgements of 562 photographs; a keyword is suggested when the combined score reaches one
cut-off, at most three per photograph, and marked *agreed* (recorded, not shown) when both
members reach their own. High-key, Layers, Negative Space and Truck are never suggested (too
few examples); Play and Solitary Figure only when both members agree. Measured out of fold on
the author's judged photographs, the default rule finds 65% of the author's keywords at 76%
precision (0.33 wrong keywords per photograph); on the 110 drawn at random, 51% at 71%. The
recall-first option finds 73% at 65%. Abstract keywords (composition, social situations) are
learned less well than concrete subjects and light, and rare keywords' figures are unsure.
Like the genres, it is one author's vocabulary and judgement (ADR-030).
