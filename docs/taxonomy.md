# Genre Taxonomy

The genres come from the bundled model: its own file, `Genreator.lrplugin/model/taxonomy.json`,
names them and fixes their order (ADR-012). The definitions below are the ones the model's
training judgements were made by. **They explain the genres; they do not steer the model**,
which learned from examples and never reads them. They are one photographer's deliberately
opinionated view (README, *About the model*).

## Two decisions per photograph

| | Question | How many | Stored as (ADR-019) |
|---|---|---|---|
| **Genres** | Which genres meaningfully apply? | any number, in priority order | `Genre > X` keywords (not exported) |
| **Primary Genre** | By what photographic standard should this image primarily be judged? | one genre, or **No genre** | Primary Genre field; the other genres in the Secondary Genres field |

The Primary Genre gives Lightroom's single star rating an evaluation context: a photograph
that would be a weak landscape may be a strong street photograph. The Genres keep a
photograph findable in every body of work it belongs to.

**Invariants** (enforced by `GrModel` for suggestions, `GrReview` for decisions and
`GrKeywords` on write):

1. A categorized photograph has a Primary Genre and its Genres, or No genre and no Genres.
   It never has genres without a primary (ADR-022). Before it is classified it may carry
   genre keywords the user applied; that is transient.
2. **The Primary Genre is among the Genres**, first in priority order.
3. Changing the Primary Genre does not remove other Genres.
4. Unrelated keywords and metadata are never touched (R5.6).
5. No genre is never a keyword.

Priority order is the model's: its ranking of how likely each genre is the primary
(ADR-023). The suggestion is every genre that reaches the model's cut-off for "applies", plus
the genres the user tagged before classifying, in that order. On a personal photograph a
genre must also reach the model's recommended floor (ADR-028).

## Personal is not a genre

Whether a photograph is personal — of people the photographer knows, or of personal
significance — is an attribute the user tags (the Personal keyword, default `#PERSONAL`, or
any keyword under it; ADR-024). It is the
model's one input besides the image. Known subjects or personal significance may inform the
genre but do not determine it.

## The genres

Street · Portrait · Event · Documentary · Landscape · Nature · Architecture · Object

Central principle: classify by what makes the photograph photographically meaningful, rather
than merely listing everything visible within the frame.

### Shared rules

- Primary genre: The strongest photographic interpretation of the image, not necessarily its most prominent literal subject.
- Secondary genres: Additional genres with independent, meaningful photographic justification. Avoid redundant classifications based merely on background elements.
- Multiple genres: Permitted without an arbitrary numerical limit, provided each is genuinely supported.
- No genre: A valid outcome when no genre applies convincingly. This is especially acceptable for ordinary Personal photographs, reproductions, and informational records.
- Personal: A separate attribute, not a genre. Known subjects or personal significance may inform interpretation but should not automatically determine genre.
- Photographic merit vs. genre: A photograph need not be especially strong artistically to qualify for a genre. Genre classification is about the nature of the photograph, not its star rating.

### No genre

A photograph may have no genre: no genre applies convincingly. It is most common on personal
photographs but allowed on any. It is a value of the Primary Genre field, `No genre`, and is
filterable like a genre.

### Street

Photography capturing spontaneous, unscripted moments, interactions, behaviors, or visual relationships involving people, animals, or objects in everyday environments. Emphasis is on observation, timing, gestures, juxtaposition, humor, or the relationship between subjects and their surroundings. Street photography is not limited to actual streets or urban locations.

- Subjects may be known to the photographer, and photographs may be taken in private or recreational settings if they have meaningful Street qualities. Mere candidness or the presence of people in public is insufficient; the image should contain a recognizable observational or visual hook.
- A deliberately constructed joke or visual relationship, such as a face-in-hole photo stand, does not establish Street merely because the result looks humorous.

### Portrait

A photograph whose principal photographic interest lies in revealing or emphasizing the individuality, character, expression, emotional state, personality, or meaningful interpersonal relationship of one or more people. The person must be more than simply the main visible subject: the photograph should offer a meaningful portrayal of the individual, through facial expression, body language, gesture, pose, interaction, or the relationship between the person and their environment.

- Classification test: could this photograph reasonably be considered for a Portrait-specific collection, and would portrait-specific criteria (expression, character, emotional connection, or individual portrayal) be meaningful in evaluating it? If not, do not assign Portrait.
- No genre is valid, including for non-personal photographs. Do not force Portrait simply because no other genre applies.
- Portrait is restricted to humans. Animals belong under Nature or another appropriate genre.

**Fuller definition.**

A photograph whose principal photographic interest lies in revealing or emphasizing the individuality, character, expression, emotional state, personality, or meaningful interpersonal relationship of one or more people.

**Include when:**

- A distinctive expression, gaze, or emotional state that communicates something about the individual.
- Body language or pose that reveals character, personality, or mood.
- A meaningful relationship between people that provides emotional or psychological interest.
- A strong environmental portrait in which the surroundings contribute to understanding or portraying the individual.
- An intimate or expressive close-up where individual character is the photographic focus.

**Not enough on its own:**

- A prominent or clearly visible face.
- Direct eye contact or looking toward the camera.
- A deliberate pose, including a tourist or family photograph.
- A smile, attractive appearance, or distinctive clothing.
- A person occupying most of the frame.
- A child engaged in ordinary play or recreation.
- A recognizable or personally known individual.

