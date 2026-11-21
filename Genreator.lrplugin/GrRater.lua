--[[
GrRater — Suggest Ratings (ADR-029): the model's suggested rating, as an action of its own.

Classifying and rating are separate commands, so a rating round never changes a genre
suggestion or its review, and a classification never writes a rating. The model answers both
in one call; Suggest Ratings renders the photographs and reads only the rating from that answer.

It writes the plugin's rating fields and nothing else: not the review state, not the genres,
never the Lightroom star rating. A photograph is rated whatever its review state. One already
rated by the bundled model is not rendered again: its bucket is re-derived from the stored
buckets when the ratio setting has changed, else it is skipped. A photograph that fails keeps
whatever rating it had; running the command again retries it.

Control flow: config → model check (and its rating head) → selection → confirm → re-derived
buckets in one write → per chunk { GrClassifier.scoreChunk → one batched catalog write }.
]]

local LrApplication     = import 'LrApplication'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'
local LrTasks           = import 'LrTasks'
local LrDialogs         = import 'LrDialogs'

local Classifier = require 'GrClassifier'
local Config     = require 'GrConfig'
local Log        = require 'GrLog'
local Metadata   = require 'GrMetadata'
local Model      = require 'GrModel'
local Rendition  = require 'GrRendition'

local Rater = {}

local F = Metadata.FIELDS

