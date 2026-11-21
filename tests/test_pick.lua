--[[
Tests for GrPick and Pick Photos to Review… (temporary): the signals, the random sample,
pick-v3's equal shares per suggested primary, and the classifier's pick mode end to end
against the stand-in model — only the picked photographs get suggestions.
]]

local t = require 'harness'
local Pick = require 'GrPick'
local Json = require 'GrJson'
local Taxonomy = require 'GrTaxonomy'

local G = Taxonomy.genres

-- A deterministic "random": always the first index, so a shuffle reverses the list.
local function first() return 1 end

local function result(spec)
  local ranked = {}
  for i, r in ipairs(spec.ranked or {}) do
    ranked[i] = { genre = G[i], applies = r[1] >= r[2], applicability = r[1], cutoff = r[2], primaryProbability = r[3] }
  end
  return { ranked = ranked, noGenreProbability = spec.noGenre }
end

t.suite('GrPick — the signals')

t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.8 }, { 0.05, 0.15, 0.1 } }, noGenre = 0.1 }), {},
     'a confident answer hits no signal')
t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.8 }, { 0.05, 0.15, 0.1 } }, noGenre = 0.45 }), { 'no-genre' },
     'a no-genre score between 0.2 and 0.8')
t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.45 }, { 0.05, 0.15, 0.35 } }, noGenre = 0.1 }), { 'close' },
     'top two primary scores within 0.15')
t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.8 }, { 0.17, 0.15, 0.1 } }, noGenre = 0.1 }), { 'cut-off' },
     'a genre within 30% of its cut-off')
t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.8 } } }), {}, 'a model without a no-genre class: no no-genre signal')
t.eq(Pick.signals(result { ranked = { { 0.9, 0.1, 0.1 }, { 0.9, 0.1, 0.8 }, { 0.9, 0.1, 0.05 } }, noGenre = 0.1 }), {},
     'the top two primary scores are taken by value, not by position')
t.eq(Pick.reason({ 'no-genre', 'close' }, 6, 500), 'pick-v3:no-genre,close:6/500',
     'the stored reason names the version, the signals and how common the primary was in the sample')
t.eq(Pick.reason({}, 212, 500), 'pick-v3:none:212/500', 'a pick with no signal says so')

t.suite('GrPick — the sample size')

t.eq(Pick.sampleSize(4), 20, 'five times n')
t.eq(Pick.sampleSize(100), 500, 'capped at 500')
t.eq(Pick.sampleSize(300), 500, 'still 500 when five times n is more')
t.eq(Pick.sampleSize(800), 800, 'never fewer than n')

t.suite('GrPick — equal shares per suggested primary (pick-v3)')

local EDGE, SURE = 0.5, 0.1
local function cand(key, group, noGenre)
  return { key = key, group = group,
           result = result { ranked = { { 0.9, 0.1, 0.8 }, { 0.05, 0.15, 0.1 } }, noGenre = noGenre } }
