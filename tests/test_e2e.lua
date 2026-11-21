--[[
End-to-end test of classification, offline.

Drives GrClassifier.classifySelection against stubbed Lightroom modules, real temp files on
disk, and tests/fixtures/fake-localgenres standing in for the model runtime (run for real
through GrCli). It asserts the whole path: config -> selection filter -> the user's keywords
-> confirmation -> renditions -> one model call per chunk -> suggestion -> batched catalog
write -> rendition and temp cleanup.

This is the offline counterpart to the in-Lightroom checklist in docs/development.md. It cannot
prove the SDK behaves as documented, but it does prove our orchestration is correct.
]]

local t = require 'harness'

local Classifier = require 'GrClassifier'
local Metadata   = require 'GrMetadata'
local Model      = require 'GrModel'
local Taxonomy   = require 'GrTaxonomy'
local Json       = require 'GrJson'

local Photo            = require 'photo'
local LrApplication    = require 'LrApplication'
local LrDialogs        = require 'LrDialogs'
local LrExportSession  = require 'LrExportSession'
local LrFileUtils      = require 'LrFileUtils'
local LrProgressScope  = require 'LrProgressScope'

local F = Metadata.FIELDS
local G = Taxonomy.genres

-- ------------------------------------------------------------------ fixtures

local TMP = '/tmp/genreator-e2e'
local PLAN = '/tmp/genreator-fake-plan.json'
local FAIL = '/tmp/genreator-fake-fail'
local REQUESTS = '/tmp/genreator-fake-requests.jsonl'
os.execute('rm -rf ' .. TMP .. ' ' .. PLAN .. ' ' .. FAIL .. ' ' .. REQUESTS .. ' && mkdir -p ' .. TMP)

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local cwd = io.popen('pwd'):read('*l')
Model.binary = (here:sub(1, 1) == '/' and here or (cwd .. '/' .. here)) .. '/fixtures/fake-localgenres'
-- The encoder is downloaded by `make install`; the stand-in does not need it.
local realCheck = Model.check
Model.check = function() return true end

local function writeFile(path, text)
  local fh = assert(io.open(path, 'w'))
  fh:write(text)
  fh:close()
end

--- Write a config file and point GrConfig at it via the documented override.
local function writeConfig(overrides)
  local cfg = { chunkSize = 2, logLevel = 'error' }
  for k, v in pairs(overrides or {}) do cfg[k] = v end
  local path = TMP .. '/config.json'
  writeFile(path, Json.encode(cfg))
  return path
end

--- Create a fake JPEG on disk and register it with the file-utils stub.
local function fakeJpeg(index)
  local path = string.format('%s/%d.jpg', TMP, index)
  writeFile(path, '\255\216\255\224' .. string.rep(string.char(64 + index), 128))
  return path
end

