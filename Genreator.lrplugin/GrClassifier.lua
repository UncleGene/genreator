--[[
GrClassifier — orchestration.

Control flow (docs/architecture.md):
  config → model check → filter selection → confirm (with the Personal count) → temp dir →
  per chunk { render to files → one model call → delete the files → one batched catalog
  write } → cleanup via context handler.

Write access is taken once per chunk rather than per photo: per-photo write access is slow
and floods Lightroom's undo history. One model call per chunk pays the encoder's start-up
(about 2 s) once per chunk rather than per photograph.
]]

local LrApplication     = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrDialogs         = import 'LrDialogs'

local Cli       = require 'GrCli'
local Config    = require 'GrConfig'
local Log       = require 'GrLog'
local Metadata  = require 'GrMetadata'
local Model     = require 'GrModel'
local Pick      = require 'GrPick'
local Rendition = require 'GrRendition'

local Classifier = {}

-- ---------------------------------------------------------------- helpers

local function newRunId()
  return string.format('r-%s-%04x', os.date('!%Y%m%dT%H%M%SZ'), math.random(0, 0xFFFF))
end
Classifier.newRunId = newRunId

--- Pure: split an array into chunks of at most n.
function Classifier.chunk(list, n)
  local out = {}
  local current = {}
  for i = 1, #list do
    current[#current + 1] = list[i]
    if #current >= n then
      out[#out + 1] = current
      current = {}
    end
  end
  if #current > 0 then out[#out + 1] = current end
  return out
end

--- Pure: decide which photos to process.
-- A photograph left in error has no suggestion, so Classify retries it rather than counting
-- it as classified: re-running Classify on the same photographs then finishes an
-- interrupted run.
-- @param infos array of { photo, isVideo, isMissing, isClassified, isError }
-- @param opts { reclassify = boolean }
-- @return keep array, skipped table of counts (plus `retrying`, which is not a skip)
function Classifier.filterSelection(infos, opts)
  opts = opts or {}
  local keep, skipped = {}, { video = 0, missing = 0, alreadyClassified = 0, retrying = 0 }
  for _, info in ipairs(infos) do
    if info.isVideo then
      skipped.video = skipped.video + 1
    elseif info.isMissing then
      skipped.missing = skipped.missing + 1
    elseif info.isClassified and not info.isError and not opts.reclassify then
      skipped.alreadyClassified = skipped.alreadyClassified + 1
    else
      if info.isError then skipped.retrying = skipped.retrying + 1 end
      keep[#keep + 1] = info.photo
    end
  end
  return keep, skipped
end

--- Pure: the confirmation text before a run (ADR-024): how many photographs carry the
-- Personal tag, since the model treats an untagged photograph as not personal; and the floor
-- their genres are held to, when it applies (ADR-028).
function Classifier.confirmText(count, personal, preTagged, keyword, floor)
  local lines = {
    string.format('%d of the %d photograph%s %s tagged personal (%s, or a keyword under it).',
                  personal, count, count == 1 and '' or 's', personal == 1 and 'is' or 'are', keyword),
    'The model treats a photograph without the tag as not personal. Tag your personal ' ..
    'photographs first if you have not.',
  }
  if floor and personal > 0 then
    lines[#lines + 1] = string.format('On personal photographs a genre is suggested only when the model ' ..
                                      'rates it at least %s as well as its cut-off (the recommended floor; ' ..
                                      'config personalFloor).', tostring(floor))
  end
  if preTagged > 0 then
    lines[#lines + 1] = string.format('%d already carr%s a genre keyword: kept, and included in the suggestion.',
                                      preTagged, preTagged == 1 and 'ies' or 'y')
  end
  return table.concat(lines, '\n\n')
end

--- true / false when Lightroom answers; nil when it cannot (the key is documented but has
-- not been seen working in Lightroom). nil means "try the export": a failed render is a
-- visible per-photo error, which beats silently skipping a photo that could have worked.
Classifier.smartPreviewKeyBroken = false
function Classifier.hasSmartPreview(photo)
  if Classifier.smartPreviewKeyBroken then return nil end
  -- LrTasks.pcall: a catalog read yields; plain pcall fails in Lightroom (2026-10-03).
  local ok, info = LrTasks.pcall(function() return photo:getRawMetadata('smartPreviewInfo') end)
  if not ok then
    Classifier.smartPreviewKeyBroken = true
    Log.warnf('smartPreviewInfo unavailable (%s); offline photos will be attempted', tostring(info))
    return nil
  end
  return type(info) == 'table' and next(info) ~= nil
end

--- Video format and review state for the whole selection, in two batched catalog reads
-- (one read per photo takes minutes on a selection of thousands).
local function readSelection(catalog, selected)
  local raw = catalog:batchGetRawMetadata(selected, { 'fileFormat' }) or {}
  local plugin = catalog:batchGetPropertyForPlugin(selected, _PLUGIN.id, { Metadata.FIELDS.reviewState }) or {}
  local out = {}
  for i, photo in ipairs(selected) do
    local state = (plugin[photo] or {})[Metadata.FIELDS.reviewState]
    out[i] = { photo = photo, isVideo = ((raw[photo] or {}).fileFormat == 'VIDEO'),
               state = (state == nil or state == '') and Metadata.STATE.unclassified or state }
  end
  return out
end

--- Availability is a method, not a raw-metadata key ('isMissing' raises "Unknown key"),
-- and it must run inside a task, which classifySelection guarantees.
-- With the original offline, Lightroom can still export from a Smart Preview (~2560 px,
-- far above the rendition size), so only "no original AND no Smart Preview" is missing.
local function isMissing(photo)
  return not photo:checkPhotoAvailability() and Classifier.hasSmartPreview(photo) == false
end
Classifier.isMissing = isMissing

local function gatherSelection(catalog, opts, progress)
  local selected = catalog:getTargetPhotos() or {}
  local infos = {}
  for i, r in ipairs(readSelection(catalog, selected)) do
    if progress:isCanceled() then return nil end
    infos[#infos + 1] = {
      photo        = r.photo,
      isVideo      = r.isVideo,
      isMissing    = not r.isVideo and isMissing(r.photo),
      isClassified = r.state ~= Metadata.STATE.unclassified,
      isError      = r.state == Metadata.STATE.error,
    }
    progress:setPortionComplete(i, #selected)
  end
  local keep, skipped = Classifier.filterSelection(infos, opts)
  return keep, skipped, #infos
end

--- Pick mode: a random sample (Pick.sampleSize) of photographs never classified (an earlier
-- error is not a fresh candidate). Availability, the slow check, runs on the shuffled
-- candidates only until the sample is full.
-- @return sample, the number of unclassified photographs, the number selected, how many
--         photographs of earlier picks still await review (anywhere in the catalog), and how
--         many candidates were skipped as offline; nil when cancelled
local function gatherSample(catalog, n, progress)
  local selected = catalog:getTargetPhotos() or {}
  local pool = {}
  for _, r in ipairs(readSelection(catalog, selected)) do
    if not r.isVideo and r.state == Metadata.STATE.unclassified then pool[#pool + 1] = r.photo end
  end
  -- Lua 5.1 repeats the same sequence after every restart unless seeded.
  math.randomseed(os.time())
  local want = math.min(#pool, Pick.sampleSize(n))
  local sample, missing = {}, 0
  for _, photo in ipairs(Pick.shuffled(pool, math.random)) do
    if #sample >= want then break end
    if progress:isCanceled() then return nil end
    if isMissing(photo) then missing = missing + 1 else sample[#sample + 1] = photo end
    progress:setPortionComplete(#sample, want)
  end
  local waiting = 0
  local earlier = catalog:findPhotosWithProperty(_PLUGIN.id, Metadata.FIELDS.pickReason) or {}
  for _, r in ipairs(readSelection(catalog, earlier)) do
    if r.state == Metadata.STATE.suggested then waiting = waiting + 1 end
  end
  return sample, #pool, #selected, waiting, missing
end

--- Human-readable summary of what was skipped.
local function describeSkips(skipped)
  local parts = {}
  if skipped.video > 0 then
    parts[#parts + 1] = string.format('%d video', skipped.video)
  end
  if skipped.missing > 0 then
    parts[#parts + 1] = string.format('%d with the original offline and no Smart Preview', skipped.missing)
  end
  if skipped.alreadyClassified > 0 then
    parts[#parts + 1] = string.format('%d already classified', skipped.alreadyClassified)
  end
  local text = #parts > 0 and ('Skipped: ' .. table.concat(parts, ', ') .. '.') or nil
  if (skipped.retrying or 0) > 0 then
    local retry = string.format('Retried after an earlier error: %d.', skipped.retrying)
    text = text and (text .. '\n' .. retry) or retry
  end
  return text
end

--- While the model runs, LrTasks.execute blocks this task; a second task turns Lightroom's
-- Cancel into the model's cancel file, so a long call stops between photographs. It needs no
-- failure handler of its own: it only polls and writes a file, and Cli.writeFile returns
-- nil rather than raising.
local function watchCancel(progress, cancelFile, state)
  LrTasks.startAsyncTask(function()
    while state.running do
      if progress:isCanceled() then
        Cli.writeFile(cancelFile, 'cancel')
        return
      end
      LrTasks.sleep(0.5)
    end
  end)
end

-- ---------------------------------------------------------------- one chunk

--- Render one chunk, run the model once on it, and delete the renditions, whatever the
-- outcome (R8.2). Shared by Classify and Suggest Ratings (ADR-029): the model answers genres
-- and the rating in the same call; what is written is the caller's.
-- @param personalOf function(photo) -> the Personal flag the model is given
-- @param counts { done } photographs finished before this chunk, for the captions
-- @return failed renders { {photo, errorCode, errorMessage} }, items { {requestId, photo, …} },
--         results (GrModel.parseResponse, nil without items or when the model failed), modelId,
--         fatal { code, message } when the model failed as a whole
function Classifier.scoreChunk(chunkPhotos, personalOf, tempDir, cfg, progress, cancelFile, counts, total, verb)
  local failed, items, files = {}, {}, {}
  Rendition.renderBatch(chunkPhotos, tempDir, cfg, function(photo, path, info)
    if not path then
      failed[#failed + 1] = { photo = photo, errorCode = info.errorCode, errorMessage = info.errorMessage }
      return
    end
    files[#files + 1] = path
    items[#items + 1] = { requestId = 'p' .. (#items + 1), photoId = photo.localIdentifier,
                          imagePath = path, personal = personalOf(photo), photo = photo }
  end, progress)

  local results, modelId, code, msg, fatal
  if #items > 0 and not progress:isCanceled() then
    progress:setCaption(string.format('%s %d–%d of %d', verb, counts.done + 1, counts.done + #chunkPhotos, total))
    local watch = { running = true }
    watchCancel(progress, cancelFile, watch)
    results, modelId, msg = Model.run(items, tempDir, cfg, cancelFile)
    watch.running = false
    if not results then code = modelId; modelId = nil end
  end
  for _, path in ipairs(files) do Rendition.deleteFile(path) end

  if #items > 0 and not results and not progress:isCanceled() then fatal = { code = code, message = msg } end
  return failed, items, results, modelId, fatal
end

-- ---------------------------------------------------------------- main entry

--- Classify the current selection.
-- @param opts { reclassify = boolean, pick = { n } }. With `pick` (Pick Photos to Review…,
--        temporary): sample unclassified photographs (Pick.sampleSize), score them, and
--        write suggestions only for the n GrPick chooses (half random, half by score); the
--        rest stay unclassified.
function Classifier.classifySelection(opts)
  opts = opts or {}

  LrFunctionContext.postAsyncTaskWithContext('GenreatorClassify', function(context)
    -- Lightroom drops errors raised inside an async task without a word; surface them.
    context:addFailureHandler(function(_, message)
      Log.error('classify failed: ' .. tostring(message))
      LrDialogs.message('Genreator: unexpected error', tostring(message), 'critical')
    end)

    -- 1. Config and model. Abort before any work if either is wrong.
    local cfg, cfgErr = Config.load()
    if not cfg then
      LrDialogs.message('Genreator: configuration problem', cfgErr, 'critical')
      return
    end
    Log.level = cfg.logLevel
    local present, modelErr = Model.check()
    if not present then
      LrDialogs.message('Genreator: the model is not installed', modelErr, 'critical')
      return
    end
    local manifest = Model.manifest() or {}
    -- The model's recommended floor for personal photographs (ADR-028): the ranking is marked
    -- for it whatever the setting, so a change of the setting can be re-derived later.
    local floor = Model.personalFloor(manifest)

    -- 2. Selection. Reading a large one takes a while, so it gets its own progress bar.
    local catalog = LrApplication.activeCatalog()
    local pick = opts.pick
    local prep = LrProgressScope {
      title           = pick and 'Genreator: drawing a sample to pick from' or 'Genreator: reading the selection',
      functionContext = context,
    }
    prep:setCancelable(true)
    local photos, skipped, selectedCount, poolSize, waiting, missing
    if pick then
      photos, poolSize, selectedCount, waiting, missing = gatherSample(catalog, pick.n, prep)
    else
      photos, skipped, selectedCount = gatherSelection(catalog, opts, prep)
    end
    if not photos or prep:isCanceled() then prep:done(); return end

    if selectedCount == 0 then
      prep:done()
      LrDialogs.message('Genreator',
        'No photographs are selected. Select one or more photographs and try again.', 'info')
      return
    end

    if #photos == 0 then
      prep:done()
      if pick then
        LrDialogs.message('Genreator: nothing to do', missing > 0
          and string.format('The %d unclassified photograph%s of the selection %s the original offline and ' ..
                            'no Smart Preview.', missing, missing == 1 and '' or 's', missing == 1 and 'has' or 'have')
          or 'No unclassified photographs in the selection.', 'info')
        return
      end
      local hint = ''
      if skipped.alreadyClassified > 0 then
        hint = hint .. '\n\nUse "Reclassify Selected Photos" to classify already-classified photographs again.'
      end
      if skipped.missing > 0 then
        hint = hint .. '\n\nReconnect the drive holding the originals, or build Smart Previews ' ..
                       '(Library > Previews > Build Smart Previews).'
      end
      LrDialogs.message('Genreator: nothing to do', (describeSkips(skipped) or '') .. hint, 'info')
      return
    end

    -- 3. The model's inputs from the user's keywords, then confirm with the Personal count.
    prep:setCaption('Reading keywords')
    local inputs, personal, preTagged = {}, 0, 0
    for i, photo in ipairs(photos) do
      if prep:isCanceled() then prep:done(); return end
      local inp = Metadata.inputsOf(photo, cfg.personalPath)
      -- Which genre keywords are the user's: not the decisions the plugin wrote (ADR-023).
      local F = Metadata.FIELDS
      local tags = Metadata.userTags(inp.preTags, {
        aiGenre = Metadata.get(photo, F.aiGenre), userGenres = Metadata.get(photo, F.userGenres),
        reviewState = Metadata.reviewState(photo), humanGenres = Metadata.get(photo, F.humanGenres) })
      inp.preTags, inp.userGenres, inp.laterUserGenres = tags.preTags, tags.userGenres, tags.laterUserGenres
      inputs[photo] = inp
      if inp.personal then personal = personal + 1 end
      if #inp.preTags > 0 then preTagged = preTagged + 1 end
      prep:setPortionComplete(i, #photos)
    end
    prep:done()
    local answer = LrDialogs.confirm(
      pick and string.format('Pick %d of %d unclassified photographs to review?', math.min(pick.n, #photos), poolSize)
           or string.format('Classify %d photograph%s?', #photos, #photos == 1 and '' or 's'),
      (pick and string.format('The model scores a random sample of %d; %d of them get suggestions, ' ..
                              'an equal share for each suggested primary genre, where the model is ' ..
                              'least sure first. The rest stay unclassified.\n\n', #photos, math.min(pick.n, #photos)) ..
               (waiting > 0 and string.format('%d photograph%s from earlier picks %s still awaiting review; ' ..
                                              'the new picks join them in Awaiting Review.\n\n',
                                              waiting, waiting == 1 and '' or 's', waiting == 1 and 'is' or 'are') or '')
            or '') ..
      Classifier.confirmText(#photos, personal, preTagged, table.concat(cfg.personalPath, ' > '),
                             Model.usesFloor(true, cfg.personalFloor, floor) and floor or nil),
      pick and 'Pick' or 'Classify', 'Cancel')
    if answer ~= 'ok' then return end

    -- 4. Temp directory, removed on every exit path including cancel and error.
    local runId = newRunId()
    local tempDir = Rendition.createTempDir(runId)
    context:addCleanupHandler(function()
      Rendition.removeTempDir(tempDir)
    end)
    Rendition.cleanStaleTempDirs(tempDir)

    Log.infof('run %s start: photos=%d personal=%d model=%s personalFloor=%s(%s)', runId, #photos, personal,
              tostring(manifest.version), cfg.personalFloor, tostring(floor))

    local progress = LrProgressScope {
      title           = pick and string.format('Genreator: scoring %d photographs to pick %d',
                                               #photos, math.min(pick.n, #photos))
                             or string.format('Genreator: classifying %d photographs', #photos),
      functionContext = context,
    }
    progress:setCancelable(true)

    local runCtx = { runId = runId, model = manifest.model_id, modelVersion = manifest.version }
    local counts = { ok = 0, errors = 0, done = 0 }
    -- Set when the model fails as a whole (missing, crashed, wrong taxonomy): every
    -- remaining photograph would share it, so the run stops and they stay unclassified.
    local fatal = nil
    local cancelFile = tempDir .. '/cancel'
    -- Pick mode: every answer is held until all are in, then only the chosen are written.
    local candidates = {}

    for chunkIndex, chunkPhotos in ipairs(Classifier.chunk(photos, cfg.chunkSize)) do
      if progress:isCanceled() or fatal then break end
      progress:setCaption(string.format('Rendering %d–%d of %d', counts.done + 1,
                                        counts.done + #chunkPhotos, #photos))

      local pending = {}
      local failed, items, results, modelId, fatalErr = Classifier.scoreChunk(chunkPhotos, function(photo)
        return inputs[photo].personal
      end, tempDir, cfg, progress, cancelFile, counts, #photos, pick and 'Scoring' or 'Classifying')
      for _, f in ipairs(failed) do
        if pick then counts.errors = counts.errors + 1
        else pending[#pending + 1] = { photo = f.photo, ok = false, errorCode = f.errorCode, errorMessage = f.errorMessage } end
      end
      if fatalErr then
        fatal = fatalErr
        Log.errorf('run %s stopped: %s', runId, tostring(fatal.code))
      end
      for _, it in ipairs(results and items or {}) do
        local r = results[it.requestId]
        if r.ranked then
          local inp = inputs[it.photo]
          Model.markFloor(r.ranked, floor)
          local s = Model.suggest(r.ranked, inp.preTags, r.noGenre,
                                  Model.usesFloor(inp.personal, cfg.personalFloor, floor))
          s.ranking = Model.rankingText(r.ranked, r.noGenre, floor)
          s.personal = inp.personal
          s.userGenres = inp.userGenres
          s.laterUserGenres = inp.laterUserGenres
          if pick then
            candidates[#candidates + 1] = { key = it.photo, result = r, group = s.primary, suggestion = s }
          else
            pending[#pending + 1] = { photo = it.photo, ok = true, suggestion = s }
          end
        elseif pick then
          if r.error ~= 'canceled' then counts.errors = counts.errors + 1 end
        elseif r.error ~= 'canceled' then
          pending[#pending + 1] = { photo = it.photo, ok = false, errorCode = r.error, errorMessage = r.message }
        end
      end
      if results and modelId then runCtx.model = modelId end

      -- One write-access gate per chunk. withWriteAccessDo yields, and Lightroom cannot
      -- yield across a plain pcall ("must be called from within an LrTask").
      local okWrite, writeErr = LrTasks.pcall(function()
        catalog:withWriteAccessDo('Genreator: classify', function()
          for _, item in ipairs(pending) do
            if item.ok then
              Metadata.writeSuggestion(item.photo, item.suggestion, runCtx)
              counts.ok = counts.ok + 1
            else
              Metadata.writeError(item.photo, item.errorCode, item.errorMessage, runCtx)
              counts.errors = counts.errors + 1
            end
          end
        end, { timeout = 30 })
      end)
      if not okWrite then
        Log.errorf('chunk %d write failed: %s', chunkIndex, tostring(writeErr))
        LrDialogs.message('Genreator: could not write to the catalog', tostring(writeErr), 'critical')
        return
      end
      counts.done = counts.done + #chunkPhotos
      progress:setPortionComplete(counts.done, #photos)
    end

    if pick and not fatal and not progress:isCanceled() then
      local suggestionOf = {}
      for _, c in ipairs(candidates) do suggestionOf[c.key] = c.suggestion end
      local picked = {}
      for _, c in ipairs(Pick.choose(candidates, pick.n, math.random)) do
        suggestionOf[c.key].pickReason = c.reason
        picked[#picked + 1] = c.key
      end
      local okWrite, writeErr = LrTasks.pcall(function()
        catalog:withWriteAccessDo('Genreator: pick photos to review', function()
          for _, photo in ipairs(picked) do Metadata.writeSuggestion(photo, suggestionOf[photo], runCtx) end
        end, { timeout = 60 })
      end)
      if not okWrite then
        LrDialogs.message('Genreator: could not write to the catalog', tostring(writeErr), 'critical')
        return
      end
      Log.infof('run %s picked %d of %d by %s', runId, #picked, #candidates, Pick.VERSION)
      local Collections = require 'GrCollections'
      LrDialogs.message('Genreator: photos picked', string.format(
        'Picked %d of %d scored (an equal share per suggested primary genre), by %s. They have ' ..
        'suggestions and are in "%s > %s"; the rest stay unclassified.%s', #picked, #candidates, Pick.VERSION,
        Collections.SET_NAME, Collections.AWAITING,
        counts.errors > 0 and string.format('\n\n%d of the sample could not be classified and were left out.', counts.errors) or ''),
        'info')
      return
    elseif pick and not fatal then
      LrDialogs.message('Genreator', 'Pick was cancelled; nothing was written.', 'info')
      return
    end

    Log.infof('run %s done: ok=%d errors=%d', runId, counts.ok, counts.errors)

    if fatal then
      LrDialogs.message('Genreator: run stopped',
        string.format('The model failed: %s\n\n' .. (pick and 'Nothing was picked or written. ' or '') ..
                      'Classified before stopping: %d. The remaining ' ..
                      'photographs were left unclassified, not marked as errors. Check Model ' ..
                      '(File > Plug-in Extras) checks the installation.',
                      tostring(fatal.message), counts.ok),
        'critical')
      return
    end

    local lines = { string.format('Classified: %d', counts.ok) }
    if counts.errors > 0 then
      lines[#lines + 1] = string.format('Errors: %d (see review state "error")', counts.errors)
    end
    local skipText = describeSkips(skipped)
    if skipText then lines[#lines + 1] = skipText end
    if progress:isCanceled() then
      lines[#lines + 1] = 'Run was cancelled; completed results were kept. Classify the same ' ..
                          'photographs again to continue: finished ones are skipped.'
    elseif counts.errors > 0 then
      lines[#lines + 1] = 'Classify the same photographs again to retry the errors.'
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'Suggestions are in plugin metadata only. No keywords were ' ..
                        'written until you accept or correct them.'

    LrDialogs.message('Genreator', table.concat(lines, '\n'), 'info')
  end)
end

return Classifier
