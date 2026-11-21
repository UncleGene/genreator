--[[
GenreatorMetadata — plugin custom metadata field definitions (LrMetadataProvider).

Registered from Info.lua. Field ids must match GrMetadata.FIELDS exactly.

Two SDK constraints shape this file (ADR-001):
  * Plugin metadata is stored ONLY in the catalog. It cannot be linked to XMP or written
    into image files. That is why the genres themselves are keywords.
  * dataType is 'string', 'enum', or 'url' — there is NO number type.

searchable = true  -> offered as a smart-collection criterion: Review state, the decided
                      Primary Genre / Secondary Genres (ADR-019), Suggested rating, Keyword
                      review, and the fields the plugin's own review collections search
                      (GrCollections).
browsable  = true  -> appears in the Library grid filter: Review state, Primary Genre (with
                      its "No genre" value, ADR-022), Suggested rating, Keyword review.
                      Genres in any role are in the Keyword column.
title              -> shown in the Metadata panel, in this order: what a person filters on,
                      then what review needs. A field without one is hidden; the plugin still
                      reads and writes it (report, Diagnostics, Correct).
readOnly = true    -> on every shown field but Secondary Genres: only the plugin's commands
                      change them (ADR-019, ADR-020). Lightroom shows a read-only value on one
                      line and cuts it off, so Secondary Genres stays editable; Update Genre
                      Keywords rewrites a hand-edited value from the keywords.

Genre fields are plain text, not enums: an enum would need a schema change with every new
model taxonomy.
]]