--- Set up a run, with renditions scripted to succeed unless the spec says otherwise.
local function scenario(photoSpecs)
  LrDialogs._reset()
  LrExportSession._reset()
  LrProgressScope._reset()
  LrFileUtils._reset()
  os.remove(REQUESTS)

  local photos, scripted = {}, {}
  for i, spec in ipairs(photoSpecs) do
    local photo = Photo.new(spec)
    photos[#photos + 1] = photo
    if spec.renderFails then
      scripted[#scripted + 1] = { photo = photo, success = false, message = 'disk full' }
    elseif not spec.raw then
      scripted[#scripted + 1] = { photo = photo, success = true, path = fakeJpeg(i) }
    end
  end
  LrApplication._setCatalog(LrApplication._fakeCatalog(photos))
  LrExportSession._scriptedRenditions = scripted
  return photos
end

--- The requests the stand-in model received, decoded.
local function requests()
  local out = {}
  local fh = io.open(REQUESTS, 'rb')
  if not fh then return out end
  for line in fh:lines() do out[#out + 1] = Json.decode(line) end
  fh:close()
  return out
end

local configPath = writeConfig()
local realGetenv = os.getenv
os.getenv = function(name)
  if name == 'GENREATOR_CONFIG' then return configPath end
  return realGetenv(name)
end

-- ------------------------------------------------------------------ the happy path

t.suite('E2E — classify a clean selection')

local photos = scenario {
  { keywords = { 'Anna', 'Iceland' }, personKeywords = { 'Anna' }, keywordPaths = { '#PERSONAL > Family' } },
  { keywords = { 'Anna' }, personKeywords = { 'Anna' }, keywordPaths = { 'Genre > ' .. G[5] } },
  { keywords = {} },
}
Classifier.classifySelection { reclassify = false }

t.eq(#LrDialogs._confirms, 1, 'the run is confirmed first')
t.contains(LrDialogs._confirms[1].body, '1 of the 3 photographs is tagged personal (#PERSONAL',
           'the confirmation counts the Personal tags (ADR-024)')
t.contains(LrDialogs._confirms[1].body, '1 already carries a genre keyword', 'and the pre-tagged photographs')
t.notContains(LrDialogs._confirms[1].body, 'pause sync', 'no sync reminder: classifying writes plugin fields only, which do not sync')

local reqs = requests()
t.eq(#reqs, 2, 'one model call per chunk (chunk size 2, three photographs)')
local sent = {}
for _, r in ipairs(reqs) do for _, it in ipairs(r.items) do sent[#sent + 1] = it end end
t.eq(#sent, 3, 'every photograph went to the model')
t.eq(sent[1].known_person, true, 'the Personal tag is the known-person input')
t.eq(sent[2].known_person, false, 'a person keyword alone is not (ADR-024)')
for _, r in ipairs(reqs) do
  local text = Json.encode(r)
  for _, word in ipairs { 'Anna', 'Iceland', 'PERSONAL', 'Family' } do
    t.notContains(text, word, 'no keyword text reaches the model: ' .. word)
  end
end

for i, photo in ipairs(photos) do
  t.eq(photo._plugin[F.reviewState], 'suggested', string.format('photo %d ends in the suggested state', i))
  t.eq(photo._plugin[F.model], 'fake-model', string.format('photo %d records the answering model', i))
  t.eq(photo._plugin[F.modelVersion], Model.manifest().version, string.format('photo %d records the model version', i))
  t.ok(photo._plugin[F.aiRanking]:match('%*') ~= nil, string.format('photo %d stores the ranking', i))
end
t.eq(photos[1]._plugin[F.aiGenre], G[2], 'photo 1: the model answered for a personal photograph')
t.eq(photos[3]._plugin[F.aiGenre], G[1], 'photo 3: the model\'s primary')
t.eq(photos[2]._plugin[F.aiGenres], G[1] .. ', ' .. G[5], 'photo 2: the pre-tag joins the suggestion (ADR-023)')
t.eq(photos[2]._plugin[F.userGenres], G[5], 'and is recorded as the user\'s')
t.eq(photos[1]._plugin[F.runId], photos[3]._plugin[F.runId], 'every photograph in the run shares one run id')

for i, photo in ipairs(photos) do
  t.eq(#photo._addedKeywords + #photo._removedKeywords, 0,
       string.format('photo %d: no keyword written or removed (ADR-002)', i))
  t.ok(photo._plugin[F.humanGenre] == nil, string.format('photo %d has no decision yet', i))
end

t.suite('E2E — renditions: GPS stripped, deleted after the model call (R8.2, R8.3)')

local used = LrExportSession._lastParams
t.eq(used.exportSettings.LR_removeLocationMetadata, true, 'the run stripped GPS from renditions')
t.eq(used.exportSettings.LR_reimportExportedPhoto, false, 'renditions never enter the catalog')
t.eq(used.exportSettings.LR_size_maxWidth, 1024, 'the configured size')
local deleted = {}
for _, p in ipairs(LrFileUtils._deleted) do deleted[p] = true end
for i = 1, 3 do
  t.ok(deleted[string.format('%s/%d.jpg', TMP, i)], string.format('rendition %d was deleted', i))
end

t.suite('E2E — batched catalog writes')

local catalog = LrApplication.activeCatalog()
t.eq(#catalog._writeTitles, 2, 'write access once per chunk, not once per photograph')
t.contains(catalog._writeTitles[1], 'Genreator', 'the write is attributed to the plugin')
local summary = LrDialogs._allText()
t.contains(summary, 'Classified: 3', 'the summary reports three classified')
t.contains(summary, 'No keywords were written', 'and that nothing was decided yet')

-- ------------------------------------------------------------------ No genre and pre-tags

t.suite('E2E — No genre, and a pre-tag when nothing reaches its cut-off (ADR-022, ADR-023)')

do
  local nothing = {}
  for i, g in ipairs(G) do nothing[i] = Json.array { g, false } end
  writeFile(PLAN, Json.encode { ['1.jpg'] = Json.array(nothing), ['2.jpg'] = Json.array(nothing),
                                ['3.jpg:no_genre'] = true })
  local ng = scenario { { keywords = {} }, { keywordPaths = { 'Genre > ' .. G[6], 'Genre > ' .. G[3] } },
                        { keywords = {} } }
  Classifier.classifySelection {}
  os.remove(PLAN)
  t.eq(ng[1]._plugin[F.aiGenre], Taxonomy.NO_GENRE, 'nothing reaches its cut-off and nothing tagged: No genre')
  t.eq(ng[1]._plugin[F.aiGenres], '', 'with no genres')
  t.eq(ng[2]._plugin[F.aiGenre], G[3], 'the pre-tag the model ranks highest becomes the primary')
  t.eq(ng[2]._plugin[F.aiGenres], G[3] .. ', ' .. G[6], 'both pre-tags, in ranking order')
  t.eq(ng[3]._plugin[F.aiGenre], Taxonomy.NO_GENRE, 'the model\'s no-genre class says No genre though a genre applies')
  t.ok(ng[3]._plugin[F.aiRanking]:match('^%-%*') ~= nil, 'and the ranking records it')
end

t.suite('E2E — the personal floor, and re-deriving it from the ranking (ADR-028)')

do
  local floor = Model.personalFloor(Model.manifest())
  t.ok(floor ~= nil, 'the bundled model brings a personal floor')
  floor = floor or 0.5
  -- A genre over its cut-off but under the floor; the rest well over both, or under both.
  local function plan(first, under)
    local list = {}
    for i, g in ipairs(G) do
      if g == under then list[i] = Json.array { g, floor - 0.05, floor - 0.1 }
      else list[i] = Json.array { g, g == first } end
    end
    return Json.array(list)
  end
  -- Only the first genre over its cut-off, and that under the floor.
  local function allUnder() return plan(nil, G[1]) end
  writeFile(PLAN, Json.encode { ['1.jpg'] = plan(G[1], G[2]), ['2.jpg'] = plan(G[1], G[2]),
                                ['3.jpg'] = allUnder(), ['4.jpg'] = allUnder() })
  local P = { '#PERSONAL > Family' }
  local fl = scenario { { keywordPaths = P }, { keywords = {} },
                        { keywordPaths = { P[1], 'Genre > ' .. G[3] } }, { keywordPaths = P } }
  Classifier.classifySelection {}
  os.remove(PLAN)
  t.contains(LrDialogs._confirms[1].body, 'at least ' .. tostring(floor), 'the confirmation names the floor')
  t.eq(fl[1]._plugin[F.aiGenres], G[1], 'personal: a genre under the floor is not suggested')
  t.eq(fl[2]._plugin[F.aiGenres], G[1] .. ', ' .. G[2], 'not personal: the model\'s cut-offs alone')
  t.eq({ fl[1]._plugin[F.personal], fl[2]._plugin[F.personal] }, { 'yes', 'no' }, 'the Personal flag is recorded')
  t.contains(fl[1]._plugin[F.aiRanking], Taxonomy.short(G[1]) .. '*+ ' .. Taxonomy.short(G[2]) .. '* ',
             'the ranking marks the genres over the floor')
  t.ok(fl[1]._plugin[F.aiRanking]:match(' floor=' .. tostring(floor):gsub('%.', '%%.') .. '$') ~= nil,
       '... and ends with the floor it was marked for')
  t.eq({ fl[3]._plugin[F.aiGenre], fl[3]._plugin[F.aiGenres] }, { G[3], G[3] }, 'a pre-tag stands under the floor')
  t.eq(fl[4]._plugin[F.aiGenre], Taxonomy.NO_GENRE, 'nothing left over the floor: No genre')

  -- The setting changed to the model's cut-offs alone: re-derived from the stored ranking.
  local PLUGIN = here .. '/../Genreator.lrplugin/'
  writeConfig { personalFloor = 'off' }
  os.remove(REQUESTS)
  LrDialogs._reset()
  dofile(PLUGIN .. 'GrMenuRederive.lua')
  t.eq(#requests(), 0, 're-deriving does not run the model')
  t.eq(fl[1]._plugin[F.aiGenres], G[1] .. ', ' .. G[2], 'cut-offs only: the genre under the floor is back')
  t.eq(fl[1]._plugin[F.reviewGenres], G[1] .. ', ' .. G[2], '... in the list under review')
  t.eq(fl[4]._plugin[F.aiGenre], G[1], '... and No genre becomes the model\'s first genre')
  t.eq(fl[3]._plugin[F.aiGenres], G[1] .. ', ' .. G[3], '... with the pre-tag kept')
  t.eq(fl[2]._plugin[F.aiGenres], G[1] .. ', ' .. G[2], 'a photograph that is not personal is unchanged')
  local text = LrDialogs._allText()
  t.contains(text, 'Re-derived: 3', 'the summary counts the personal photographs')
  t.contains(text, 'not personal', '... and says why the other was skipped')
  for i, photo in ipairs(fl) do
    t.eq(#photo._addedKeywords + #photo._removedKeywords, 0, string.format('photo %d: no keyword written', i))
  end

  writeConfig {}
  dofile(PLUGIN .. 'GrMenuRederive.lua')
  t.eq(fl[1]._plugin[F.aiGenres], G[1], 'back to the recommended floor')

  -- Review is unchanged; the decision keeps the Personal flag of what it answered.
  dofile(PLUGIN .. 'GrMenuAccept.lua')
  t.eq({ fl[1]._plugin[F.reviewState], fl[1]._plugin[F.decisionPersonal] }, { 'accepted', 'yes' },
       'a decision on a personal photograph is marked personal')
  t.eq(fl[2]._plugin[F.decisionPersonal], 'no', '... and one on another photograph is not')
  LrDialogs._reset()
  dofile(PLUGIN .. 'GrMenuRederive.lua')
  t.eq(fl[1]._plugin[F.humanGenres], G[1], 'a decision stands when re-deriving')
  t.contains(LrDialogs._allText(), 'a decision stands', '... and the summary says so')
end

t.suite('E2E — Suggest Ratings is its own action (ADR-029)')

do
  local Rater = require 'GrRater'
  local manifest = Model.manifest()
  t.ok(type(manifest.rating) == 'table', 'the bundled model has a rating head')
  -- The fake runtime answers bucket n % 4 under 1.5 and (n + 1) % 4 under 2.0 (photo n);
  -- the expectations follow the bundled model's default ratio.
  local def = manifest.rating.default_ratio
  local other = def == '1.5' and '2.0' or '1.5'
  local function fb(n, ratio) return tostring(ratio == '1.5' and n % 4 or (n + 1) % 4) end
  local rp = scenario { { keywordPaths = { '#PERSONAL > Family' } }, { keywords = {} },
                        { plugin = { reviewState = 'accepted', aiGenre = G[2], humanGenre = G[2], humanGenres = G[2] } },
                        { raw = { fileFormat = 'VIDEO' } } }
  Classifier.classifySelection {}
  for i = 1, 2 do
    t.ok((rp[i]._plugin[F.ratingBucket] or '') == '', string.format('photo %d: Classify writes no rating', i))
  end

  os.remove(REQUESTS)
  LrDialogs._reset()
  local before = {}
  for i, p in ipairs(rp) do
    before[i] = {}
    for k, v in pairs(p._plugin) do before[i][k] = v end
  end
  for i = 1, 3 do fakeJpeg(i) end -- Classify deleted its renditions
  Rater.rateSelection()
  t.contains(LrDialogs._confirms[1].title, 'Suggest ratings for 3 photographs', 'the run is confirmed first')
  t.contains(LrDialogs._confirms[1].body, 'Bucket ratio ' .. def, '... naming the bucket ratio')
  local sent = {}
  for _, r in ipairs(requests()) do for _, it in ipairs(r.items) do sent[#sent + 1] = it end end
  t.eq(#sent, 3, 'the model rates every photograph but the video, whatever its review state')
  t.eq(sent[1].known_person, true, 'the Personal flag reaches the model')
  t.eq({ rp[1]._plugin[F.ratingBucket], rp[2]._plugin[F.ratingBucket], rp[3]._plugin[F.ratingBucket] },
       { fb(1, def), fb(2, def), fb(3, def) }, 'the bucket under the default ratio is written')
  t.eq(rp[1]._plugin[F.ratingBuckets], '1.5=1 2.0=2', 'every shipped bucket is stored')
  t.eq(rp[1]._plugin[F.ratingScore], '0.100', 'and the score')
  t.eq({ rp[1]._plugin[F.ratingRatio], rp[1]._plugin[F.ratingModelVersion] }, { def, manifest.version },
       'and the ratio and the model version that rated')
  for i = 1, 3 do
    for k, v in pairs(before[i]) do
      if not k:match('^rating') then
        t.eq(rp[i]._plugin[k], v, string.format('photo %d: Suggest Ratings leaves %s alone', i, k))
      end
    end
    t.eq(#rp[i]._addedKeywords + #rp[i]._removedKeywords, 0, string.format('photo %d: no keyword written', i))
  end
  t.isNil(rp[4]._plugin[F.ratingBucket], 'the video is skipped')
  t.contains(LrDialogs._allText(), 'Rated: 3', 'the summary counts the rated photographs')

  -- Again with the same model: nothing is rendered; a changed ratio is re-derived.
  os.remove(REQUESTS)
  LrDialogs._reset()
  Rater.rateSelection()
  t.eq(#requests(), 0, 'photographs this model rated are not rated again')
  t.contains(LrDialogs._allText(), '3 already rated by this model', '... and the message says so')
  writeConfig { ratingRatio = other }
  LrDialogs._reset()
  Rater.rateSelection()
  t.eq(#requests(), 0, 'a changed ratio needs no model')
  t.eq({ rp[1]._plugin[F.ratingBucket], rp[1]._plugin[F.ratingRatio] }, { fb(1, other), other },
       'the bucket is re-derived under the new ratio from the stored buckets')
  t.contains(LrDialogs._allText(), 'Re-derived for the ratio setting, without the model: 3', 'the summary says so')
  writeConfig {}

  -- A bad rating answer fails that photograph's rating only.
  writeFile(PLAN, Json.encode { ['1.jpg:rating'] = { score = 1, bucket = { ['1.5'] = 7 }, default_ratio = '1.5' } })
  local bad = scenario { { keywords = {} }, { keywords = {} } }
  Rater.rateSelection()
  os.remove(PLAN)
  t.ok((bad[1]._plugin[F.ratingBucket] or '') == '', 'a malformed rating is not written')
  t.eq(bad[2]._plugin[F.ratingBucket], fb(2, def), 'the rest of the chunk is')
  t.isNil(bad[1]._plugin[F.reviewState], 'and the review state is not touched')
  t.contains(LrDialogs._allText(), 'Not rated (see the log): 1', 'the summary counts it')

  -- A model without a rating head suggests none.
  local realManifest = Model.manifest
  Model.manifest = function() local m = realManifest(); m.rating = nil; return m end
  scenario { { keywords = {} } }
  Rater.rateSelection()
  Model.manifest = realManifest
  t.contains(LrDialogs._allText(), 'has no rating head', 'a model without a rating head is reported')
  t.isNil(LrExportSession._lastParams, 'and nothing is rendered')
end

t.suite('E2E — declining the confirmation changes nothing')

do
  local declined = scenario { { keywords = {} } }
  LrDialogs._confirmAnswer = 'cancel'
  Classifier.classifySelection {}
  t.ok(declined[1]._plugin[F.reviewState] == nil, 'not classified')
  t.isNil(LrExportSession._lastParams, 'nothing was rendered')
end

-- ------------------------------------------------------------------ skips

t.suite('E2E — ineligible photographs are skipped, not failed')

scenario { { raw = { fileFormat = 'VIDEO' } }, { missing = true } }
Classifier.classifySelection { reclassify = false }
local skipText = LrDialogs._allText()
t.contains(skipText, 'nothing to do', 'a fully ineligible selection reports nothing to do')
t.contains(skipText, 'video', 'the message names the skipped video')
t.contains(skipText, 'original offline and no Smart Preview', 'the message names the offline original')
t.contains(skipText, 'Build Smart Previews', 'and says how to make it classifiable')
t.notContains(skipText, 'Reclassify', 'no irrelevant reclassify advice')

t.suite('E2E — an offline original with a Smart Preview is classified')

local offline = scenario { { missing = true, smartPreview = true }, { missing = true } }
Classifier.classifySelection {}
t.eq(offline[1]._plugin[F.reviewState], 'suggested', 'rendered from the Smart Preview and classified')
t.ok(offline[2]._plugin[F.reviewState] == nil, 'no Smart Preview: still skipped, not an error')

t.suite('E2E — if Lightroom rejects smartPreviewInfo, offline photos are attempted, not skipped')

local realGetRaw = Photo.getRawMetadata
Photo.getRawMetadata = function(self, key)
  if key == 'smartPreviewInfo' then error('Unknown key: "smartPreviewInfo"', 2) end
  return realGetRaw(self, key)
end
offline = scenario { { missing = true } }
Classifier.classifySelection {}
t.eq(offline[1]._plugin[F.reviewState], 'suggested', 'the export is attempted (a failure would be a visible error)')
Photo.getRawMetadata = realGetRaw
Classifier.smartPreviewKeyBroken = false

t.suite('E2E — already-classified photographs are skipped (R6.5)')

local done = scenario { { plugin = { reviewState = 'accepted', aiGenre = 'Street' } } }
Classifier.classifySelection { reclassify = false }
t.eq(done[1]._plugin[F.aiGenre], 'Street', 'an accepted photograph is left untouched')
t.contains(LrDialogs._allText(), 'already classified', 'the message explains why it was skipped')

t.suite('E2E — Reclassify keeps a decision and its keywords (R2.7)')

do
  local decided = scenario { { keywordPaths = { 'Genre > ' .. G[4] },
                               plugin = { reviewState = 'accepted', humanGenre = G[4], humanGenres = G[4],
                                          primaryGenre = G[4], aiGenre = G[4] } } }
  Classifier.classifySelection { reclassify = true }
  t.eq(decided[1]._plugin[F.reviewState], 'accepted', 'the decision stands')
  t.eq(decided[1]._plugin[F.primaryGenre], G[4], 'the decided primary stands')
  t.eq(decided[1]._plugin[F.aiGenre], G[1], 'the new suggestion is the model\'s own: the decision is not fed back as a pre-tag')
  t.eq(decided[1]._plugin[F.userGenres], '', 'and the decided genre is not recorded as the user\'s')
  t.eq(#decided[1]._removedKeywords, 0, 'no keyword removed')
end

-- ------------------------------------------------------------------ failures

t.suite('E2E — a rendition failure is recorded, and the run continues')

local mixed = scenario { { keywords = {} }, { renderFails = true }, { keywords = {} } }
Classifier.classifySelection { reclassify = false }
t.eq(mixed[1]._plugin[F.reviewState], 'suggested', 'the first photograph still succeeded')
t.eq(mixed[2]._plugin[F.reviewState], 'error', 'the failing photograph is marked error')
t.contains(mixed[2]._plugin[F.errorText], 'render_failed', 'the error records the failure code')
t.eq(mixed[3]._plugin[F.reviewState], 'suggested', 'the run did not abort')
local mixedSummary = LrDialogs._allText()
t.contains(mixedSummary, 'Classified: 2', 'the summary counts the two successes')
t.contains(mixedSummary, 'Errors: 1', 'the summary counts the one failure')

t.suite('E2E — a model that fails stops the run without blaming the photographs')

do
  writeFile(FAIL, 'x')
  local stopped = scenario { { keywords = {} }, { keywords = {} }, { keywords = {} } }
  Classifier.classifySelection {}
  os.remove(FAIL)
  for i, photo in ipairs(stopped) do
    t.ok(photo._plugin[F.reviewState] == nil, string.format('photo %d left unclassified, not error', i))
  end
  local stopText = LrDialogs._allText()
  t.contains(stopText, 'run stopped', 'the user is told the run stopped')
  t.contains(stopText, 'model exploded', 'and why')
  t.eq(#requests(), 1, 'the next chunk was never sent')
  local gone = {}
  for _, p in ipairs(LrFileUtils._deleted) do gone[p] = true end
  t.ok(gone[TMP .. '/1.jpg'] and gone[TMP .. '/2.jpg'], 'the failed chunk\'s renditions were still deleted')
end

t.suite('E2E — a missing model is reported before any work')

do
  Model.check = function() return nil, 'the image encoder is not installed' end
  scenario { { keywords = {} } }
  Classifier.classifySelection {}
  Model.check = function() return true end
  t.contains(LrDialogs._allText(), 'the model is not installed', 'the user is told')
  t.isNil(LrExportSession._lastParams, 'nothing was rendered')
end

t.suite('E2E — an empty selection is handled')

scenario {}
Classifier.classifySelection {}
t.contains(LrDialogs._allText(), 'No photographs are selected', 'an empty selection gives a clear message')

t.suite('E2E — a bad config aborts before any work')

local badPath = TMP .. '/bad-config.json'
writeFile(badPath, '{ this is not json ')
os.getenv = function(name)
  if name == 'GENREATOR_CONFIG' then return badPath end
  return realGetenv(name)
end
scenario { { keywords = {} } }
Classifier.classifySelection {}
local cfgText = LrDialogs._allText()
t.contains(cfgText, 'configuration problem', 'a malformed config is reported')
t.contains(cfgText, 'not valid JSON', 'the message explains what is wrong')
t.isNil(LrExportSession._lastParams, 'no export session was created — the run aborted before any work')

t.suite('E2E — an unexpected error is shown, not swallowed')

os.getenv = function(name)
  if name == 'GENREATOR_CONFIG' then return configPath end
  return realGetenv(name)
end
scenario { { keywords = {} } }
local realActiveCatalog = LrApplication.activeCatalog
LrApplication.activeCatalog = function() error('catalog exploded') end
local okRun = pcall(Classifier.classifySelection, {})
LrApplication.activeCatalog = realActiveCatalog
t.ok(okRun, 'the failure handler consumes the error')
local failText = LrDialogs._allText()
t.contains(failText, 'unexpected error', 'the user sees an error dialog')
t.contains(failText, 'catalog exploded', 'the dialog carries the underlying message')

t.suite('E2E — a photograph left in error is retried by Classify')

local retry = scenario { { plugin = { reviewState = 'error', errorText = 'timeout: no answer' } },
                         { plugin = { reviewState = 'suggested', aiGenre = 'Street', runId = 'r-old' } },
                         { keywords = {} } }
Classifier.classifySelection { reclassify = false }
t.eq(retry[1]._plugin[F.reviewState], 'suggested', 'the earlier error was classified this time')
t.eq(retry[2]._plugin[F.runId], 'r-old', 'an already-classified photograph is still skipped')
t.contains(LrDialogs._allText(), 'Retried after an earlier error: 1', 'the summary says so')

-- ------------------------------------------------------------------ keywords (ADR-030)

t.suite('E2E — Suggest Keywords writes keywords at the taxonomy paths, with a review state')

do
  local KW = require 'GrKeywording'
  local KT = require 'GrKeywordTaxonomy'
  local Collections = require 'GrCollections'
  assert(KT.load(Model.dir()))
  local K = KT.keywords
  local N = #K
  -- The fake answers image n with keyword (n mod N)+1 (agreed) and (n+1 mod N)+1 (not agreed).
  local function first(n) return K[(n % N) + 1].id end
  local function second(n) return K[((n + 1) % N) + 1].id end
  local function pathOf(id) return table.concat(KT.path(id), ' > ') end
  local function full(kw)
    local parts = {}
    while kw do table.insert(parts, 1, kw._name); kw = kw._parent end
    return table.concat(parts, ' > ')
  end
  local function paths(photo)
    local out = {}
    for _, kw in ipairs(photo._keywords) do out[#out + 1] = full(kw) end
    table.sort(out)
    return out
  end
  local function sorted(list) table.sort(list); return list end
  local function has(photo, id)
    for _, p in ipairs(paths(photo)) do if p == pathOf(id) then return true end end
    return false
  end
  local hand = K[20].id -- a taxonomy keyword the user adds by hand
  local rp = scenario {
    { keywords = { 'Holiday' }, raw = nil },
    { keywordPaths = { pathOf(hand) }, plugin = { reviewState = 'accepted', aiGenre = G[1] } },
    { keywords = {}, plugin = { keywordState = 'verified' } },
    { raw = { fileFormat = 'VIDEO' } },
  }
  local genreBefore = {}
  for k, v in pairs(rp[2]._plugin) do genreBefore[k] = v end

  KW.suggestSelection(KW.MODE.suggest)
  t.contains(LrDialogs._confirms[1].title, 'Suggest Keywords for 2 photographs', 'the run is confirmed first')
  local sent = 0
  for _, r in ipairs(requests()) do sent = sent + #r.items end
  t.eq(sent, 2, 'the model sees neither the verified photograph nor the video')
  t.eq(paths(rp[1]), sorted { 'Holiday', pathOf(first(1)), pathOf(second(1)) },
       'the suggested keywords are added at their taxonomy paths; the user\'s own stay')
  t.eq(rp[1]._plugin[F.keywordState], 'suggested', 'the photograph awaits verification')
  local sug = KW.parseSuggestion(rp[1]._plugin[F.keywordSuggestion])
  t.eq({ sug.ids, sug.agreed, sug.modelVersion, sug.taxonomyVersion, sug.rule },
       { { first(1), second(1) }, { first(1) }, Model.manifest().keywords.version, KT.version, 'balanced' },
       'the suggestion records the keywords, the agreed ones, the model, the taxonomy and the rule')
  t.ok(has(rp[2], hand), 'a taxonomy keyword the user put there is kept')
  for k, v in pairs(genreBefore) do
    if not k:match('^keyword') then t.eq(rp[2]._plugin[k], v, 'Suggest Keywords leaves ' .. k .. ' alone') end
  end
  t.isNil(rp[3]._plugin[F.keywordSuggestion], 'a verified photograph is not changed')
  local cat = LrApplication.activeCatalog()
  local root = cat._roots[1]
  t.eq(root and root._parent, nil, 'the categories are root keywords')
  local exported = false
  local function walk(kw) if kw._includeOnExport ~= false then exported = true end
    for _, c in ipairs(kw._children) do walk(c) end end
  for _, r in ipairs(cat._roots) do walk(r) end
  t.ok(not exported, 'every keyword created is left out of exports')
  local grids = {}
  for _, c in ipairs(cat._collections) do
    if c.kind == 'smart' and c.parent and c.parent.name == Collections.KEYWORD_SET then grids[#grids + 1] = c.name end
  end
  t.eq(sorted(grids), { Collections.KEYWORDS_TO_VERIFY, Collections.KEYWORD_ERRORS },
       'the keyword grids exist, in the Genreator set')
  t.contains(LrDialogs._allText(), 'Keyworded: 2 photographs, 4 keywords added', 'the summary counts the keywords')
  t.contains(LrDialogs._allText(), '1 with verified or judged keywords', '... and the skipped photographs')

  -- The model changes its mind; the user added a taxonomy keyword in review.
  for i = 1, 2 do fakeJpeg(i) end
  local extra = K[30].id
  cat:withWriteAccessDo('user', function()
    local refs = KW.ensure(cat, { extra }, {})
    rp[1]._addedKeywords = {}
    rp[1]._removedKeywords = {}
    rp[1].__pendingExtra = refs[extra]
  end)
  cat:withWriteAccessDo('user', function() rp[1]:addKeyword(rp[1].__pendingExtra) end)
  writeFile(PLAN, Json.encode { ['1.jpg:keywords'] = { { K[40].name, 3, 3, 3 } } })
  LrDialogs._reset()
  KW.suggestSelection(KW.MODE.suggest)
  os.remove(PLAN)
  t.eq(paths(rp[1]), sorted { 'Holiday', pathOf(extra), pathOf(K[40].id) },
       'awaiting verification: the earlier suggestions go, the new one comes, the user\'s keywords stay')

  -- Mark Keywords Verified records the keywords present.
  LrDialogs._reset()
  KW.markVerified()
  t.eq(rp[1]._plugin[F.keywordState], 'verified', 'Mark Keywords Verified verifies an awaiting photograph')
  local decided = KW.parseDecided(rp[1]._plugin[F.keywordDecided])
  t.eq({ decided.source, decided.ids }, { 'verified', KT.sorted { extra, K[40].id } },
       '... recording the taxonomy keywords present as the decision')
  t.contains(LrDialogs._allText(), 'Verified: 2', '... and counts them')
  t.contains(LrDialogs._allText(), 'not awaiting verification): 2', '... leaving the others alone')

  -- Suggest Keywords leaves it now; Re-suggest adds without removing.
  os.remove(REQUESTS)
  LrDialogs._reset()
  for i = 1, 3 do fakeJpeg(i) end
  KW.suggestSelection(KW.MODE.suggest)
  t.eq(#requests(), 0, 'a verified selection is not rendered')
  t.contains(LrDialogs._allText(), 'nothing to do', '... and the message says so')
  LrDialogs._reset()
  KW.suggestSelection(KW.MODE.resuggest)
  t.eq(paths(rp[1]), sorted { 'Holiday', pathOf(extra), pathOf(K[40].id), pathOf(first(1)), pathOf(second(1)) },
       'Re-suggest adds the current suggestions and removes nothing')
  t.eq(rp[1]._plugin[F.keywordState], 'suggested', '... and returns the photograph to Keywords to Verify')
  t.eq(rp[3]._plugin[F.keywordState], 'suggested', '... the other verified one too')
  t.isNil(rp[4]._plugin[F.keywordState], 'the video is left as it was')

  -- A bad answer: the photograph's keywords stay, and it is marked when it had no state.
  local bad = scenario { { keywords = {} }, { keywords = {}, plugin = { keywordState = 'suggested',
                                                                       keywordSuggestion = 'v1|m|t|balanced|T|||' } } }
  writeFile(PLAN, Json.encode { ['1.jpg:keywords'] = 'nonsense', ['2.jpg:keywords'] = 'nonsense' })
  KW.suggestSelection(KW.MODE.suggest)
  os.remove(PLAN)
  t.eq({ bad[1]._plugin[F.keywordState], #bad[1]._keywords }, { 'error', 0 },
       'a malformed answer marks a new photograph as an error and writes no keyword')
  t.eq(bad[2]._plugin[F.keywordState], 'suggested', 'one awaiting verification keeps its state')
  t.ok((bad[2]._plugin[F.keywordError] or '') ~= '', '... with the error recorded')
  t.contains(LrDialogs._allText(), 'Not keyworded', 'the summary counts the errors')

  -- A model without a keyword head.
  local realManifest = Model.manifest
  Model.manifest = function() local m = realManifest(); m.keywords = nil; return m end
  scenario { { keywords = {} } }
  KW.suggestSelection(KW.MODE.suggest)
  Model.manifest = realManifest
  t.contains(LrDialogs._allText(), 'no keyword head', 'a model without a keyword head says so')
  t.eq(#requests(), 0, '... and renders nothing')
end

t.suite('E2E — Apply Keyword Judgements… sets exactly the judged keywords')

do
  local KW = require 'GrKeywording'
  local KT = require 'GrKeywordTaxonomy'
  local K = KT.keywords
  local function pathOf(id) return table.concat(KT.path(id), ' > ') end
  local jp = scenario {
    { keywords = { 'Holiday' }, keywordPaths = { pathOf(K[5].id) }, raw = { uuid = 'U1' }, formatted = { fileName = 'DSC_1.NEF' } },
    { keywords = {}, raw = { uuid = 'U2' }, formatted = { fileName = 'OTHER.NEF' } },
  }
  local function judgements(items)
    local path = TMP .. '/judgements.json'
    writeFile(path, Json.encode { schema_version = 1, taxonomy_version = KT.version, count = #items, items = items })
    LrDialogs._reset()
    LrDialogs._openPanel = { path }
    KW.applyJudgements()
  end
  local function taxonomyIds(photo)
    local Keywords = require 'GrKeywords'
    local cat = LrApplication.activeCatalog()
    local ids
    cat:withWriteAccessDo('read', function() ids = KW.presentIds(Keywords.currentOf(photo)) end)
    return ids
  end
  judgements { { photo_uuid = 'U1', file_base = 'DSC_1', keywords = { K[6].name } },
               { photo_uuid = 'U2', file_base = 'DSC_2', keywords = {} } }
  t.eq(taxonomyIds(jp[1]), { K[6].id }, 'a matched photograph gets exactly the judged keywords')
  local others = 0
  for _, kw in ipairs(jp[1]._keywords) do if kw._name == 'Holiday' then others = others + 1 end end
  t.eq(others, 1, '... keywords outside the taxonomy untouched')
  t.eq(jp[1]._plugin[F.keywordState], 'golden', '... and it is judged')
  t.isNil(jp[2]._plugin[F.keywordState], 'a file name that does not match is skipped')
  t.contains(LrDialogs._allText(), 'Skipped 1: file name does not match', '... and reported')

  judgements { { photo_uuid = 'U1', file_base = 'DSC_1', keywords = { K[6].name } },
               { photo_uuid = 'U2', file_base = 'DSC_2', keywords = {} } }
  t.contains(LrDialogs._allText(), 'Nothing to apply', 'the same file again changes nothing')

  -- The user adds a keyword; a newer file must not overwrite it.
  local cat = LrApplication.activeCatalog()
  local refs
  cat:withWriteAccessDo('user', function() refs = KW.ensure(cat, { K[7].id }, {}) end)
  cat:withWriteAccessDo('user', function() jp[1]:addKeyword(refs[K[7].id]) end)
  judgements { { photo_uuid = 'U1', file_base = 'DSC_1', keywords = { K[8].name } } }
  t.eq(taxonomyIds(jp[1]), KT.sorted { K[6].id, K[7].id }, 'a newer file keeps the user\'s later change')
  t.contains(LrDialogs._allText(), 'conflicts, not applied): 1', '... and reports the conflict')
  LrDialogs._openPanel = nil

  -- Suggest Keywords never changes a judged photograph.
  for i = 1, 2 do fakeJpeg(i) end
  KW.suggestSelection(KW.MODE.suggest)
  t.eq(taxonomyIds(jp[1]), KT.sorted { K[6].id, K[7].id }, 'Suggest Keywords leaves a judged photograph alone')
end

-- Restore
Model.binary = nil
Model.check = realCheck
os.getenv = realGetenv
os.execute('rm -rf ' .. TMP .. ' ' .. REQUESTS)

return t