**Primary or secondary:** When action, event, environment, or spontaneous public-life interaction is the principal photographic interest, prefer the corresponding genre. Portrait may be secondary only if individual portrayal is independently significant.

- Ordinary family snapshots, posed souvenir photographs, and records of everyday activities do not qualify unless they contain meaningful portrait-specific interest.
- Quality independence: a photograph need not be technically excellent or already worthy of a high rating to qualify. However, it must offer a credible portrait-oriented photographic interpretation, rather than merely depict a person.

### Event

Photography documenting a recognizable organized occasion, such as a celebration, ceremony, festival, performance, competition, parade, demonstration, or other distinct gathering. The event itself, its participants, activities, or atmosphere should be important to the image.

- Routine activities, classes, recreational outings, and informal gatherings do not automatically qualify. Event may overlap with Street, Portrait, or Documentary, but should be assigned only when the occasion is independently meaningful.

### Documentary

Photography recording real people, events, activities, places, or conditions to communicate meaningful factual, social, cultural, historical, or informational content. Its defining quality is the significance of what is documented, beyond the mere fact that the photograph records reality.

- Documentary does not require a formal project or exceptional photographic quality. However, ordinary snapshots, casual observations, and personal records do not automatically qualify. The photograph should communicate something substantive about its subject or contribute meaningfully to a broader documentary narrative.

**Fuller definition.**

Photography whose meaningful purpose or content is to record and communicate real-world social, cultural, historical, occupational, or other factual circumstances. Assign when the image offers substantive informational or contextual value beyond simply depicting a person, place, activity, or event. May overlap with Street, Event, or Portrait, but must have independent documentary relevance. Do not use as a generic category for candid photographs, routine snapshots, or personal records.

**Include when:**

- Social or historical significance: Documents social conditions, traditions, political activity, historical events, or community life.
- Informational value: Communicates meaningful facts about a subject, activity, situation, or environment beyond its visual appearance.
- Cultural context: Shows recognizable practices, occupations, customs, or aspects of a community.
- Documentary storytelling: Contributes to understanding a real-world subject or narrative, including as part of a coherent photographic series.
- A photograph need not be aesthetically strong, professionally produced, or part of a formal documentary project to qualify.

**Not enough on its own:**

- The photograph records something that actually happened.
- It depicts ordinary people engaged in everyday activities.
- It was taken candidly rather than posed.
- It documents a family memory or vacation.
- It shows a recognizable location, building, or object.
- It depicts an organized event without conveying meaningful information beyond the occasion itself.

**Primary or secondary:** Documentary primary when communicating the subject's social, cultural, historical, or informational significance is the photograph's dominant function; secondary when that significance is substantial but another genre provides the primary photographic identity.

- Documentary should not become a fallback for ordinary photographs that lack stronger genre characteristics.
- Documentary intent or membership in a coherent documentary series can strengthen a borderline classification; this context should be explicitly available rather than invented by the classifier.
- For personal photographs, require genuine documentary significance beyond family-memory value.
- Threshold: moderate to selective; informational significance should be reasonably identifiable from the image or reliable contextual metadata.

### Landscape

Photography emphasizing the overall character, spatial relationships, atmosphere, or visual composition of an environment. Landscapes may be natural, rural, coastal, mountainous, or urban, and can include buildings, roads, people, animals, and other human-made elements.

- The environment as a whole should be the photographic subject, rather than an isolated natural feature or individual object. People and structures may contribute scale or visual interest without changing the primary classification. Nature should not be added automatically when natural elements are integral to a unified landscape.

### Nature

Photography emphasizing living organisms, natural phenomena, or specific elements of the natural world, including animals, plants, flowers, water, ice, weather, and natural textures or patterns. Subjects may be photographed in natural, cultivated, or human-influenced environments.

- Nature typically emphasizes particular natural subjects rather than the overall environment. It includes close-ups, wildlife behavior, botanical studies, and abstract representations of natural phenomena. Artificial representations of nature, such as animal sculptures or artificial flowers, do not qualify merely because of what they depict.

### Architecture

Photography emphasizing buildings, monuments, structures, interiors, or elements of the built environment. Architectural form, design, geometry, materials, spatial relationships, historical character, or structural details should be central to the photograph.

- Architecture includes unconventional structures and architectural fragments, not only complete buildings. However, buildings appearing merely as background or context do not justify the genre. Close-ups of manufactured objects or machinery generally belong to Object unless architectural significance is independently present.

### Object

Photography emphasizing physical objects, artifacts, manufactured items, tools, vehicles, sculptures, decorations, or other tangible things. Attention may focus on an object's appearance, design, function, condition, texture, details, or visual arrangement.

- Objects may be photographed individually or within their environment. Object differs from Architecture when the emphasis is on a discrete item rather than a building or structure, and from Nature when the subject is manufactured rather than naturally occurring. An object appearing incidentally within another genre does not automatically justify Object as a secondary classification.

## Changing the genres

The genre list is the model's and cannot be edited in the plugin: a renamed or added genre
would be one the model has never seen. A different definition, a new genre or a genre removed
needs new judgements and a new model; the plugin then takes the new model's taxonomy as it
is. Every suggestion records the model version (`modelVersion`), so results from different
models are never mixed.

A useful test for a proposed genre: *would photographs in this category need meaningfully
different criteria for 2, 3, 4 or 5 stars?* — and *would I want to view and evaluate them as a
body of work?* A distinction of subject, place or technique alone belongs in ordinary
keywords.
