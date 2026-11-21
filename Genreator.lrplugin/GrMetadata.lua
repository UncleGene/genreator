--[[
GrMetadata — plugin-metadata read/write, and the model's inputs from the catalog.

The model sees only the rendered image and one flag: whether the user tagged the photograph
Personal (ADR-024). The plugin also reads the genres the user tagged before classifying
(ADR-023). Both come from keywords the user applies; no keyword text goes anywhere.
]]

local Taxonomy = require 'GrTaxonomy'

local Metadata = {}

-- get/setPropertyForPlugin take the global _PLUGIN object, not the toolkit id string:
-- Lightroom rejects the string on write ("first parameter must be the _PLUGIN object").

--- Plugin metadata field ids. Must match GenreatorMetadata.lua exactly.
Metadata.FIELDS = {
  reviewState    = 'reviewState',
  -- The decided genres as GrKeywords leaves them (ADR-019): what smart collections and the
  -- Library filter use, since a keyword rule cannot tell a primary from a secondary.
  -- Written with the keywords, never anywhere else.
  primaryGenre    = 'primaryGenre',
  secondaryGenres = 'secondaryGenres',
  reviewGenre    = 'reviewGenre',
  reviewGenres   = 'reviewGenres',
  errorText      = 'errorText',
  aiGenre        = 'aiGenre',
  aiGenres       = 'aiGenres',
  aiRanking      = 'aiRanking',
  userGenres     = 'userGenres',
  -- Temporary, while the model is tuned: genre keywords the user added after the first
  -- suggestion, outside review (ADR-023).
  laterUserGenres = 'laterUserGenres',
  humanGenre     = 'humanGenre',
  humanGenres    = 'humanGenres',
  decisionSource = 'decisionSource',
  -- The model version the decision answered; empty for an approved genres file.
  decisionModelVersion = 'decisionModelVersion',
  -- Whether the photograph was personal when the model answered (`yes` / `no`, ADR-028), and
  -- whether the suggestion a decision answered was.
  personal       = 'personal',
  decisionPersonal = 'decisionPersonal',
  model          = 'model',
  modelVersion   = 'modelVersion',
  classifiedAt   = 'classifiedAt',
  runId          = 'runId',
  -- Temporary (Pick Photos to Review…): how the photograph was picked, e.g. pick-v3:close:6/500.
  pickReason     = 'pickReason',
  -- Temporary (ADR-027): the review commands on the photograph since its suggestion.
  reviewTrail    = 'reviewTrail',
  -- The suggested rating (ADR-029), written by Suggest Ratings alone: the bucket under the
  -- chosen ratio (`0`–`3`, what the rating collections search), that ratio, the model's score,
  -- the bucket under every shipped ratio (so a changed ratio setting is re-derived without the
  -- model), and the model version that rated.
  ratingBucket   = 'ratingBucket',
  ratingRatio    = 'ratingRatio',
  ratingScore    = 'ratingScore',
  ratingBuckets  = 'ratingBuckets',
  ratingModelVersion = 'ratingModelVersion',
  -- The keywords' review and provenance (ADR-030), written by the keyword commands alone
  -- (GrKeywording); the keywords themselves are Lightroom keywords at the taxonomy's paths.
  keywordState      = 'keywordState',
  keywordSuggestion = 'keywordSuggestion',
  keywordDecided    = 'keywordDecided',
  keywordError      = 'keywordError',
}

--- The keyword review states (ADR-030).
Metadata.KEYWORD_STATE = { suggested = 'suggested', verified = 'verified', golden = 'golden', error = 'error' }

-- They describe the keywords, so Clear Plugin Data leaves them, as it leaves the keywords.
local GENRE_FIELDS = { primaryGenre = true, secondaryGenres = true }

Metadata.STATE = {
  unclassified = 'unclassified',
  suggested    = 'suggested',
  accepted     = 'accepted',
  corrected    = 'corrected',
  error        = 'error',
}

