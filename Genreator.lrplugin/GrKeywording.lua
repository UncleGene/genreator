--[[
GrKeywording — keyword suggestions (ADR-030, R10): Suggest Keywords, Re-suggest Keywords,
Mark Keywords Verified and Apply Keyword Judgements….

The keyword categories sit at the root of the keyword list. Suggested keywords are written at
once as Lightroom keywords at their taxonomy paths (GrKeywordTaxonomy), and the photograph's
keyword review state says where it stands:

  (none) / error --Suggest Keywords--> suggested --Mark Keywords Verified--> verified
  suggested --Suggest Keywords--> suggested (re-synchronised)
  verified --Re-suggest Keywords--> suggested (new suggestions added, nothing removed)
  any --Apply Keyword Judgements…--> golden (exactly the judged keywords)

Suggest Keywords never changes a verified or golden photograph; Re-suggest never a golden one.
Re-synchronising a suggested photograph removes the keywords the plugin suggested before and
no longer suggests (when still present), adds the new ones, and keeps whatever the user added.

Only keywords at the taxonomy's paths are read or written: categories and subcategories are
parents only, any other keyword (the same name elsewhere included) is never touched. The
genres, their review, the rating and the star rating are untouched.

Lightroom constraints (as GrKeywords): a keyword created in a write gate cannot be assigned in
it, and a repeated createKeyword(…, returnExisting) in one command can return nil, so each
keyword is created or found once per command, in a gate of its own, before the gate that
assigns it.

Pure: suggestionText, parseSuggestion, decidedText, parseDecided, presentIds, syncPlan,
exactPlan, plan, summaryText, parseJudgements, judgementAction. Lightroom-bound: ensure, assign,
the commands.
]]

local Json     = require 'GrJson'
local KT       = require 'GrKeywordTaxonomy'
local Metadata = require 'GrMetadata'

local KW = {}

local F = Metadata.FIELDS
local S = Metadata.KEYWORD_STATE

KW.FORMAT = 'v1'
KW.VERIFIED = 'verified'
KW.GOLDEN = 'golden'
KW.MODE = { suggest = 'suggest', resuggest = 'resuggest' }

-- ------------------------------------------------------------ stored forms (pure)

