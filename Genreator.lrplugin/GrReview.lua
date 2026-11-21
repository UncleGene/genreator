--[[
GrReview — accept / correct, Add / Remove Genre, and the two reverts (ADR-002, ADR-012).

A suggestion never writes a keyword (ADR-002); these commands are where keywords appear.
The human decision is recorded in plugin metadata (`humanGenre`, `humanGenres`, review
state) — the calibration truth (R7.4) — and mirrored as keywords by GrKeywords.

Every decision is a primary genre with its genres, or NO_GENRE with none (ADR-022). Genre
lists keep the model's priority order (`aiRanking`), so removing the primary promotes the
next genre in that order, and an added genre takes its place in it (ADR-023).

Pure: genreList, underReview, primaryUnderReview, ordered, acceptDecision, setPrimaryDecision,
correctDecision, genreEditDecision, upToDate, rederiveDecision. Lightroom-bound: run.
]]

local Keywords = require 'GrKeywords'
local Metadata = require 'GrMetadata'
local Model    = require 'GrModel'
local Taxonomy = require 'GrTaxonomy'

local Review = {}

local S = Metadata.STATE
local NO_GENRE = Taxonomy.NO_GENRE

--- Pure: "Street, Portrait" -> { 'Street', 'Portrait' }.
function Review.genreList(text)
  local out = {}
  for g in (text or ''):gmatch('[^,]+') do
    g = g:gsub('^%s+', ''):gsub('%s+$', '')
    if g ~= '' then out[#out + 1] = g end
  end
  return out
end

--- Pure: genres in the photograph's priority order — the model's ranking, then taxonomy
-- order for anything the ranking does not list. Unknown names are dropped.
function Review.ordered(genres, fields)
  local pos = {}
  for i, r in ipairs(Model.parseRanking(fields and fields.aiRanking)) do pos[r.genre] = i end
  local n = #Taxonomy.genres
  local out, seen = {}, {}
  for _, g in ipairs(genres or {}) do
    if Taxonomy.isGenre(g) and not seen[g] then seen[g] = true; out[#out + 1] = g end
  end
  table.sort(out, function(a, b)
    return (pos[a] or n + Taxonomy.rank(a)) < (pos[b] or n + Taxonomy.rank(b))
  end)
  return out
end

local function withPrimary(primary, genres)
  local out, seen = {}, {}
  if Taxonomy.isGenre(primary) then out[1] = primary; seen[primary] = true end
  for _, g in ipairs(genres or {}) do
    if Taxonomy.isGenre(g) and not seen[g] then out[#out + 1] = g; seen[g] = true end
  end
  return out
end

local function sameSet(a, b)
  if #a ~= #b then return false end
  local set = {}
  for _, x in ipairs(a) do set[x] = true end
  for _, x in ipairs(b) do if not set[x] then return false end end
  return true
end

--- Pure: the genre list under review — the model's list as edited by Add / Remove Genre
-- (R6.9). Lightroom stores an unset field as '', so an empty list cannot mark "not yet
-- prepared": reviewGenre does. Once it is set, reviewGenres is authoritative even when
-- empty; before that, aiGenres applies.
function Review.underReview(fields)
  local prepared = fields.reviewGenre ~= nil and fields.reviewGenre ~= ''
  return Review.genreList(prepared and fields.reviewGenres or fields.aiGenres)
end

--- Pure: the Primary Genre under review (R6.9), falling back to the model's.
function Review.primaryUnderReview(fields)
  local p = fields.reviewGenre
  if p == nil or p == '' then p = fields.aiGenre end
  return p
end

--- Pure: is this decision the model's own suggestion?
local function agrees(fields, primary, genres)
  return fields.aiGenre == primary
     and sameSet(genres, withPrimary(fields.aiGenre, Review.genreList(fields.aiGenres)))
end

--- Pure: the user's own answer. Recorded as `accepted` when it equals the suggestion,
-- `corrected` otherwise, so the summary counts agreement honestly. NO_GENRE takes no genres.
-- @return decision { state, primary, genres }; or nil, reason
function Review.correctDecision(fields, primary, genres)
  if not Taxonomy.isPrimary(primary) then
    return nil, string.format('%q is not a genre in the current taxonomy', tostring(primary))
  end
  local chosen = primary == NO_GENRE and {} or withPrimary(primary, Review.ordered(genres, fields))
  return { state = agrees(fields, primary, chosen) and S.accepted or S.corrected,
           primary = primary, genres = chosen }
end

--- Pure: adopt the suggestion as reviewed — the model's, with any Add / Remove Genre edits.
-- @return decision { state, primary, genres }; or nil, reason
function Review.acceptDecision(fields)
  local ai = fields.aiGenre
  if ai == nil or ai == '' then return nil, 'no suggestion to accept' end
  local primary = Review.primaryUnderReview(fields)
  if not Taxonomy.isPrimary(primary) then
    return nil, string.format('suggested genre %q is not in the current taxonomy', primary)
  end
  local d = Review.correctDecision(fields, primary, Review.underReview(fields))
  d.keepLater = true
  return d
end

--- Pure: Add Genre (op '+') or Remove Genre (op '-') on the genres under review (R6.9).
-- Never fails on the list itself: adding a listed genre or removing an absent one changes
-- nothing. Removing the primary promotes the next genre in priority order; removing the last
-- leaves No genre. Adding to No genre makes the genre the primary. The photograph stays
-- awaiting review; Accept applies the result.
-- @return decision { keepKeywords = true, reviewGenres = text, reviewGenre = primary };
--         or nil, reason (a skip: not a genre, or not awaiting review)
function Review.genreEditDecision(fields, genre, op)
  if not Taxonomy.isGenre(genre) then
    return nil, string.format('%q is not a genre in the current taxonomy', tostring(genre))
  end
  if fields.reviewState ~= S.suggested then
    return nil, 'not awaiting review (decided photographs: use Correct Genres…)'
  end
  local primary = Review.primaryUnderReview(fields)
  if not Taxonomy.isGenre(primary) then primary = nil end
  local list = withPrimary(primary, Review.underReview(fields))

  local out = {}
  if op == '-' then
    for _, g in ipairs(list) do if g ~= genre then out[#out + 1] = g end end
    if primary == genre then primary = Review.ordered(out, fields)[1] end
  elseif op == '+' then
    out = list
    local listed = false
    for _, g in ipairs(list) do listed = listed or g == genre end
    if not listed then
      out[#out + 1] = genre
      primary = primary or genre
    end
  else
    error('genreEditDecision: op must be + or -', 2)
  end
  out = withPrimary(primary, Review.ordered(out, fields))
  return { keepKeywords = true, reviewGenres = table.concat(out, ', '),
           reviewGenre = primary or NO_GENRE }
end

--- Pure: Accept and Set Primary Genre… keep the genres the user added by hand after the
-- suggestion, outside review: they join the decision (and become its primary when it was No
-- genre), recorded as later user genres. Correct Genres… sets an exact list and does not.
-- @param present the genre keywords on the photograph now
function Review.withLaterTags(decision, fields, present)
  if not decision.keepLater then return decision end
  local later = Metadata.userTags(present, fields).laterUserGenres
  if #later == 0 then return decision end
  local primary = decision.primary
  if primary == NO_GENRE then primary = Review.ordered(later, fields)[1] end
  local genres = {}
  for _, g in ipairs(decision.genres or {}) do genres[#genres + 1] = g end
  for _, g in ipairs(later) do genres[#genres + 1] = g end
  local d = Review.correctDecision(fields, primary, genres)
  d.laterUserGenres = later
  return d
end

--- Pure: does a photograph already match the keyword plan and genre fields it would get?
function Review.upToDate(fields, plan, want)
  local function same(a, b) return (a or '') == (b or '') end
  return #plan.add == 0 and #plan.remove == 0
     and same(fields.primaryGenre, want.primary)
     and same(fields.secondaryGenres, table.concat(want.secondaries, ', '))
end

--- Pure: Set Primary Genre… on one photograph of a multi-photo selection: `genre` becomes
-- the primary (added if missing); every other genre of THIS photograph stays, the old
-- primary included. NO_GENRE clears the genres. Decides at once, from the photograph's own
-- list: the user's earlier decision, else the genres under review (with any step-1 edits).
-- @return decision { state, primary, genres }; or nil, reason
function Review.setPrimaryDecision(fields, genre)
  if not Taxonomy.isPrimary(genre) then
    return nil, string.format('%q is not a genre in the current taxonomy', tostring(genre))
  end
  local state = fields.reviewState
  local base
  if (state == S.accepted or state == S.corrected) and Taxonomy.isPrimary(fields.humanGenre) then
    base = Review.genreList(fields.humanGenres)
  elseif state == S.suggested or state == S.accepted or state == S.corrected then
    base = Review.underReview(fields)
  else
    return nil, 'not classified yet'
  end
  local d = Review.correctDecision(fields, genre, withPrimary(genre, base))
  -- An explicit No genre is the user's word over their own later tags.
  d.keepLater = genre ~= NO_GENRE
  return d
end

--- Pure: Re-derive Personal Suggestions (ADR-028): a personal photograph's suggestion
-- derived again from its stored ranking with the current personalFloor setting, so a change
-- of the setting applies without the model. Only photographs awaiting review: a decision
-- stands. A ranking stored before the model brought a floor cannot be re-derived to it.
-- @param present the genre keywords on the photograph now
-- @param mode the personalFloor setting; modelFloor the bundled model's floor (or nil)
-- @return decision { keepKeywords = true, rederived = { primary, genres, laterUserGenres } };
--         or nil, reason
function Review.rederiveDecision(fields, present, mode, modelFloor)
  if fields.reviewState ~= S.suggested then return nil, 'not awaiting review (a decision stands)' end
  if fields.personal ~= Metadata.YES then return nil, 'not personal: the setting does not change it' end
  local ranked, info = Model.parseRanking(fields.aiRanking)
  if #ranked == 0 then return nil, 'no stored ranking: reclassify' end
  if mode ~= Model.FLOOR_MODES.off and not info.floor and modelFloor then
    return nil, 'classified before the model had a personal floor: reclassify'
  end
  local tags = Metadata.userTags(present, fields)
  local s = Model.suggest(ranked, tags.preTags, info.noGenre, Model.usesFloor(true, mode, info.floor))
  if s.primary == fields.aiGenre and table.concat(s.genres, ', ') == (fields.aiGenres or '') then
    return nil, 'unchanged'
  end
  s.laterUserGenres = tags.laterUserGenres
  return { keepKeywords = true, rederived = s }
end

-- ------------------------------------------------------------ Lightroom-bound

local function readFields(photo)
  local f = {}
  for name, id in pairs(Metadata.FIELDS) do f[name] = Metadata.get(photo, id) end
  return f
end

--- Apply a decision to every photograph in `photos`.
-- @param decide function(fields, photo) -> decision | nil, reason. A decision with no `state`
--        changes keywords only (Remove Genre Keywords); `clearData` resets plugin fields;
--        `fromKeywords` rewrites the photograph's own genre keywords in the current form.
--        Keywords and genre fields are written together, from GrKeywords.wanted.
-- @param progress optional LrProgressScope. Cancel is honoured while reading, before any
--        write, so a cancelled command changes nothing; the writes are one short gate.
-- @param trail optional entry (GrMetadata.trailEntry) appended to the review trail of every
--        photograph whose decision or genres under review this writes (ADR-027)
-- @return { done = n, skipped = n, reasons = { [reason] = n }, cancelled = bool }
function Review.run(catalog, photos, decide, title, progress, trail)
  local LrTasks = import 'LrTasks'

  -- Reads first, outside any write gate.
  local work, counts = {}, { done = 0, skipped = 0, reasons = {} }
  for i, photo in ipairs(photos) do
    if progress then
      if progress:isCanceled() then counts.cancelled = true; return counts end
      progress:setPortionComplete(i - 1, #photos)
    end
    local fields = readFields(photo)
    local decision, reason = decide(fields, photo)
    local plan
    if decision and not decision.keepKeywords then
      local current = Keywords.currentOf(photo)
      if decision.fromKeywords then
        -- Update Genre Keywords: the photograph's own keywords are the decision (ADR-019).
        decision = Keywords.held(current, fields.primaryGenre, Review.genreList(fields.secondaryGenres))
        plan = Keywords.plan(current, decision)
        if Review.upToDate(fields, plan, Keywords.wanted(decision)) then
          decision, reason = nil, 'already up to date'
        end
      else
        if decision.keepLater then
          decision = Review.withLaterTags(decision, fields, Keywords.held(current).genres)
        end
        plan = Keywords.plan(current, decision)
      end
    end
    -- A review decision records the model version it answered and whether the suggestion was
    -- for a personal photograph (ADR-028); an approved file's records neither.
    if decision and decision.state and decision.source == nil then
      decision.modelVersion = fields.modelVersion
      decision.personal = fields.personal
    end
    if decision then
      work[#work + 1] = { photo = photo, decision = decision, plan = plan or { add = {}, remove = {} },
                          trail = trail and (decision.state or decision.reviewGenres)
                                  and Metadata.trailWith(fields.reviewTrail, trail) or nil }
    else
      counts.skipped = counts.skipped + 1
      counts.reasons[reason] = (counts.reasons[reason] or 0) + 1
    end
  end
  if #work == 0 then return counts end

  -- Gate 1: find or create every keyword the photographs need, once each. Lightroom will
  -- not let a keyword be assigned inside the call that created it.
  local adds, refs = {}, {}
  for _, w in ipairs(work) do for _, a in ipairs(w.plan.add) do adds[#adds + 1] = a end end
  if #adds > 0 then
    local ok, err = LrTasks.pcall(function()
      catalog:withWriteAccessDo(title .. ' (keywords)', function() refs = Keywords.ensureTree(catalog, adds) end,
                                { timeout = 30 })
    end)
    if not ok then error('could not create keywords: ' .. tostring(err), 0) end
  end

  -- Gate 2: assign keywords and record the decision, all photographs at once.
  local step = 'opening write access'
  local ok, err = LrTasks.pcall(function()
    catalog:withWriteAccessDo(title, function()
      for i, w in ipairs(work) do
        local where = string.format('photo %d of %d', i, #work)
        Keywords.assign(w.photo, w.plan, refs, function(s) step = where .. ', ' .. s end)
        step = where .. ', recording the decision'
        -- The genre fields change exactly when the keywords do, from the same result.
        if not w.decision.keepKeywords then Metadata.writeGenreFields(w.photo, Keywords.wanted(w.decision)) end
        if w.decision.clearData then
          Metadata.clear(w.photo)
        elseif w.decision.state then
          Metadata.writeDecision(w.photo, w.decision)
        elseif w.decision.rederived then
          Metadata.writeRederived(w.photo, w.decision.rederived)
        elseif w.decision.reviewGenres then
          Metadata.writeReviewGenres(w.photo, w.decision.reviewGenres, w.decision.reviewGenre)
        end
        if w.trail then Metadata.set(w.photo, Metadata.FIELDS.reviewTrail, w.trail) end
        counts.done = counts.done + 1
      end
    end, { timeout = 60 })
  end)
  if not ok then error(string.format('could not write the decision (%s): %s', step, tostring(err)), 0) end
  return counts
end

--- Pure: one line per outcome, for the dialog after a command.
function Review.summary(counts, verb)
  if counts.cancelled then return 'Cancelled — nothing was changed.' end
  local lines = { string.format('%s: %d', verb, counts.done) }
  for reason, n in pairs(counts.reasons) do
    lines[#lines + 1] = string.format('Skipped %d: %s', n, reason)
  end
  return table.concat(lines, '\n')
end

return Review
