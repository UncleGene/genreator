--[[
GrReport — the plugin's verdicts and the user's decisions, read back out (M4).

1. CSV export of the selected photographs, for analysis outside Lightroom. The file stays on
   this computer (~/.config/genreator/reports/). It holds the file name, the suggestions and
   the decisions — never GPS or paths.
2. Quality Summary (R7.8): the user's own review decisions, counted per model version: how
   often the model's primary and genre list were kept. The user's decision is the only truth
   here (R7.4); decisions from an approved genres file had no suggestion to judge, so they
   are counted apart.

Pure: COLUMNS, csvField, toCsv, rowFor, outcome, summarize, summaryText.
Lightroom-bound: readPhoto, exportSelection, readDecisionFields, catalogDecisions.
]]

local Metadata = require 'GrMetadata'
local Taxonomy = require 'GrTaxonomy'

local Report = {}

-- The keyword fields (ADR-030), with keyword ids shown as names when the bundled keyword
-- taxonomy knows them.
local function keywordNames(ids)
  local KT = require 'GrKeywordTaxonomy'
  if not KT.available() then KT.load(require('GrModel').dir()) end
  local out = {}
  for i, id in ipairs(ids or {}) do out[i] = KT.nameOf(id) or id end
  return table.concat(out, '; ')
end
local function suggestion(p) return require('GrKeywording').parseSuggestion(p.fields.keywordSuggestion) or {} end
local function decided(p) return require('GrKeywording').parseDecided(p.fields.keywordDecided) or {} end

Report.COLUMNS = {
  { 'file',                function(p) return p.fileName end },
  { 'review_state',        function(p) return p.fields.reviewState end },
  { 'primary_genre',       function(p) return p.fields.aiGenre end },
  { 'genres',              function(p) return p.fields.aiGenres end },
  { 'ranking',             function(p) return p.fields.aiRanking end },
  { 'personal',            function(p) return p.fields.personal end },
  { 'rating_bucket',       function(p) return p.fields.ratingBucket end },
  { 'rating_ratio',        function(p) return p.fields.ratingRatio end },
  { 'rating_score',        function(p) return p.fields.ratingScore end },
  { 'rating_buckets',      function(p) return p.fields.ratingBuckets end },
  { 'rating_model_version', function(p) return p.fields.ratingModelVersion end },
  { 'keyword_state',       function(p) return p.fields.keywordState end },
  { 'keywords_suggested',  function(p) return keywordNames(suggestion(p).ids) end },
  { 'keywords_agreed',     function(p) return keywordNames(suggestion(p).agreed) end },
  { 'keywords_implied',    function(p) return keywordNames(suggestion(p).implied) end },
  { 'keyword_rule',        function(p) return suggestion(p).rule end },
  { 'keyword_model_version', function(p) return suggestion(p).modelVersion end },
  { 'keyword_taxonomy',    function(p) return suggestion(p).taxonomyVersion end },
  { 'keywords_decided',    function(p) return keywordNames(decided(p).ids) end },
  { 'keyword_decision_source', function(p) return decided(p).source end },
  { 'keyword_error',       function(p) return p.fields.keywordError end },
  { 'user_genres',         function(p) return p.fields.userGenres end },
  { 'later_user_genres',   function(p) return p.fields.laterUserGenres end },
  { 'review_primary',      function(p) return p.fields.reviewGenre end },
  { 'review_genres',       function(p) return p.fields.reviewGenres end },
  { 'human_genre',         function(p) return p.fields.humanGenre end },
  { 'human_genres',        function(p) return p.fields.humanGenres end },
  { 'decision_source',     function(p) return p.fields.decisionSource end },
  { 'decision_model_version', function(p) return p.fields.decisionModelVersion end },
  { 'decision_personal',   function(p) return p.fields.decisionPersonal end },
  { 'model',               function(p) return p.fields.model end },
  { 'model_version',       function(p) return p.fields.modelVersion end },
  { 'pick_reason',         function(p) return p.fields.pickReason end },
  { 'review_trail',        function(p) return p.fields.reviewTrail end },
  { 'run_id',              function(p) return p.fields.runId end },
  { 'error',               function(p) return p.fields.errorText end },
}