--- Lightroom's cloud sync carries keywords (when the catalog's "Sync keywords" is on) but not
-- plugin fields, so only commands that write genre keywords in bulk matter to it. The SDK has
-- no way to pause sync, so those that confirm first say so.
Metadata.SYNC_NOTE = 'This writes genre keywords. If Lightroom syncs this catalog, pause sync ' ..
                     'first (cloud icon, top right) and resume it afterwards if you want.'

--- The stored form of the Personal flag (`personal`, `decisionPersonal`).
Metadata.YES, Metadata.NO = 'yes', 'no'
function Metadata.flag(b) return b and Metadata.YES or Metadata.NO end

--- Where a decision came from (decisionSource).
Metadata.SOURCE = { review = 'review', approved = 'approved' }

-- Catalog reads yield inside Lightroom, so they are guarded with LrTasks.pcall: a plain
-- pcall fails there with "Yielding is not allowed within a C or metamethod call" — and,
-- being a pcall, fails silently (found 2026-10-03).
local function guarded(fn)
  return (import 'LrTasks').pcall(fn)
end

-- ------------------------------------------------- the model's inputs

--- Pure: the model's inputs from a photograph's keywords (GrKeywords.currentOf form).
-- @param personalPath the Personal keyword as a path (config `personalPath`): it, or any
--        keyword nested under it, marks the photograph personal
-- @return { personal = bool, preTags = {genres, taxonomy order} }
function Metadata.inputsFrom(current, personalPath)
  local Keywords = require 'GrKeywords'
  local personal, tagged = false, {}
  for _, k in ipairs(current or {}) do
    if k.branch == Keywords.GENRE and Taxonomy.isGenre(k.name) then tagged[k.name] = true end
    if Keywords.under(k.path, personalPath) then personal = true end
  end
  local preTags = {}
  for _, g in ipairs(Taxonomy.genres) do if tagged[g] then preTags[#preTags + 1] = g end end
  return { personal = personal, preTags = preTags }
end

local function list(text)
  local out = {}
  for g in (text or ''):gmatch('[^,]+') do
    g = g:gsub('^%s+', ''):gsub('%s+$', '')
    if g ~= '' then out[#out + 1] = g end
  end
  return out
end

local function set_of(items)
  local s = {}
  for _, g in ipairs(items) do s[g] = true end
  return s
end

--- Pure: whose the genre keywords on a photograph are (ADR-023).
-- `present` are the genre keywords on it now. Those the plugin wrote for a decision (the
-- decided genres the user had not tagged before) are not the user's. The user's pre-tags are
-- fixed at the first suggestion; any user genre added since, outside review, is a later one.
-- @param fields the photograph's plugin fields (GrMetadata.FIELDS names)
-- @return { preTags = the user's genres on it now, userGenres = recorded at the first
--           suggestion, laterUserGenres = added since }
function Metadata.userTags(present, fields)
  fields = fields or {}
  local first = (fields.aiGenre or '') == ''
  local recorded = first and {} or list(fields.userGenres)
  local isRecorded = set_of(recorded)
  -- Genres the user added later and a decision kept are still the user's, not the plugin's.
  local isUsers = set_of(recorded)
  for _, g in ipairs(first and {} or list(fields.laterUserGenres)) do isUsers[g] = true end
  local decided = fields.reviewState == Metadata.STATE.accepted or fields.reviewState == Metadata.STATE.corrected
  local written = {}
  for _, g in ipairs(decided and list(fields.humanGenres) or {}) do
    if not isUsers[g] then written[g] = true end
  end
  local preTags, later = {}, {}
  for _, g in ipairs(present or {}) do
    if not written[g] then
      preTags[#preTags + 1] = g
      if not first and not isRecorded[g] then later[#later + 1] = g end
    end
  end
  return { preTags = preTags, userGenres = first and preTags or recorded, laterUserGenres = later }
end

function Metadata.inputsOf(photo, personalPath)
  return Metadata.inputsFrom(require('GrKeywords').currentOf(photo), personalPath)
end

-- ------------------------------------------------- plugin metadata accessors

local function get(photo, field)
  local ok, v = guarded(function()
    return photo:getPropertyForPlugin(_PLUGIN, field)
  end)
  if ok then return v end
  return nil
end

local function set(photo, field, value)
  -- Plugin metadata has no number type; everything is stored as a string (ADR-001).
  if value == nil then value = '' end
  photo:setPropertyForPlugin(_PLUGIN, field, tostring(value))
end

Metadata.get = get
Metadata.set = set

--- Current review state, defaulting to unclassified.
function Metadata.reviewState(photo)
  local s = get(photo, Metadata.FIELDS.reviewState)
  if s == nil or s == '' then return Metadata.STATE.unclassified end
  return s
end

function Metadata.isClassified(photo)
  return Metadata.reviewState(photo) ~= Metadata.STATE.unclassified
end

local DECIDED = { accepted = true, corrected = true }

--- Has the user decided this photograph (accept / correct, or an approved genres file)?
function Metadata.isDecided(photo)
  return DECIDED[Metadata.reviewState(photo)] == true
end

--- Write a suggestion. Caller must already hold catalog write access.
-- @param s { primary, genres, ranking, userGenres, laterUserGenres, personal = bool }
function Metadata.writeSuggestion(photo, s, ctx)
  local F = Metadata.FIELDS
  -- Reclassify refreshes the model's fields, but a human decision stands until the user
  -- accepts or corrects again (R2.7).
  if not Metadata.isDecided(photo) then
    set(photo, F.reviewState, Metadata.STATE.suggested)
    set(photo, F.reviewTrail, '')
  end
  local genres = table.concat(s.genres or {}, ', ')
  set(photo, F.aiGenre,      s.primary)
  set(photo, F.aiGenres,     genres)
  set(photo, F.aiRanking,    s.ranking or '')
  set(photo, F.personal,     Metadata.flag(s.personal))
  set(photo, F.userGenres,   table.concat(s.userGenres or {}, ', '))
  set(photo, F.laterUserGenres, table.concat(s.laterUserGenres or {}, ', '))
  -- A new suggestion starts a new review: earlier Add / Remove Genre edits are dropped.
  set(photo, F.reviewGenres, genres)
  set(photo, F.reviewGenre,  s.primary)
  set(photo, F.model,        (ctx and ctx.model) or '')
  set(photo, F.modelVersion, (ctx and ctx.modelVersion) or '')
  set(photo, F.classifiedAt, os.date('!%Y-%m-%dT%H:%M:%SZ'))
  set(photo, F.runId,        (ctx and ctx.runId) or '')
  set(photo, F.errorText,    '')
  -- Kept across a reclassification: it records why the photograph was chosen, not what the
  -- model said.
  if s.pickReason then set(photo, F.pickReason, s.pickReason) end
end

--- Write the suggested rating (Suggest Ratings, ADR-029). Caller holds write access. Touches
-- nothing but the rating fields: not the review state, not the genres, never the star rating.
-- @param r { score, bucket, ratio, buckets } (GrModel.ratingSuggestion)
-- @param modelVersion the bundled model's version
function Metadata.writeRating(photo, r, modelVersion)
  local F = Metadata.FIELDS
  set(photo, F.ratingBucket,  tostring(r.bucket))
  set(photo, F.ratingRatio,   r.ratio)
  set(photo, F.ratingScore,   string.format('%.3f', r.score))
  set(photo, F.ratingBuckets, r.buckets or '')
  set(photo, F.ratingModelVersion, modelVersion or '')
end

--- Write a bucket re-derived from the stored buckets under a changed ratio (ADR-029). Caller
-- holds write access.
function Metadata.writeRatingBucket(photo, bucket, ratio)
  set(photo, Metadata.FIELDS.ratingBucket, tostring(bucket))
  set(photo, Metadata.FIELDS.ratingRatio,  ratio)
end

--- Write a suggestion re-derived from the stored ranking (Re-derive Personal Suggestions, ADR-028):
-- the suggested genres and a fresh review of them. The model's own fields stay. Caller holds
-- write access; the photograph is awaiting review.
-- @param s { primary, genres, laterUserGenres }
function Metadata.writeRederived(photo, s)
  local F = Metadata.FIELDS
  local genres = table.concat(s.genres or {}, ', ')
  set(photo, F.aiGenre,      s.primary)
  set(photo, F.aiGenres,     genres)
  set(photo, F.laterUserGenres, table.concat(s.laterUserGenres or {}, ', '))
  set(photo, F.reviewGenres, genres)
  set(photo, F.reviewGenre,  s.primary)
  set(photo, F.reviewTrail,  '')
end

--- Write a failure. Caller must already hold catalog write access.
function Metadata.writeError(photo, errorCode, errorMessage, ctx)
  local F = Metadata.FIELDS
  -- A failed reclassification must not erase a decision the user already made.
  if not Metadata.isDecided(photo) then set(photo, F.reviewState, Metadata.STATE.error) end
  set(photo, F.errorText,    string.format('%s: %s', tostring(errorCode), tostring(errorMessage)))
  set(photo, F.runId,        (ctx and ctx.runId) or '')
  set(photo, F.classifiedAt, os.date('!%Y-%m-%dT%H:%M:%SZ'))
end

--- Record a human decision (GrReview). Caller must already hold catalog write access.
-- @param decision { state, primary = genre | NO_GENRE, genres, source }
function Metadata.writeDecision(photo, decision)
  local F = Metadata.FIELDS
  set(photo, F.reviewState,    decision.state)
  set(photo, F.humanGenre,     decision.primary or '')
  set(photo, F.humanGenres,    table.concat(decision.genres or {}, ', '))
  set(photo, F.decisionSource, decision.source or Metadata.SOURCE.review)
  set(photo, F.decisionModelVersion, decision.modelVersion or '')
  set(photo, F.decisionPersonal, decision.personal or '')
  if decision.laterUserGenres then set(photo, F.laterUserGenres, table.concat(decision.laterUserGenres, ', ')) end
end

--- Record the genre keywords a photograph now has (GrKeywords.wanted). Caller holds write
-- access.
function Metadata.writeGenreFields(photo, want)
  local F = Metadata.FIELDS
  set(photo, F.primaryGenre,    want.primary or '')
  set(photo, F.secondaryGenres, table.concat(want.secondaries or {}, ', '))
end

--- Record the genres under review (Add / Remove Genre). Caller holds write access.
function Metadata.writeReviewGenres(photo, text, primary)
  set(photo, Metadata.FIELDS.reviewGenres, text)
  set(photo, Metadata.FIELDS.reviewGenre, primary)
end

--- Pure: the review trail with one more entry (ADR-027): `<UTC seconds> <command>
-- n=<selection size> @<grid>`. Only the last TRAIL_MAX entries are kept.
Metadata.TRAIL_MAX = 30
function Metadata.trailWith(trail, entry)
  local items = {}
  for e in (trail or ''):gmatch('[^;]+') do
    e = e:gsub('^%s+', ''):gsub('%s+$', '')
    if e ~= '' then items[#items + 1] = e end
  end
  items[#items + 1] = entry
  while #items > Metadata.TRAIL_MAX do table.remove(items, 1) end
  return table.concat(items, '; ')
end

--- Pure: one trail entry. `grid` is the active source's name, nil when there is none.
function Metadata.trailEntry(time, command, count, grid)
  return string.format('%d %s n=%d @%s', time, command, count, (tostring(grid or '-'):gsub(';', ',')))
end

--- Reset every plugin field but the genre fields. Caller must already hold write access.
-- Review state is an enum without an empty value: Lightroom refuses '' for it when the write
-- gate closes (seen 2026-10-28, which undid the whole command), so it is set, never blanked.
function Metadata.clear(photo)
  for name, field in pairs(Metadata.FIELDS) do
    if not GENRE_FIELDS[name] and name ~= 'reviewState' then set(photo, field, '') end
  end
  set(photo, Metadata.FIELDS.reviewState, Metadata.STATE.unclassified)
end

return Metadata