--- Pure: what to do with each photograph of the selection.
-- @param infos array of { photo, isVideo, ratingModelVersion, ratingBuckets, ratingBucket, ratingRatio }
-- @param isMissing function(photo): the original offline and no Smart Preview (asked only of
--        photographs to render, since it is the slow check)
-- @return toRate (photos), rederive { {photo, bucket, ratio} }, skipped { video, missing, alreadyRated }
function Rater.plan(infos, modelVersion, ratio, isMissing)
  local toRate, rederive = {}, {}
  local skipped = { video = 0, missing = 0, alreadyRated = 0 }
  for _, info in ipairs(infos) do
    local bucket, key
    if info.ratingModelVersion == modelVersion and modelVersion ~= nil then
      bucket, key = Model.rederiveBucket(info.ratingBuckets, ratio)
    end
    if info.isVideo then
      skipped.video = skipped.video + 1
    elseif bucket ~= nil then
      if tostring(bucket) == info.ratingBucket and key == info.ratingRatio then
        skipped.alreadyRated = skipped.alreadyRated + 1
      else
        rederive[#rederive + 1] = { photo = info.photo, bucket = bucket, ratio = key }
      end
    elseif isMissing(info.photo) then
      skipped.missing = skipped.missing + 1
    else
      toRate[#toRate + 1] = info.photo
    end
  end
  return toRate, rederive, skipped
end

--- Pure: the summary after a run.
function Rater.summaryText(counts, rederived, skipped, cancelled)
  local lines = { string.format('Rated: %d', counts.ok) }
  if rederived > 0 then
    lines[#lines + 1] = string.format('Re-derived for the ratio setting, without the model: %d', rederived)
  end
  if counts.errors > 0 then
    lines[#lines + 1] = string.format('Not rated (see the log): %d. Run Suggest Ratings on the same ' ..
                                      'photographs again to retry them.', counts.errors)
  end
  local parts = {}
  if skipped.alreadyRated > 0 then parts[#parts + 1] = string.format('%d already rated by this model', skipped.alreadyRated) end
  if skipped.video > 0 then parts[#parts + 1] = string.format('%d video', skipped.video) end
  if skipped.missing > 0 then
    parts[#parts + 1] = string.format('%d with the original offline and no Smart Preview', skipped.missing)
  end
  if #parts > 0 then lines[#lines + 1] = 'Skipped: ' .. table.concat(parts, ', ') .. '.' end
  if cancelled then
    lines[#lines + 1] = 'The run was cancelled; finished ratings were kept. Run it again to continue.'
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'The suggestion is in the Suggested rating field only; star ratings are untouched.'
  return table.concat(lines, '\n')
end

local function readSelection(catalog, selected)
  local raw = catalog:batchGetRawMetadata(selected, { 'fileFormat' }) or {}
  local plugin = catalog:batchGetPropertyForPlugin(selected, _PLUGIN.id,
    { F.ratingModelVersion, F.ratingBuckets, F.ratingBucket, F.ratingRatio }) or {}
  local out = {}
  for i, photo in ipairs(selected) do
    local p = plugin[photo] or {}
    out[i] = { photo = photo, isVideo = ((raw[photo] or {}).fileFormat == 'VIDEO'),
               ratingModelVersion = p[F.ratingModelVersion], ratingBuckets = p[F.ratingBuckets],
               ratingBucket = p[F.ratingBucket], ratingRatio = p[F.ratingRatio] }
  end
  return out
end

local function write(catalog, title, fn)
  -- withWriteAccessDo yields: LrTasks.pcall, never a plain pcall.
  local ok, err = LrTasks.pcall(function() catalog:withWriteAccessDo(title, fn, { timeout = 30 }) end)
  if not ok then
    Log.errorf('%s: write failed: %s', title, tostring(err))
    LrDialogs.message('Genreator: could not write to the catalog', tostring(err), 'critical')
  end
  return ok
end

--- Suggest ratings for the current selection.
function Rater.rateSelection()
  LrFunctionContext.postAsyncTaskWithContext('GenreatorRate', function(context)
    context:addFailureHandler(function(_, message)
      Log.error('suggest ratings failed: ' .. tostring(message))
      LrDialogs.message('Genreator: unexpected error', tostring(message), 'critical')
    end)

    -- 1. Config and model, and the model's rating head.
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
    local ratio, ratioNote = Model.ratingRatio(manifest, cfg.ratingRatio)
    if not ratio and type(manifest.rating) == 'table' then
      Log.warnf('ratingRatio %s not usable (%s): using the model\'s default', tostring(cfg.ratingRatio), tostring(ratioNote))
      ratio = Model.ratingRatio(manifest, Model.RATING_RECOMMENDED)
    end
    if not ratio then
      LrDialogs.message('Genreator: no suggested rating', string.format(
        'The installed model %s has no rating head, so it suggests no rating.', tostring(manifest.version)), 'info')
      return
    end

    -- 2. Selection.
    local catalog = LrApplication.activeCatalog()
    local prep = LrProgressScope { title = 'Genreator: reading the selection', functionContext = context }
    prep:setCancelable(true)
    local selected = catalog:getTargetPhotos() or {}
    if #selected == 0 then
      prep:done()
      LrDialogs.message('Genreator',
        'No photographs are selected. Select one or more photographs and try again.', 'info')
      return
    end
    local toRate, rederive, skipped = Rater.plan(readSelection(catalog, selected), manifest.version, ratio,
                                                 Classifier.isMissing)
    if prep:isCanceled() then prep:done(); return end
    if #toRate == 0 and #rederive == 0 then
      prep:done()
      LrDialogs.message('Genreator: nothing to do', Rater.summaryText({ ok = 0, errors = 0 }, 0, skipped, false), 'info')
      return
    end

    -- 3. The Personal flag is an input to the rating as to the genres (ADR-024).
    prep:setCaption('Reading keywords')
    local personalOf, personal = {}, 0
    for i, photo in ipairs(toRate) do
      if prep:isCanceled() then prep:done(); return end
      personalOf[photo] = Metadata.inputsOf(photo, cfg.personalPath).personal
      if personalOf[photo] then personal = personal + 1 end
      prep:setPortionComplete(i, #toRate)
    end
    prep:done()

    local body = {}
    if #toRate > 0 then
      body[#body + 1] = string.format('The model rates %d photograph%s: a bucket from 0 (likely 0★) to 3 ' ..
        '(a candidate for 3★ and above), in the Suggested rating field. %d %s tagged personal; the model ' ..
        'treats a photograph without the tag as not personal.', #toRate, #toRate == 1 and '' or 's', personal,
        personal == 1 and 'is' or 'are')
    end
    if #rederive > 0 then
      body[#body + 1] = string.format('%d already rated by this model get%s the bucket under the ratio setting, ' ..
        'without the model.', #rederive, #rederive == 1 and 's' or '')
    end
    body[#body + 1] = string.format('Bucket ratio %s%s. Genres, review and star ratings are untouched.', ratio,
      ratioNote and string.format(' (the setting %s is not shipped by this model)', tostring(cfg.ratingRatio))
                or (cfg.ratingRatio == Model.RATING_RECOMMENDED and ', the model\'s recommendation' or ''))
    local answer = LrDialogs.confirm(
      string.format('Suggest ratings for %d photograph%s?', #toRate + #rederive, (#toRate + #rederive) == 1 and '' or 's'),
      table.concat(body, '\n\n'), 'Suggest Ratings', 'Cancel')
    if answer ~= 'ok' then return end

    -- 4. Re-derived buckets: no model, one write.
    if #rederive > 0 and not write(catalog, 'Genreator: suggest ratings', function()
      for _, r in ipairs(rederive) do Metadata.writeRatingBucket(r.photo, r.bucket, r.ratio) end
    end) then return end

    local counts = { ok = 0, errors = 0, done = 0 }
    local fatal
    local progress
    if #toRate > 0 then
      -- 5. Temp directory, removed on every exit path.
      local runId = Classifier.newRunId()
      local tempDir = Rendition.createTempDir(runId)
      context:addCleanupHandler(function() Rendition.removeTempDir(tempDir) end)
      Rendition.cleanStaleTempDirs(tempDir)
      Log.infof('rating run %s start: photos=%d personal=%d model=%s ratingRatio=%s(%s)', runId, #toRate, personal,
                tostring(manifest.version), tostring(cfg.ratingRatio), ratio)

      progress = LrProgressScope { title = string.format('Genreator: rating %d photographs', #toRate),
                                   functionContext = context }
      progress:setCancelable(true)
      local cancelFile = tempDir .. '/cancel'

      for _, chunkPhotos in ipairs(Classifier.chunk(toRate, cfg.chunkSize)) do
        if progress:isCanceled() or fatal then break end
        progress:setCaption(string.format('Rendering %d–%d of %d', counts.done + 1, counts.done + #chunkPhotos, #toRate))
        local failed, items, results, _, fatalErr = Classifier.scoreChunk(chunkPhotos, function(photo)
          return personalOf[photo]
        end, tempDir, cfg, progress, cancelFile, counts, #toRate, 'Rating')
        fatal = fatalErr
        if fatal then Log.errorf('rating run %s stopped: %s', runId, tostring(fatal.code)) end

        counts.errors = counts.errors + #failed
        for _, f in ipairs(failed) do Log.warnf('not rated: %s: %s', tostring(f.errorCode), tostring(f.errorMessage)) end
        local pending = {}
        for _, it in ipairs(results and items or {}) do
          local r = results[it.requestId]
          local s = r.ranked and not r.ratingError and Model.ratingSuggestion(r.rating, ratio)
          if s then
            pending[#pending + 1] = { photo = it.photo, rating = s }
          elseif r.error ~= 'canceled' then
            counts.errors = counts.errors + 1
            Log.warnf('not rated: %s', tostring(r.ratingError or r.message or 'the answer has no rating'))
          end
        end
        if #pending > 0 and not write(catalog, 'Genreator: suggest ratings', function()
          for _, p in ipairs(pending) do Metadata.writeRating(p.photo, p.rating, manifest.version) end
        end) then return end
        counts.ok = counts.ok + #pending
        counts.done = counts.done + #chunkPhotos
        progress:setPortionComplete(counts.done, #toRate)
      end
      Log.infof('rating run %s done: ok=%d errors=%d', runId, counts.ok, counts.errors)
    end

    if fatal then
      LrDialogs.message('Genreator: run stopped', string.format(
        'The model failed: %s\n\nRated before stopping: %d. The remaining photographs keep the rating ' ..
        'they had. Check Model (File > Plug-in Extras) checks the installation.',
        tostring(fatal.message), counts.ok), 'critical')
      return
    end
    LrDialogs.message('Genreator', Rater.summaryText(counts, #rederive, skipped,
                                                     progress ~= nil and progress:isCanceled()), 'info')
  end)
end

return Rater