--- RFC 4180 quoting: wrap in quotes when needed, double any embedded quote.
function Report.csvField(v)
  v = (v == nil) and '' or tostring(v)
  if v:find('[",\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
  return v
end

--- Pure: one row from { fileName, fields = { <Metadata.FIELDS value> = ... } }.
function Report.rowFor(p)
  local out = {}
  for _, col in ipairs(Report.COLUMNS) do out[#out + 1] = Report.csvField(col[2](p)) end
  return table.concat(out, ',')
end

function Report.toCsv(photos)
  local lines = {}
  local header = {}
  for _, col in ipairs(Report.COLUMNS) do header[#header + 1] = col[1] end
  lines[1] = table.concat(header, ',')
  for _, p in ipairs(photos) do lines[#lines + 1] = Report.rowFor(p) end
  return table.concat(lines, '\n') .. '\n'
end

-- ------------------------------------------------------------ Quality Summary (R7.8)

local STATE = Metadata.STATE

--- Pure: what one photograph says about the model, from its plugin fields.
-- Compared against the photo's *current* suggestion: Reclassify refreshes the model's fields
-- and keeps the decision, so the comparison is with what the plugin now suggests.
-- @return 'pending' | 'error' | 'approved' | 'agreed' | 'listCorrected' | 'primaryDefect',
--         or nil to skip
function Report.outcome(fields)
  local state = fields.reviewState
  if state == STATE.suggested then return 'pending' end
  if state == STATE.error then return 'error' end
  if state ~= STATE.accepted and state ~= STATE.corrected then return nil end
  if (fields.decisionSource or ''):match('^' .. Metadata.SOURCE.approved) then return 'approved' end
  local human, ai = fields.humanGenre, fields.aiGenre
  if human == nil or human == '' or human ~= ai then return 'primaryDefect' end
  if state == STATE.corrected then return 'listCorrected' end
  return 'agreed'
end

local function genreSet(text, extra)
  local set = {}
  for g in (text or ''):gmatch('[^,]+') do
    g = g:gsub('^%s+', ''):gsub('%s+$', '')
    if g ~= '' then set[g] = true end
  end
  if Taxonomy.isGenre(extra) then set[extra] = true end
  return set
end

--- Pure: how the user's genre list differs from the model's, for a decided photograph.
-- @return { added = {genre...}, removed = {genre...} } or nil
function Report.listChange(fields)
  local human = fields.humanGenre
  if human == nil or human == '' then return nil end
  local ai = genreSet(fields.aiGenres, fields.aiGenre)
  local mine = genreSet(fields.humanGenres, human)
  local out = { added = {}, removed = {} }
  for _, g in ipairs(Taxonomy.genres) do
    if mine[g] and not ai[g] then out.added[#out.added + 1] = g end
    if ai[g] and not mine[g] then out.removed[#out.removed + 1] = g end
  end
  return out
end

-- A decision belongs to the model version it answered; a reclassification since does not
-- move it.
local function versionOf(fields)
  local v = fields.decisionModelVersion
  local reviewed = (fields.reviewState == STATE.accepted or fields.reviewState == STATE.corrected)
                   and not (fields.decisionSource or ''):match('^' .. Metadata.SOURCE.approved)
  -- A review decision from before decision versions were recorded: which model it answered
  -- is not known, so it is not credited to the version a reclassification wrote since.
  if (v == nil or v == '') and reviewed then return '(unknown)' end
  if v == nil or v == '' then v = fields.modelVersion end
  return (v == nil or v == '') and '(unknown)' or v
end

local function newCounts()
  return { pending = 0, error = 0, approved = 0, agreed = 0, listCorrected = 0,
           primaryDefect = 0, decided = 0, listChanged = 0 }
end

--- Pure: tally decisions per model version.
-- @param rows list of field tables (Metadata.FIELDS names)
-- @param currentVersion the bundled model's version
-- @return { current, versions = { [v] = counts }, order = { v... }, confusion = { {ai, human, n}... },
--           added, removed }
function Report.summarize(rows, currentVersion)
  local versions, order = {}, {}
  local confusion, added, removed = {}, {}, {}
  for _, fields in ipairs(rows) do
    local kind = Report.outcome(fields)
    if kind then
      local v = versionOf(fields)
      local c = versions[v]
      if not c then c = newCounts(); versions[v] = c; order[#order + 1] = v end
      c[kind] = c[kind] + 1
      if kind == 'agreed' or kind == 'listCorrected' or kind == 'primaryDefect' then
        c.decided = c.decided + 1
        local change = Report.listChange(fields)
        if change and (#change.added > 0 or #change.removed > 0) then
          c.listChanged = c.listChanged + 1
          if v == currentVersion then
            for _, g in ipairs(change.added) do added[g] = (added[g] or 0) + 1 end
            for _, g in ipairs(change.removed) do removed[g] = (removed[g] or 0) + 1 end
          end
        end
      end
      if kind == 'primaryDefect' and v == currentVersion then
        local key = tostring(fields.aiGenre) .. '\t' .. tostring(fields.humanGenre)
        confusion[key] = (confusion[key] or 0) + 1
      end
    end
  end
  -- Current version first, then the rest newest first (versions start with a date).
  table.sort(order, function(a, b)
    if a == currentVersion or b == currentVersion then return a == currentVersion end
    return a > b
  end)
  local pairsList = {}
  for key, n in pairs(confusion) do
    local ai, human = key:match('^(.-)\t(.*)$')
    pairsList[#pairsList + 1] = { ai = ai, human = human, n = n }
  end
  table.sort(pairsList, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.ai .. a.human < b.ai .. b.human
  end)
  local function tally(t)
    local out = {}
    for g, n in pairs(t) do out[#out + 1] = { genre = g, n = n } end
    table.sort(out, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.genre < b.genre end)
    return out
  end
  return { current = currentVersion, versions = versions, order = order, confusion = pairsList,
           added = tally(added), removed = tally(removed) }
end

local function pct(n, d) return d > 0 and 100 * n / d or 0 end

local function counts(c)
  return string.format('%d reviewed — primary kept %d (%.0f%%), genre list edited %d (%.0f%%)',
    c.decided, c.agreed + c.listCorrected, pct(c.agreed + c.listCorrected, c.decided),
    c.listChanged, pct(c.listChanged, c.decided))
end

local function list(t)
  local parts = {}
  for _, x in ipairs(t) do parts[#parts + 1] = string.format('%s %d', x.genre, x.n) end
  return table.concat(parts, ', ')
end

--- Pure: the dialog text — short enough for a laptop screen: the current model, its top
-- confusions, and one line per older version. `fullPath` names the file with summaryText.
function Report.summaryShort(sum, fullPath)
  local lines = {}
  local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
  if #sum.order == 0 then
    add('No classified photographs in this catalog yet.')
    return table.concat(lines, '\n')
  end
  local c = sum.versions[sum.current] or newCounts()
  add('Model %s: %s.', sum.current, counts(c))
  if c.pending > 0 or c.error > 0 or c.approved > 0 then
    add('Awaiting review %d, errors %d, from an approved genres file %d.', c.pending, c.error, c.approved)
  end
  if #sum.confusion > 0 then
    local parts = {}
    for i = 1, math.min(5, #sum.confusion) do
      local p = sum.confusion[i]
      parts[#parts + 1] = string.format('%s -> %s %d', p.ai, p.human, p.n)
    end
    add('Primary changed (suggested -> yours): %s%s', table.concat(parts, ', '), #sum.confusion > 5 and ', …' or '.')
  end
  if #sum.removed > 0 then add('Genres removed: %s.', list(sum.removed)) end
  if #sum.added > 0 then add('Genres added: %s.', list(sum.added)) end
  local older = {}
  for _, v in ipairs(sum.order) do if v ~= sum.current then older[#older + 1] = v end end
  if #older > 0 then
    add('')
    add('Older versions:')
    for i = 1, math.min(4, #older) do add('  %s: %s', older[i], counts(sum.versions[older[i]])) end
    if #older > 4 then add('  … and %d more', #older - 4) end
  end
  if fullPath then add(''); add('Full report: %s', fullPath) end
  return table.concat(lines, '\n')
end

--- Pure: the full text, written to a file (every version, every confusion).
function Report.summaryText(sum)
  local lines = {}
  local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
  if #sum.order == 0 then
    add('No classified photographs in this catalog yet.')
    return table.concat(lines, '\n')
  end
  for _, v in ipairs(sum.order) do
    local c = sum.versions[v]
    add('%s%s', v, v == sum.current and '  (current)' or '')
    add('  %s', counts(c))
    add('  primary changed %d; awaiting review %d, errors %d, from an approved genres file %d',
        c.primaryDefect, c.pending, c.error, c.approved)
    add('')
  end
  if #sum.confusion > 0 then
    add('Primary changed on the current model (suggested -> your decision):')
    for _, p in ipairs(sum.confusion) do add('  %s -> %s: %d', p.ai, p.human, p.n) end
  end
  if #sum.removed > 0 or #sum.added > 0 then
    add('')
    add('Genre-list edits on the current model:')
    if #sum.removed > 0 then add('  removed: %s', list(sum.removed)) end
    if #sum.added > 0 then add('  added: %s', list(sum.added)) end
  end
  return table.concat(lines, '\n')
end

-- ------------------------------------------------------------ Lightroom-bound

--- Read a photo's plugin fields and file name. Catalog reads only; no write access.
function Report.readPhoto(photo)
  local fields = {}
  for name, id in pairs(Metadata.FIELDS) do fields[name] = Metadata.get(photo, id) end
  local ok, fileName = (import 'LrTasks').pcall(function() return photo:getFormattedMetadata('fileName') end)
  return { fileName = ok and fileName or '', fields = fields }
end

--- The fields Report.outcome and Report.summarize need. Catalog reads only.
local DECISION_FIELDS = { 'reviewState', 'aiGenre', 'aiGenres', 'humanGenre', 'humanGenres',
                          'decisionSource', 'modelVersion', 'decisionModelVersion' }
function Report.readDecisionFields(photo)
  local fields = {}
  for _, name in ipairs(DECISION_FIELDS) do fields[name] = Metadata.get(photo, Metadata.FIELDS[name]) end
  return fields
end

--- Every photograph in the catalog the plugin has touched, as decision-field rows.
-- findPhotosWithProperty takes the plugin id string (unlike get/setPropertyForPlugin).
-- @param progress optional LrProgressScope
-- @return rows; or nil, errorMessage when cancelled
function Report.catalogDecisions(catalog, progress)
  local photos = catalog:findPhotosWithProperty(_PLUGIN.id, Metadata.FIELDS.reviewState) or {}
  local rows = {}
  for i, photo in ipairs(photos) do
    if progress then
      if progress:isCanceled() then return nil, 'cancelled' end
      progress:setPortionComplete(i - 1, #photos)
    end
    rows[#rows + 1] = Report.readDecisionFields(photo)
  end
  return rows
end

--- Write the full Quality Summary next to the CSV reports. @return path, or nil
function Report.writeSummary(text)
  local LrFileUtils = import 'LrFileUtils'
  local LrPathUtils = import 'LrPathUtils'
  local Config = require 'GrConfig'
  local dir = LrPathUtils.child(LrPathUtils.parent(Config.path()), 'reports')
  if not LrFileUtils.exists(dir) then LrFileUtils.createAllDirectories(dir) end
  local path = LrPathUtils.child(dir, os.date('genre-quality-summary-%Y%m%d-%H%M%S.txt'))
  local fh = io.open(path, 'wb')
  if not fh then return nil end
  fh:write(text, '\n')
  fh:close()
  return path
end

--- Write the CSV for `photos` into <config dir>/reports/.
-- @return path, or nil plus an error message
function Report.exportSelection(photos)
  local LrFileUtils = import 'LrFileUtils'
  local LrPathUtils = import 'LrPathUtils'
  local Config = require 'GrConfig'

  local dir = LrPathUtils.child(LrPathUtils.parent(Config.path()), 'reports')
  if not LrFileUtils.exists(dir) then LrFileUtils.createAllDirectories(dir) end
  local path = LrPathUtils.child(dir, os.date('genreator-report-%Y%m%d-%H%M%S.csv'))

  local rows = {}
  for _, photo in ipairs(photos) do rows[#rows + 1] = Report.readPhoto(photo) end
  local fh, err = io.open(path, 'wb')
  if not fh then return nil, 'cannot write ' .. path .. ': ' .. tostring(err) end
  fh:write(Report.toCsv(rows))
  fh:close()
  return path
end

return Report