return {

  metadataFieldsForPhotos = {

    -- --------------------------------------------------- shown in the Metadata panel

    {
      id = 'reviewState',
      title = 'Review state',
      dataType = 'enum',
      values = {
        { value = 'unclassified', title = 'Unclassified' },
        { value = 'suggested',    title = 'Suggested — awaiting review' },
        { value = 'accepted',     title = 'Accepted' },
        { value = 'corrected',    title = 'Corrected' },
        { value = 'error',        title = 'Error' },
      },
      searchable = true,
      browsable = true,
      readOnly = true,
      version = 3,   -- 3: no "rejected" (ADR-022)
    },

    -- The decided genres as the keywords hold them (ADR-019), written only with the keywords
    -- (GrKeywords): a genre, or "No genre" (ADR-022). A keyword rule cannot tell a primary
    -- from a secondary genre; these can. Secondary Genres is a list, so it is off the
    -- Library filter; smart collections use it with "contains".
    {
      id = 'primaryGenre',
      title = 'Primary Genre',
      dataType = 'string',
      searchable = true,
      browsable = true,
      readOnly = true,
      version = 2,
    },

    {
      id = 'secondaryGenres',
      title = 'Secondary Genres',
      dataType = 'string',
      searchable = true,
      browsable = false,
      version = 3,
    },

    -- The Primary Genre under review (R6.9): starts as aiGenre; Remove Genre on it promotes
    -- the next genre in priority order (or No genre when none is left). The primary grids
    -- search it. After a decision it keeps the last suggestion, hence "under review".
    {
      id = 'reviewGenre',
      title = 'Under review: primary genre',
      dataType = 'string',
      searchable = true,
      browsable = false,
      readOnly = true,
      version = 4,
    },

    -- The genre list under review (R6.9), in priority order: starts as a copy of aiGenres
    -- and is edited by Add / Remove Genre; Accept applies it. The genre grids search it.
    {
      id = 'reviewGenres',
      title = 'Under review: genres',
      dataType = 'string',
      searchable = true,
      browsable = false,
      readOnly = true,
      version = 4,
    },

    {
      id = 'errorText',
      title = 'Error',
      dataType = 'string',
      searchable = false,
      browsable = false,
      readOnly = true,
      version = 3,
    },

    -- Whether the photograph was personal when the model answered (ADR-024, ADR-028): `yes`
    -- or `no`, as sent to it. The personal floor and Personal Candidates go by it. A string,
    -- not an enum: Clear Plugin Data blanks it, and Lightroom refuses '' for an enum.
    {
      id = 'personal',
      title = 'Classified as personal',
      dataType = 'string',
      searchable = true,
      browsable = false,
      readOnly = true,
      version = 1,
    },

    -- The suggested rating's bucket under the chosen ratio (ADR-029), written by Suggest Ratings:
    -- `0` (likely 0 stars) to `3` (a candidate for 3 stars and above). The rating collections
    -- and the Library filter search it. Never the Lightroom star rating. A string: Clear Plugin
    -- Data blanks it.
    {
      id = 'ratingBucket',
      title = 'Suggested rating',
      dataType = 'string',
      searchable = true,
      browsable = true,
      readOnly = true,
      version = 1,
    },

    -- The keywords' review (ADR-030, R10): `suggested` (in Keywords to verify), `verified`,
    -- `golden` (the author's judgements applied) or `error`. Written by the keyword commands
    -- alone; the genres' review state is separate. A string: Clear Plugin Data blanks it.
    {
      id = 'keywordState',
      title = 'Keyword review',
      dataType = 'string',
      searchable = true,
      browsable = true,
      readOnly = true,
      version = 1,
    },

    -- ------------------------------------------- hidden: provenance and decision record
    -- No title, so not in the panel. The CSV report and Diagnostics read them.

    {
      id = 'aiGenre',            -- the primary as first suggested: a genre or No genre
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 5,
    },

    {
      id = 'aiGenres',           -- the suggested genres in priority order; includes aiGenre
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 4,
    },

    -- Every genre in the model's priority order, `*` where it reaches the model's cut-off:
    -- "Por* Str* Eve Doc …" (ADR-023). Add Genre places a genre by it.
    {
      id = 'aiRanking',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- The genres the user had tagged when the photograph was classified (ADR-023).
    {
      id = 'userGenres',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- Temporary, while the model is tuned: genre keywords the user added after the first
    -- suggestion, outside review — corrections, as opposed to pre-tags (ADR-023).
    {
      id = 'laterUserGenres',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- The decision as made: the truth the Quality Summary counts against (R7.4).
    {
      id = 'humanGenre',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 5,
    },

    {
      id = 'humanGenres',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 4,
    },

    -- Where the decision came from: `review`, or `approved` for an approved genres file
    -- (ADR-025), with the file's version after a colon.
    {
      id = 'decisionSource',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- The model version the decision answered (Accept, Set Primary, Correct); empty for an
    -- approved genres file. Keeps per-version quality honest after a reclassification.
    {
      id = 'decisionModelVersion',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- Whether the suggestion the decision answered was for a personal photograph (`yes` /
    -- `no`, from `personal`); empty for an approved genres file. Decisions on personal
    -- photographs are feedback on the model, not training material (ADR-028).
    {
      id = 'decisionPersonal',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    {
      id = 'model',              -- model id that answered
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 4,
    },

    {
      id = 'modelVersion',       -- the bundled model's version; segregates incomparable results
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    {
      id = 'classifiedAt',       -- UTC
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 3,
    },

    {
      id = 'runId',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 3,
    },

    -- Temporary (Pick Photos to Review…): how the photograph was picked (GrPick), e.g.
    -- `pick-v3:close,cut-off:6/500` (signals, then its primary's count in the sample).
    {
      id = 'pickReason',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- The suggested rating's provenance (ADR-029): the ratio its bucket is under, the score,
    -- the bucket under every ratio the model ships ("1.5=3 2.0=2", so a changed ratio setting is
    -- re-derived without the model), and the model version that rated.
    {
      id = 'ratingRatio',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    {
      id = 'ratingScore',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    {
      id = 'ratingBuckets',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    {
      id = 'ratingModelVersion',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },

    -- The keyword suggestion and decision (ADR-030), as GrKeywording formats them:
    -- `v1|<model version>|<taxonomy version>|<rule>|<UTC>|<ids>|<agreed ids>|<implied ids>` and
    -- `v1|<verified or golden:fingerprint>|<UTC>|<ids>`, ids comma-separated; and the last
    -- keyword error.
    { id = 'keywordSuggestion', dataType = 'string', searchable = false, browsable = false, version = 1 },
    { id = 'keywordDecided',    dataType = 'string', searchable = false, browsable = false, version = 1 },
    { id = 'keywordError',      dataType = 'string', searchable = false, browsable = false, version = 1 },

    -- Temporary, to tune the review collections' order (ADR-027): every review command on
    -- this photograph since its suggestion, oldest first, `; `-separated, each
    -- `<UTC seconds> <command> n=<selection size> @<grid>`, e.g.
    -- `1793000000 rm:Object n=14 @Step 1 · Genres/1 Object`. A new suggestion starts it afresh.
    {
      id = 'reviewTrail',
      dataType = 'string',
      searchable = false,
      browsable = false,
      version = 1,
    },
  },

  -- Lightroom caches field definitions per catalog; it re-reads them only when this
  -- increases, so any change to the field list or a field's type needs a bump.
  -- 1–13: earlier versions (see git history)
  -- 14: the bundled model (ADR-021): aiRanking, userGenres, decisionSource, modelVersion
  --     added; review state without "rejected"
  -- 15: pickReason (temporary, Pick Photos to Review…)
  -- 16: laterUserGenres, decisionModelVersion
  -- 17: reviewTrail (temporary, ADR-027)
  -- 18: personal, decisionPersonal (ADR-028)
  -- 19: ratingBucket, ratingRatio, ratingScore, ratingBuckets, ratingModelVersion (ADR-029)
  -- 20: keywordState, keywordSuggestion, keywordDecided, keywordError (ADR-030)
  schemaVersion = 20,
}