end
-- Twelve candidates: eight of G[1] (two on the edge), three of G[2] (one on the edge), one of G[3].
local cands = {}
for i = 1, 8 do cands[#cands + 1] = cand('a' .. i, G[1], (i == 7 or i == 8) and EDGE or SURE) end
for i = 1, 3 do cands[#cands + 1] = cand('b' .. i, G[2], i == 3 and EDGE or SURE) end
cands[#cands + 1] = cand('c1', G[3], SURE)

local function groupsOf(picked)
  local n = {}
  for _, p in ipairs(picked) do n[p.group] = (n[p.group] or 0) + 1 end
  return n
end
local picked = Pick.choose(cands, 3, first)
t.eq(groupsOf(picked), { [G[1]] = 1, [G[2]] = 1, [G[3]] = 1 }, 'one of each primary, however common')
t.eq(picked[1].group, G[3], 'the rarest primary first')
t.eq(picked[2].key, 'b3', 'within a primary, the one on the edge first')
t.contains(picked[2].reason, ':3/12', 'the reason records how common the primary was in the sample')
picked = Pick.choose(cands, 7, first)
t.eq(groupsOf(picked), { [G[1]] = 3, [G[2]] = 3, [G[3]] = 1 },
     'a primary with too few drops out; the others share the rest equally')
local edgesA = 0
for _, p in ipairs(picked) do if p.key == 'a7' or p.key == 'a8' then edgesA = edgesA + 1 end end
t.eq(edgesA, 2, 'the common primary\'s picks start with its edge cases')
t.eq(#Pick.choose(cands, 20, first), 12, 'never more than there are')
for _, p in ipairs(Pick.choose(cands, 12, first)) do
  t.ok(p.reason:match('^pick%-v3:[%a,%-]+:%d+/12$') ~= nil, 'reason ' .. p.reason .. ' has the pick-v3 form')
end
t.isNil(Pick.choose(cands, 3, first)[1].personal, 'Personal plays no part in the pick')

t.suite('Pick Photos to Review… — the classifier\'s pick mode, end to end')

local Classifier    = require 'GrClassifier'
local Metadata      = require 'GrMetadata'
local Model         = require 'GrModel'
local Photo         = require 'photo'
local LrApplication = require 'LrApplication'
local LrDialogs     = require 'LrDialogs'
local LrExportSession = require 'LrExportSession'
local LrFileUtils   = require 'LrFileUtils'
local F = Metadata.FIELDS

local TMP, PLAN = '/tmp/genreator-pick', '/tmp/genreator-fake-plan.json'
os.execute('rm -rf ' .. TMP .. ' && mkdir -p ' .. TMP)
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local cwd = io.popen('pwd'):read('*l')
Model.binary = (here:sub(1, 1) == '/' and here or (cwd .. '/' .. here)) .. '/fixtures/fake-localgenres'
local realCheck = Model.check
Model.check = function() return true end
local cfgPath = TMP .. '/config.json'
local fh = assert(io.open(cfgPath, 'w')); fh:write('{"chunkSize": 4, "logLevel": "error"}'); fh:close()
local realGetenv = os.getenv
os.getenv = function(name) if name == 'GENREATOR_CONFIG' then return cfgPath end return realGetenv(name) end

-- Eleven photographs: ten unclassified, so a sample of 5 × 2 is all ten; 3 and 7 sit on the
-- model's edges (a no-genre score of 0.5), the rest are confident. The eleventh is already
-- classified, so it is no candidate. N = 4.
LrDialogs._reset(); LrExportSession._reset(); LrFileUtils._reset()
local plan = {}
local photos, scripted = {}, {}
for i = 1, 11 do
  local spec = i == 11 and { plugin = { reviewState = 'suggested', aiGenre = G[1] } } or {}
  if i % 2 == 0 then spec.keywordPaths = { '#PERSONAL' } end
  photos[i] = Photo.new(spec)
  local path = string.format('%s/%d.jpg', TMP, i)
  local f = assert(io.open(path, 'wb')); f:write('jpeg'); f:close()
  scripted[i] = { photo = photos[i], success = true, path = path }
  if i == 3 or i == 7 then plan[i .. '.jpg:no_genre'] = 0.5 end
end
fh = assert(io.open(PLAN, 'w')); fh:write(Json.encode(plan)); fh:close()
LrApplication._setCatalog(LrApplication._fakeCatalog(photos))
LrExportSession._scriptedRenditions = scripted

Classifier.classifySelection { pick = { n = 4 } }
os.remove(PLAN)

t.contains(LrDialogs._confirms[1].title, 'Pick 4 of 10 unclassified photographs', 'confirms: n of the unclassified')
t.contains(LrDialogs._confirms[1].body, 'an equal share for each suggested primary genre', 'and how they are picked')
local suggested = 0
for i = 1, 10 do
  if photos[i]._plugin[F.reviewState] == 'suggested' then
    suggested = suggested + 1
    t.ok(photos[i]._plugin[F.pickReason]:match('^pick%-v3:[%a,%-]+:%d+/10$') ~= nil,
         'the pick reason is recorded: ' .. photos[i]._plugin[F.pickReason])
  end
end
t.eq(suggested, 4, 'only the picked photographs get suggestions')
local edges = 0
for _, i in ipairs { 3, 7 } do if photos[i]._plugin[F.reviewState] == 'suggested' then edges = edges + 1 end end
t.eq(edges, 2, 'the photographs on the edge are picked first within their primary')
t.eq(photos[11]._plugin[F.aiGenre], G[1], 'an already-classified photograph is untouched')
local pickedColl = false
for _, c in ipairs(LrApplication._catalog._collections) do
  if c.kind == 'collection' then pickedColl = true end
end
t.ok(not pickedColl, 'no collection of picks: they are in Awaiting Review')
t.ok(not LrDialogs._confirms[1].body:find('earlier picks'), 'no earlier picks waiting, so no word of them')
t.contains(LrDialogs._allText(), 'Picked 4 of 10', 'the summary says how many')
t.ok(not LrDialogs._allText():find('Picked [^\n]*personal'), 'the pick summary does not count personal photographs')

-- A second pick while the first still awaits review says so.
-- The first run deleted its renditions, as it should; make them again.
local function remakeRenditions()
  for i = 1, 10 do
    local f = assert(io.open(string.format('%s/%d.jpg', TMP, i), 'wb')); f:write('jpeg'); f:close()
  end
end
LrDialogs._reset()
remakeRenditions()
LrExportSession._scriptedRenditions = scripted
Classifier.classifySelection { pick = { n = 1 } }
t.contains(LrDialogs._confirms[1].body, '4 photographs from earlier picks are still awaiting review',
           'the confirmation counts earlier picks still awaiting review')
t.contains(LrDialogs._confirms[1].body, 'random sample of 5', 'the sample is five times n')
t.contains(LrDialogs._allText(), 'Picked 1 of 5 scored', 'only the sample is scored')

-- The sample draws from available photographs only, and checks availability only until it is
-- full: twelve unclassified, the first four offline, a sample of 5 for n = 1.
local LrProgressScope = require 'LrProgressScope'
local offline, checks = {}, 0
for i = 1, 12 do
  offline[i] = Photo.new { missing = i <= 4 }
  local real = offline[i].checkPhotoAvailability
  offline[i].checkPhotoAvailability = function(self) checks = checks + 1; return real(self) end
end
LrApplication._setCatalog(LrApplication._fakeCatalog(offline))
LrDialogs._reset(); LrDialogs._confirmAnswer = 'cancel'
Classifier.classifySelection { pick = { n = 1 } }
t.contains(LrDialogs._confirms[1].body, 'random sample of 5', 'offline photographs are left out of the sample')
t.ok(checks >= 5 and checks <= 9, 'availability is checked only until the sample is full')

-- Every candidate offline: the message says so.
LrApplication._setCatalog(LrApplication._fakeCatalog { offline[1], offline[2] })
LrDialogs._reset()
Classifier.classifySelection { pick = { n = 1 } }
t.contains(LrDialogs._allText(), 'The 2 unclassified photographs of the selection have the original offline',
           'a sample of offline photographs only is explained')

-- Cancel while the sample is drawn: no confirmation, nothing written.
LrApplication._setCatalog(LrApplication._fakeCatalog(offline))
LrDialogs._reset(); LrProgressScope._reset(); LrProgressScope._cancelAfter = 1
Classifier.classifySelection { pick = { n = 1 } }
t.eq(#LrDialogs._confirms, 0, 'cancelling the sample bar stops before the confirmation')
LrProgressScope._reset(); LrDialogs._reset()

Model.binary = nil
Model.check = realCheck
os.getenv = realGetenv
LrApplication._setCatalog(nil)
os.execute('rm -rf ' .. TMP)

return t