local function join(ids) return table.concat(ids or {}, ',') end
local function split(text)
  local out = {}
  for id in (text or ''):gmatch('[^,]+') do out[#out + 1] = id end
  return out
end
local function fields(text)
  local out = {}
  for part in ((text or '') .. '|'):gmatch('([^|]*)|') do out[#out + 1] = part end
  return out
end

--- Pure: the stored suggestion (keywordSuggestion), and back (nil when empty or unknown).
-- @param s { modelVersion, taxonomyVersion, rule, at, ids, agreed, implied }
function KW.suggestionText(s)
  return table.concat({ KW.FORMAT, s.modelVersion or '', s.taxonomyVersion or '', s.rule or '', s.at or '',
                        join(s.ids), join(s.agreed), join(s.implied) }, '|')
end
function KW.parseSuggestion(text)
  local p = fields(text)
  if p[1] ~= KW.FORMAT then return nil end
  return { modelVersion = p[2], taxonomyVersion = p[3], rule = p[4], at = p[5],
           ids = split(p[6]), agreed = split(p[7]), implied = split(p[8]) }
end

--- Pure: the stored decision (keywordDecided), and back.
-- @param d { source = 'verified' | 'golden:<fingerprint>', at, ids }
function KW.decidedText(d)
  return table.concat({ KW.FORMAT, d.source or '', d.at or '', join(d.ids) }, '|')
end
function KW.parseDecided(text)
  local p = fields(text)
  if p[1] ~= KW.FORMAT then return nil end
  return { source = p[2], at = p[3], ids = split(p[4]) }
end

-- ------------------------------------------------------------ plans (pure)

--- Pure: the taxonomy keywords on a photograph, from its keywords (GrKeywords.currentOf form:
-- each with `path` and `ref`): ids in taxonomy order, and each id's keyword object.
function KW.presentIds(current)
  local ids, refOf = {}, {}
  for _, k in ipairs(current or {}) do
    local id = KT.idOfPath(k.path)
    if id and not refOf[id] then ids[#ids + 1] = id; refOf[id] = k.ref end
  end
  return KT.sorted(ids), refOf
end

--- Pure: the ids with the general keywords they imply (Sailboat → Boat, along the whole
-- chain), in taxonomy order. Lightroom's filters by a parent keyword do not find a photograph
-- tagged only with its child (checked 2026-11-06), so the general keyword is assigned beside
-- the specific one wherever the plugin assigns it (ADR-030).
function KW.withImplied(ids)
  local out, seen = {}, {}
  for _, id in ipairs(ids or {}) do
    local at = KT.byId(id)
    while at and not seen[at.id] do
      seen[at.id] = true
      out[#out + 1] = at.id
      at = at.fallback and KT.byId(at.fallback) or nil
    end
  end
  return KT.sorted(out)
end

local function setOf(list)
  local s = {}
  for _, x in ipairs(list or {}) do s[x] = true end
  return s
end

--- Pure: what Suggest Keywords or Re-suggest Keywords changes on one photograph (R10.1,
-- R10.4, R10.5), or nil and why it is left alone.
-- @param mode KW.MODE
-- @param state the keyword review state ('' / nil when none)
-- @param present ids of the taxonomy keywords on it now
-- @param previous ids the plugin suggested before (the stored suggestion)
-- @param suggested ids suggested now
-- Both are taken with the general keywords they imply (withImplied), which are assigned too.
-- @return { add = ids, remove = ids }; or nil, 'decided' | 'not verified'
function KW.syncPlan(mode, state, present, previous, suggested)
  previous, suggested = KW.withImplied(previous), KW.withImplied(suggested)
  if mode == KW.MODE.resuggest then
    if state ~= S.verified then return nil, 'not verified' end
  elseif state == S.verified or state == S.golden then
    return nil, 'decided'
  end
  local have, now = setOf(present), setOf(suggested)
  local plan = { add = {}, remove = {} }
  if mode == KW.MODE.suggest and state == S.suggested then
    for _, id in ipairs(KT.sorted(previous)) do
      if have[id] and not now[id] then plan.remove[#plan.remove + 1] = id end
    end
  end
  for _, id in ipairs(KT.sorted(suggested)) do
    if not have[id] then plan.add[#plan.add + 1] = id end
  end
  return plan
end

--- Pure: the changes that leave a photograph with exactly `listed` among the taxonomy
-- keywords (Apply Keyword Judgements…); other keywords are not in `present`, so untouched.
function KW.exactPlan(present, listed)
  local have, want = setOf(present), setOf(listed)
  local plan = { add = {}, remove = {} }
  for _, id in ipairs(KT.sorted(present)) do if not want[id] then plan.remove[#plan.remove + 1] = id end end
  for _, id in ipairs(KT.sorted(listed)) do if not have[id] then plan.add[#plan.add + 1] = id end end
  return plan
end

--- Pure: which photographs of the selection a suggestion run renders.
-- @param infos array of { photo, isVideo, state }
-- @param isMissing function(photo), asked only of photographs to render (the slow check)
-- @return photos to render, skipped { video, decided, notVerified, missing }
function KW.plan(infos, mode, isMissing)
  local run, skipped = {}, { video = 0, decided = 0, notVerified = 0, missing = 0 }
  for _, info in ipairs(infos) do
    local state = info.state or ''
    if info.isVideo then
      skipped.video = skipped.video + 1
    elseif mode == KW.MODE.resuggest and state ~= S.verified then
      skipped.notVerified = skipped.notVerified + 1
    elseif mode == KW.MODE.suggest and (state == S.verified or state == S.golden) then
      skipped.decided = skipped.decided + 1
    elseif isMissing(info.photo) then
      skipped.missing = skipped.missing + 1
    else
      run[#run + 1] = info.photo
    end
  end
  return run, skipped
end

--- Pure: the summary after a suggestion run.
-- @param counts { ok, added, removed, errors, changed }
function KW.summaryText(mode, counts, skipped, cancelled)
  local lines = { string.format('%s: %d photograph%s, %d keyword%s added, %d removed.',
    mode == KW.MODE.resuggest and 'Re-suggested' or 'Keyworded', counts.ok, counts.ok == 1 and '' or 's',
    counts.added, counts.added == 1 and '' or 's', counts.removed) }
  if counts.errors > 0 then
    lines[#lines + 1] = string.format('Not keyworded (see the Keyword Errors grid and the log): %d.', counts.errors)
  end
  local parts = {}
  if skipped.decided > 0 then parts[#parts + 1] = string.format('%d with verified or judged keywords', skipped.decided) end
  if skipped.notVerified > 0 then parts[#parts + 1] = string.format('%d not verified', skipped.notVerified) end
  if (counts.changed or 0) > 0 then parts[#parts + 1] = string.format('%d decided meanwhile', counts.changed) end
  if skipped.video > 0 then parts[#parts + 1] = string.format('%d video', skipped.video) end
  if skipped.missing > 0 then
    parts[#parts + 1] = string.format('%d with the original offline and no Smart Preview', skipped.missing)
  end
  if #parts > 0 then lines[#lines + 1] = 'Skipped: ' .. table.concat(parts, ', ') .. '.' end
  if cancelled then lines[#lines + 1] = 'The run was cancelled; finished photographs were kept. Run it again to continue.' end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Vet them in Genreator / Suggested Keywords / 1 Keywords to Verify: remove wrong ' ..
                      'keywords, add missing ones, then Mark Keywords Verified.'
  return table.concat(lines, '\n')
end

-- ------------------------------------------------------------ judgements (pure)

--- Pure: read a keyword judgements file (R10.6): { schema_version = 1, taxonomy_version,
-- items = { {photo_uuid, file_base, keywords = {names}} } }. Invalid items are listed, not applied.
-- A judged specific keyword brings its general one (the file lists only the specific one).
-- @return { source = 'golden:<fingerprint>', items = { {uuid, fileBase, ids} }, invalid = {reasons} };
--         or nil, message
function KW.parseJudgements(text)
  local ok, data = pcall(Json.decode, text or '')
  if not ok or type(data) ~= 'table' or type(data.items) ~= 'table' then
    return nil, 'the file is not a keyword judgements file (JSON with an "items" list)'
  end
  if data.schema_version ~= 1 then return nil, string.format('unsupported schema_version %s', tostring(data.schema_version)) end
  if data.taxonomy_version ~= KT.version then
    return nil, string.format('the file is for keyword taxonomy %s; the bundled model has %s',
                              tostring(data.taxonomy_version), tostring(KT.version))
  end
  local out = { source = KW.GOLDEN .. ':' .. require('GrApproved').fingerprint(text), items = {}, invalid = {} }
  for i, it in ipairs(data.items) do
    local why
    if type(it) ~= 'table' or type(it.photo_uuid) ~= 'string' or it.photo_uuid == ''
       or type(it.file_base) ~= 'string' or type(it.keywords) ~= 'table' then
      why = 'missing photo_uuid, file_base or keywords'
    else
      local ids = {}
      for _, name in ipairs(it.keywords) do
        local id = type(name) == 'string' and KT.idOfName(name)
        if not id then why = string.format('%q is not in the keyword taxonomy', tostring(name)); break end
        ids[#ids + 1] = id
      end
      if not why then out.items[#out.items + 1] = { uuid = it.photo_uuid, fileBase = it.file_base, ids = KW.withImplied(ids) } end
    end
    if why then out.invalid[#out.invalid + 1] = string.format('item %d: %s', i, why) end
  end
  return out
end

--- Pure: what applying a judgement does to one photograph: 'unchanged' (this file was applied
-- and nothing differs), 'conflict' (an earlier file was applied and the user has changed the
-- taxonomy keywords since: theirs stand), or 'apply'.
function KW.judgementAction(state, decidedText, present, item, source)
  local d = KW.parseDecided(decidedText)
  if state == S.golden and d then
    if join(KT.sorted(present)) == join(item.ids) and d.source == source then return 'unchanged' end
    if join(KT.sorted(present)) ~= join(KT.sorted(d.ids)) then return 'conflict' end
  end
  return 'apply'
end

-- ------------------------------------------------------------ Lightroom-bound

local function now() return os.date('!%Y-%m-%dT%H:%M:%SZ') end

--- Inside a write gate of its own: find or create each keyword (by id) at its taxonomy path,
-- every level once per command (`cache`, kept by the caller across gates). Created keywords
-- are not exported; existing ones are reused unchanged.
-- @return cache, where cache[id] is the keyword object
function KW.ensure(catalog, ids, cache)
  cache = cache or {}
  cache.levels = cache.levels or {}
  for _, id in ipairs(ids) do
    if not cache[id] then
      local path = KT.path(id)
      if not path then error('keyword ' .. tostring(id) .. ' is not in the keyword taxonomy', 0) end
      local parent, key
      for i, name in ipairs(path) do
        key = key and (key .. '\t' .. name) or name
        local kw = cache.levels[key]
        if not kw then
          kw = catalog:createKeyword(name, {}, false, parent, true)
          if not kw then error('keyword ' .. table.concat(path, ' > ', 1, i) .. ' not found or created', 0) end
          cache.levels[key] = kw
        end
        parent = kw
      end
      cache[id] = parent
    end
  end
  return cache
end

--- Inside a LATER write gate: apply a plan. Removals use the photograph's own keyword objects
-- (`refOf`, from presentIds), additions the prepared ones (`cache`, from ensure).
function KW.assign(photo, plan, cache, refOf)
  for _, id in ipairs(plan.remove) do
    if refOf[id] then photo:removeKeyword(refOf[id]) end
  end
  for _, id in ipairs(plan.add) do
    if not cache[id] then error('keyword ' .. tostring(id) .. ' was not prepared', 0) end
    photo:addKeyword(cache[id])
  end
end

local function lr()
  return import 'LrApplication', import 'LrDialogs', import 'LrTasks', import 'LrProgressScope',
         import 'LrFunctionContext'
end

local function write(catalog, title, fn)
  local _, LrDialogs, LrTasks = lr()
  -- withWriteAccessDo yields: LrTasks.pcall, never a plain pcall.
  local ok, err = LrTasks.pcall(function() catalog:withWriteAccessDo(title, fn, { timeout = 30 }) end)
  if not ok then
    require('GrLog').errorf('%s: write failed: %s', title, tostring(err))
    LrDialogs.message('Genreator: could not write to the catalog', tostring(err), 'critical')
  end
  return ok
end

--- The keyword head, or nil after telling the user why not.
local function keywordHead(cfg)
  local _, LrDialogs = lr()
  local Model = require 'GrModel'
  local present, modelErr = Model.check()
  if not present then
    LrDialogs.message('Genreator: the model is not installed', modelErr, 'critical')
    return nil
  end
  local manifest = Model.manifest() or {}
  local ok, err = KT.load(Model.dir())
  if not ok or type(manifest.keywords) ~= 'table' then
    LrDialogs.message('Genreator: no keyword suggestions', string.format(
      'The installed model %s has no keyword head (%s), so it suggests no keywords.',
      tostring(manifest.version), tostring(err or 'the manifest names none')), 'info')
    return nil
  end
  return manifest
end

local function readStates(catalog, photos, withRaw)
  local raw = withRaw and catalog:batchGetRawMetadata(photos, { 'fileFormat' }) or {}
  local plugin = catalog:batchGetPropertyForPlugin(photos, _PLUGIN.id,
    { F.keywordState, F.keywordSuggestion, F.keywordDecided }) or {}
  local out = {}
  for i, photo in ipairs(photos) do
    local p = plugin[photo] or {}
    out[i] = { photo = photo, isVideo = ((raw[photo] or {}).fileFormat == 'VIDEO'), state = p[F.keywordState] or '',
               suggestion = p[F.keywordSuggestion], decided = p[F.keywordDecided] }
  end
  return out
end

local function ensureCollections(catalog)
  local LrTasks = select(3, lr())
  local ok, err = LrTasks.pcall(function()
    local Collections = require 'GrCollections'
    Collections.setUp(catalog, _PLUGIN.id, Collections.KEYWORD_SET)
  end)
  if not ok then require('GrLog').warnf('keyword collections not set up: %s', tostring(err)) end
end

--- Suggest Keywords (mode suggest) or Re-suggest Keywords (mode resuggest) on the selection.
function KW.suggestSelection(mode)
  local LrApplication, LrDialogs, _, LrProgressScope, LrFunctionContext = lr()
  local Classifier = require 'GrClassifier'
  local Config     = require 'GrConfig'
  local Keywords   = require 'GrKeywords'
  local Log        = require 'GrLog'
  local Model      = require 'GrModel'
  local Rendition  = require 'GrRendition'
  local title = mode == KW.MODE.resuggest and 'Re-suggest Keywords' or 'Suggest Keywords'

  LrFunctionContext.postAsyncTaskWithContext('GenreatorKeywords', function(context)
    context:addFailureHandler(function(_, message)
      Log.error(title .. ' failed: ' .. tostring(message))
      LrDialogs.message('Genreator: unexpected error', tostring(message), 'critical')
    end)

    local cfg, cfgErr = Config.load()
    if not cfg then
      LrDialogs.message('Genreator: configuration problem', cfgErr, 'critical')
      return
    end
    Log.level = cfg.logLevel
    local manifest = keywordHead(cfg)
    if not manifest then return end

    local catalog = LrApplication.activeCatalog()
    local prep = LrProgressScope { title = 'Genreator: reading the selection', functionContext = context }
    prep:setCancelable(true)
    local selected = catalog:getTargetPhotos() or {}
    if #selected == 0 then
      prep:done()
      LrDialogs.message('Genreator', 'No photographs are selected. Select one or more photographs and try again.', 'info')
      return
    end
    local infos = readStates(catalog, selected, true)
    local stored = {}
    for _, info in ipairs(infos) do stored[info.photo] = info end
    local toRun, skipped = KW.plan(infos, mode, Classifier.isMissing)
    prep:done()
    if #toRun == 0 then
      LrDialogs.message('Genreator: nothing to do', KW.summaryText(mode, { ok = 0, added = 0, removed = 0, errors = 0 },
                                                                  skipped, false), 'info')
      return
    end

    local body = mode == KW.MODE.resuggest
      and 'The model suggests keywords again for verified photographs: new suggestions are added, ' ..
          'nothing is removed, and the photographs return to Keywords to Verify.'
      or 'The model\'s suggested keywords are added as keywords at once, under their categories at the root ' ..
         'of the keyword list, and the photographs go to Keywords to Verify. On a photograph awaiting ' ..
         'verification, keywords the model no longer suggests are removed; keywords you added are kept.'
    local answer = LrDialogs.confirm(
      string.format('%s for %d photograph%s?', title, #toRun, #toRun == 1 and '' or 's'),
      body .. string.format('\n\nKeyword taxonomy %s, rule %s. Genres, ratings and other keywords are untouched.',
                            tostring(KT.version), cfg.keywordRule) .. '\n\n' ..
      'If Lightroom syncs this catalog, pause sync first (cloud icon, top right).',
      title, 'Cancel')
    if answer ~= 'ok' then return end

    ensureCollections(catalog)

    local runId = Classifier.newRunId()
    local tempDir = Rendition.createTempDir(runId)
    context:addCleanupHandler(function() Rendition.removeTempDir(tempDir) end)
    Rendition.cleanStaleTempDirs(tempDir)
    Log.infof('keyword run %s start: mode=%s photos=%d model=%s taxonomy=%s rule=%s', runId, mode, #toRun,
              tostring(manifest.version), tostring(KT.version), cfg.keywordRule)

    local progress = LrProgressScope { title = string.format('Genreator: keywording %d photographs', #toRun),
                                       functionContext = context }
    progress:setCancelable(true)
    local cancelFile = tempDir .. '/cancel'
    local counts = { ok = 0, added = 0, removed = 0, errors = 0, changed = 0, done = 0 }
    local cache, fatal = {}, nil

    -- An error marks a photograph with no keyword state yet (or an earlier error); one already
    -- suggested or verified keeps its state, and the error is in its keywordError field.
    local function markError(photo, message)
      local state = stored[photo] and stored[photo].state or ''
      if state == '' or state == S.error then Metadata.set(photo, F.keywordState, S.error) end
      Metadata.set(photo, F.keywordError, message)
    end

    for _, chunkPhotos in ipairs(Classifier.chunk(toRun, cfg.chunkSize)) do
      if progress:isCanceled() or fatal then break end
      -- The keyword head reads the image only: the Personal flag is not read.
      local failed, items, results, _, fatalErr = Classifier.scoreChunk(chunkPhotos, function() return false end,
        tempDir, cfg, progress, cancelFile, counts, #toRun, 'Keywording')
      fatal = fatalErr
      if fatal then Log.errorf('keyword run %s stopped: %s', runId, tostring(fatal.code)) end

      local errors, pending, ids = {}, {}, {}
      for _, f in ipairs(failed) do errors[#errors + 1] = { photo = f.photo, message = tostring(f.errorCode) .. ': ' .. tostring(f.errorMessage) } end
      for _, it in ipairs(results and items or {}) do
        local r = results[it.requestId]
        if r.keywords and not r.keywordError then
          local s = Model.deriveKeywords(r.keywords, cfg.keywordRule)
          pending[#pending + 1] = { photo = it.photo, s = s }
          for _, id in ipairs(s.ids) do ids[#ids + 1] = id end
        elseif r.error ~= 'canceled' then
          errors[#errors + 1] = { photo = it.photo, message = tostring(r.keywordError or r.message or 'the answer has no keywords') }
        end
      end

      if #pending > 0 and not write(catalog, 'Genreator: keywords (create)', function()
        KW.ensure(catalog, ids, cache)
      end) then return end

      local at = now()
      if (#pending > 0 or #errors > 0) and not write(catalog, 'Genreator: ' .. title, function()
        for _, e in ipairs(errors) do markError(e.photo, e.message) end
        for _, p in ipairs(pending) do
          local state = Metadata.get(p.photo, F.keywordState) or ''
          local previous = KW.parseSuggestion(Metadata.get(p.photo, F.keywordSuggestion))
          local present, refOf = KW.presentIds(Keywords.currentOf(p.photo))
          local plan = KW.syncPlan(mode, state, present, previous and previous.ids or {}, p.s.ids)
          if plan then
            KW.assign(p.photo, plan, cache, refOf)
            Metadata.set(p.photo, F.keywordState, S.suggested)
            Metadata.set(p.photo, F.keywordSuggestion, KW.suggestionText {
              -- The keyword model's own version: a new keyword model can come on the same genre model.
              modelVersion = manifest.keywords.version, taxonomyVersion = KT.version, rule = cfg.keywordRule, at = at,
              ids = p.s.ids, agreed = p.s.agreed, implied = p.s.implied })
            Metadata.set(p.photo, F.keywordError, '')
            counts.ok = counts.ok + 1
            counts.added = counts.added + #plan.add
            counts.removed = counts.removed + #plan.remove
          else
            counts.changed = counts.changed + 1
          end
        end
      end) then return end
      counts.errors = counts.errors + #errors
      for _, e in ipairs(errors) do Log.warnf('not keyworded: %s', e.message) end
      counts.done = counts.done + #chunkPhotos
      progress:setPortionComplete(counts.done, #toRun)
    end
    Log.infof('keyword run %s done: ok=%d added=%d removed=%d errors=%d', runId, counts.ok, counts.added,
              counts.removed, counts.errors)

    if fatal then
      LrDialogs.message('Genreator: run stopped', string.format(
        'The model failed: %s\n\nKeyworded before stopping: %d. The remaining photographs are unchanged. ' ..
        'Check Model (File > Plug-in Extras) checks the installation.', tostring(fatal.message), counts.ok), 'critical')
      return
    end
    LrDialogs.message('Genreator', KW.summaryText(mode, counts, skipped, progress:isCanceled()), 'info')
  end)
end

--- Mark Keywords Verified: each selected photograph awaiting verification records the
-- taxonomy keywords it now has as the decision (R10.4). No keyword changes.
function KW.markVerified()
  local LrApplication, LrDialogs, _, _, LrFunctionContext = lr()
  LrFunctionContext.postAsyncTaskWithContext('GenreatorMarkVerified', function(context)
    context:addFailureHandler(function(_, message)
      LrDialogs.message('Genreator: Mark Keywords Verified failed', tostring(message), 'critical')
    end)
    local Keywords = require 'GrKeywords'
    local Model = require 'GrModel'
    local ok, err = KT.load(Model.dir())
    if not ok then
      LrDialogs.message('Genreator: no keyword suggestions', 'The installed model has no keyword head (' .. tostring(err) .. ').', 'info')
      return
    end
    local catalog = LrApplication.activeCatalog()
    local selected = catalog:getTargetPhotos() or {}
    local counts = { verified = 0, other = 0 }
    local at = now()
    local infos = readStates(catalog, selected)
    if not write(catalog, 'Genreator: Mark Keywords Verified', function()
      for _, info in ipairs(infos) do
        -- Re-read inside the gate: another command may have decided it since.
        if info.state == S.suggested and Metadata.get(info.photo, F.keywordState) == S.suggested then
          local present = KW.presentIds(Keywords.currentOf(info.photo))
          Metadata.set(info.photo, F.keywordState, S.verified)
          Metadata.set(info.photo, F.keywordDecided, KW.decidedText { source = KW.VERIFIED, at = at, ids = present })
          counts.verified = counts.verified + 1
        else
          counts.other = counts.other + 1
        end
      end
    end) then return end
    require('GrLog').infof('Mark Keywords Verified: verified=%d other=%d', counts.verified, counts.other)
    LrDialogs.message('Genreator: Mark Keywords Verified', string.format(
      'Verified: %d.%s', counts.verified,
      counts.other > 0 and string.format('\nLeft alone (not awaiting verification): %d.', counts.other) or ''), 'info')
  end)
end

--- Apply Keyword Judgements…: a file of the user's own keyword judgements (R10.6).
function KW.applyJudgements()
  local LrApplication, LrDialogs, _, LrProgressScope, LrFunctionContext = lr()
  LrFunctionContext.postAsyncTaskWithContext('GenreatorApplyJudgements', function(context)
    context:addFailureHandler(function(_, message)
      LrDialogs.message('Genreator: Apply Keyword Judgements failed', tostring(message), 'critical')
    end)
    local Approved = require 'GrApproved'
    local Keywords = require 'GrKeywords'
    local LrFileUtils = import 'LrFileUtils'
    local cfg, cfgErr = require('GrConfig').load()
    if not cfg then
      LrDialogs.message('Genreator: configuration problem', cfgErr, 'critical')
      return
    end
    if not keywordHead(cfg) then return end

    local paths = LrDialogs.runOpenPanel {
      title = 'Apply Keyword Judgements', prompt = 'Choose',
      canChooseFiles = true, canChooseDirectories = false, allowsMultipleSelection = false,
      fileTypes = { 'json' },
    }
    if not paths or not paths[1] then return end
    local parsed, err = KW.parseJudgements(LrFileUtils.readFile(paths[1]))
    if not parsed then
      LrDialogs.message('Genreator: Apply Keyword Judgements', err, 'critical')
      return
    end

    local catalog = LrApplication.activeCatalog()
    local matched, skipped = Approved.match(catalog, parsed.items)
    local photos = {}
    for i, m in ipairs(matched) do photos[i] = m.photo end
    local work, counts = {}, { applied = 0, unchanged = 0, conflict = 0 }
    for i, info in ipairs(readStates(catalog, photos)) do
      local item = matched[i].item
      local present, refOf = KW.presentIds(Keywords.currentOf(info.photo))
      local action = KW.judgementAction(info.state, info.decided, present, item, parsed.source)
      if action == 'apply' then
        work[#work + 1] = { photo = info.photo, item = item, plan = KW.exactPlan(present, item.ids), refOf = refOf }
      else
        counts[action] = counts[action] + 1
      end
    end

    local notes = {}
    for reason, n in pairs(skipped) do notes[#notes + 1] = string.format('Skipped %d: %s', n, reason) end
    if counts.unchanged > 0 then notes[#notes + 1] = string.format('Already applied: %d', counts.unchanged) end
    if counts.conflict > 0 then
      notes[#notes + 1] = string.format('Kept your later keyword changes (conflicts, not applied): %d', counts.conflict)
    end
    if #parsed.invalid > 0 then
      notes[#notes + 1] = string.format('Invalid %d (first: %s)', #parsed.invalid, parsed.invalid[1])
    end
    table.sort(notes)
    if #work == 0 then
      LrDialogs.message('Genreator: Apply Keyword Judgements', 'Nothing to apply.\n\n' .. table.concat(notes, '\n'), 'info')
      return
    end
    local answer = LrDialogs.confirm(
      string.format('Apply keyword judgements to %d photograph%s?', #work, #work == 1 and '' or 's'),
      'Each gets exactly the judged keywords of the keyword taxonomy (other keywords are untouched) and is ' ..
      'marked judged: Suggest Keywords will not change it.\n\n' ..
      'If Lightroom syncs this catalog, pause sync first (cloud icon, top right).' ..
      (#notes > 0 and ('\n\n' .. table.concat(notes, '\n')) or ''), 'Apply', 'Cancel')
    if answer ~= 'ok' then return end

    ensureCollections(catalog)
    local ids = {}
    for _, w in ipairs(work) do for _, id in ipairs(w.plan.add) do ids[#ids + 1] = id end end
    local cache = {}
    if not write(catalog, 'Genreator: keywords (create)', function() KW.ensure(catalog, ids, cache) end) then return end
    local progress = LrProgressScope { title = 'Genreator: applying keyword judgements', functionContext = context }
    local at = now()
    if not write(catalog, 'Genreator: Apply Keyword Judgements', function()
      for _, w in ipairs(work) do
        KW.assign(w.photo, w.plan, cache, w.refOf)
        Metadata.set(w.photo, F.keywordState, S.golden)
        Metadata.set(w.photo, F.keywordDecided, KW.decidedText { source = parsed.source, at = at, ids = w.item.ids })
        Metadata.set(w.photo, F.keywordSuggestion, '')
        Metadata.set(w.photo, F.keywordError, '')
        counts.applied = counts.applied + 1
      end
    end) then progress:done(); return end
    progress:done()
    local summary = string.format('Applied: %d.', counts.applied) .. (#notes > 0 and ('\n' .. table.concat(notes, '\n')) or '')
    require('GrLog').infof('Apply Keyword Judgements: %s', (summary:gsub('\n', '; ')))
    LrDialogs.message('Genreator: Apply Keyword Judgements', summary, 'info')
  end)
end

return KW
