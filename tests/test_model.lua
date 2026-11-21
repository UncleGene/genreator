--[[
Tests for GrModel: the request it writes, how it reads the model's answer, the stored
ranking, and the suggestion rule (ADR-023). The process call runs for real through GrCli
against tests/fixtures/fake-localgenres, a stand-in that answers in the runtime's format.
]]

local t = require 'harness'
local Json = require 'GrJson'
local Model = require 'GrModel'
local Taxonomy = require 'GrTaxonomy'

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local G = Taxonomy.genres
local NO = Taxonomy.NO_GENRE

local function ranked(spec)   -- { {genre, applies}, … } from { 'Gen*', 'Gen', … } short forms
  local out = {}
  for _, s in ipairs(spec) do out[#out + 1] = { genre = s[1], applies = s[2] } end
  return out
end

t.suite('GrModel — the request')

local req = Model.buildRequest({
  { requestId = 'p1', photoId = 42, imagePath = '/tmp/x/a.jpg', personal = true },
  { requestId = 'p2', photoId = 43, imagePath = '/tmp/x/b.jpg' },
}, '/tmp/x/cancel')
t.eq(req.schema_version, 1, 'request schema 1')
t.eq(req.task, 'genres', 'task genres')
t.eq(req.cancel_file, '/tmp/x/cancel', 'the cancel file is named')
t.eq(req.items[1].photo_id, '42', 'photo ids are strings')
t.eq(req.items[1].known_person, true, 'the Personal tag is the known-person input (ADR-024)')
t.eq(req.items[2].known_person, false, 'untagged is not personal')
t.eq(req.items[1].orientation, 'AB', 'renditions are upright')
local text = Json.encode(req)
t.notContains(text, 'keyword', 'no keyword text in the request')

t.suite('GrModel — reading the answer: never a guess')

local function response(items, version)
  return Json.encode { schema_version = 1, task = 'genres', model_id = 'm1',
                       taxonomy_version = version or Taxonomy.version, items = Json.array(items) }
end
local function rankedItem(id, photo, genres)
  local list = {}
  for i, g in ipairs(genres) do
    list[i] = { genre = g[1], primary_probability = 0.5, applicability = g[2] and 0.9 or 0.1, cutoff = 0.5 }
  end
  return { request_id = id, photo_id = photo, ranked = { genres = Json.array(list) } }
end
local function all(first)
  local list = { { first, true } }
  for _, g in ipairs(G) do if g ~= first then list[#list + 1] = { g, false } end end
  return list
end
local items = { { requestId = 'p1', photoId = 1 }, { requestId = 'p2', photoId = 2 },
                { requestId = 'p3', photoId = 3 }, { requestId = 'p4', photoId = 4 } }
local bad = all(G[1]); bad[2] = { 'Wedding', true }
local short = all(G[1]); table.remove(short)
local results, modelId = Model.parseResponse(response {
  rankedItem('p1', '1', all(G[2])),
  rankedItem('p2', '2', bad),
  { request_id = 'p3', photo_id = '3', error = 'Missing or unreadable image preview' },
  rankedItem('p4', '4', short),
}, items)
t.eq(modelId, 'm1', 'the answering model id is returned')
t.eq({ results.p1.ranked[1].genre, results.p1.ranked[1].applies }, { G[2], true }, 'a good answer is read in the model\'s order')
t.eq({ results.p1.ranked[1].applicability, results.p1.ranked[1].cutoff, results.p1.ranked[1].primaryProbability },
     { 0.9, 0.5, 0.5 }, 'with the model\'s numbers, for picking (never stored)')
t.eq(#results.p1.ranked, #G, 'every genre is ranked')
t.eq(results.p2.error, 'unknown_genre', 'a genre outside the taxonomy is an error, never mapped')
t.eq(results.p3.error, 'model_error', 'a per-photograph error is kept')
t.contains(results.p3.message, 'unreadable', 'with the runtime\'s message')
t.eq(results.p4.error, 'bad_response', 'a ranking missing a genre is an error')

t.eq(results.p1.noGenre, false, 'a model without a no-genre class never says no genre')

local function withNoGenre(id, photo, genres, probability)
  local it = rankedItem(id, photo, genres)
  it.ranked.no_genre = { probability = probability, cutoff = 0.5 }
  return it
end
results = Model.parseResponse(response { withNoGenre('p1', '1', all(G[1]), 0.7),
                                         withNoGenre('p2', '2', all(G[1]), 0.2),
                                         withNoGenre('p3', '3', all(G[1]), 'high') }, items)
t.eq(results.p1.noGenre, true, 'no_genre reaching its cut-off: the model says no genre')
t.eq(results.p2.noGenre, false, 'below its cut-off: it does not')
t.eq(results.p3.error, 'bad_response', 'a malformed no_genre is an error, never a guess')

results = Model.parseResponse(response { rankedItem('p1', '99', all(G[1])) }, { items[1] })
t.eq(results.p1.error, 'no_answer', 'an answer for another photograph does not count')
results = Model.parseResponse(response {}, { items[1] })
t.eq(results.p1.error, 'no_answer', 'a missing answer is an error')
results = Model.parseResponse(response { { request_id = 'p1', photo_id = '1', error = 'Canceled' } }, { items[1] })
t.eq(results.p1.error, 'canceled', 'a cancelled photograph is marked so, not as a failure')

local r, code = Model.parseResponse(response({ rankedItem('p1', '1', all(G[1])) }, 'other-taxonomy'), { items[1] })
t.ok(r == nil and code == 'model_mismatch', 'a model for another taxonomy fails the whole call')
r, code = Model.parseResponse('garbage', { items[1] })
t.ok(r == nil and code == 'bad_response', 'an unreadable response fails the whole call')

t.suite('GrModel — the stored ranking')

local rk = ranked { { G[2], true }, { G[1], true }, { G[3], false } }
local text2 = Model.rankingText(rk)
t.eq(text2, Taxonomy.short(G[2]) .. '* ' .. Taxonomy.short(G[1]) .. '* ' .. Taxonomy.short(G[3]),
     'short forms in order, * where the genre reaches its cut-off')
t.eq(Model.parseRanking(text2), rk, 'and read back')
t.eq(Model.parseRanking('Xyz* ' .. Taxonomy.short(G[1])), ranked { { G[1], false } }, 'an unknown short form is skipped')
t.eq(Model.rankingText(rk, true), '-* ' .. text2, 'the model\'s no-genre answer leads the ranking as -*')
t.eq(Model.parseRanking('-* ' .. text2), rk, 'and reading it back gives the genres alone')
t.eq(Model.parseRanking(nil), {}, 'no ranking reads as empty')

t.suite('GrModel — the suggestion (ADR-023)')

local three = ranked { { G[3], true }, { G[1], true }, { G[2], false }, { G[4], false } }
t.eq(Model.suggest(three, {}), { primary = G[3], genres = { G[3], G[1] } },
     'genres reaching their cut-off, in ranking order; the first is the primary')
t.eq(Model.suggest(three, { G[4] }), { primary = G[3], genres = { G[3], G[1], G[4] } },
     'a pre-tag joins in its ranking position; the model\'s ranking still picks the primary')
t.eq(Model.suggest(three, { G[2] }), { primary = G[3], genres = { G[3], G[1], G[2] } },
     'a pre-tag ranked below the applying genres stays below them')
local tagFirst = ranked { { G[4], false }, { G[3], true }, { G[1], true } }
t.eq(Model.suggest(tagFirst, { G[4] }), { primary = G[4], genres = { G[4], G[3], G[1] } },
     'a pre-tag the model ranks as the most likely primary is the primary: the ranking decides')
local none = ranked { { G[1], false }, { G[2], false }, { G[3], false }, { G[4], false } }
t.eq(Model.suggest(none, {}), { primary = NO, genres = {} }, 'nothing reaches its cut-off and nothing tagged: No genre')
t.eq(Model.suggest(none, { G[4], G[2] }), { primary = G[2], genres = { G[2], G[4] } },
     'nothing reaches its cut-off: the pre-tag the model ranks highest is the primary')
t.eq(Model.suggest(none, { [G[3]] = true }), { primary = G[3], genres = { G[3] } }, 'pre-tags may be a set')
t.eq(Model.suggest(three, { 'Wedding' }).genres, { G[3], G[1] }, 'an unknown pre-tag is ignored')
t.eq(Model.suggest(three, {}, true), { primary = NO, genres = {} },
     'the model says no genre: No genre, whatever genres reach their cut-off')
t.eq(Model.suggest(three, { G[4], G[1] }, true), { primary = G[1], genres = { G[1], G[4] } },
     'the model says no genre but the user tagged genres: they stand, the one ranked highest primary')

t.suite('GrModel — the personal floor (ADR-028)')

t.eq(Model.personalFloor { personal_floor = 0.5 }, 0.5, 'the floor comes from the manifest')
t.isNil(Model.personalFloor {}, 'a manifest without one has no floor')
t.isNil(Model.personalFloor { personal_floor = 'high' }, '... nor one with a floor that is not a number')
t.isNil(Model.personalFloor(nil), '... nor a missing manifest')
t.ok(Model.usesFloor(true, 'recommended', 0.5), 'the floor applies to a personal photograph by default')
t.ok(not Model.usesFloor(false, 'recommended', 0.5), '... never to one that is not personal')
t.ok(not Model.usesFloor(true, 'off', 0.5), '... nor with the setting at cut-offs only')
t.ok(not Model.usesFloor(true, 'recommended', nil), '... nor without a floor')

-- Applicability and cut-off per genre: over both, over the cut-off only, under both.
local function scored(list)
  local out = {}
  for _, s in ipairs(list) do
    out[#out + 1] = { genre = s[1], applicability = s[2], cutoff = s[3], applies = s[2] >= s[3] }
  end
  return out
end
local sc = Model.markFloor(scored { { G[1], 0.45, 0.3 }, { G[2], 0.8, 0.4 }, { G[3], 0.5, 0.5 }, { G[4], 0.2, 0.3 } }, 0.5)
t.eq({ sc[1].overFloor, sc[2].overFloor, sc[3].overFloor, sc[4].overFloor }, { nil, true, true, nil },
     'a genre is over the floor when it reaches it and its cut-off; reaching it exactly counts')
t.eq(Model.suggest(sc, {}, false, true), { primary = G[2], genres = { G[2], G[3] } },
     'with the floor: the primary is the first genre left, in ranking order')
t.eq(Model.suggest(sc, {}, false, false), { primary = G[1], genres = { G[1], G[2], G[3] } },
     'without it: the model\'s cut-offs')
t.eq(Model.suggest(sc, { G[1] }, false, true), { primary = G[1], genres = { G[1], G[2], G[3] } },
     'a pre-tag under the floor still counts: present by the user\'s word')
t.eq(Model.suggest(sc, {}, true, true), { primary = NO, genres = {} },
     'the no-genre answer comes first, floor or not')
local low = Model.markFloor(scored { { G[1], 0.45, 0.3 }, { G[2], 0.2, 0.3 } }, 0.5)
t.eq(Model.suggest(low, {}, false, true), { primary = NO, genres = {} }, 'nothing left over the floor: No genre')
t.eq(#Model.markFloor(scored { { G[1], 0.9, 0.3 } }, nil), 1, 'no floor marks nothing')
t.isNil(Model.markFloor(scored { { G[1], 0.9, 0.3 } }, nil)[1].overFloor, '... at all')

local ftext = Model.rankingText(sc, false, 0.5)
t.eq(ftext, Taxonomy.short(G[1]) .. '* ' .. Taxonomy.short(G[2]) .. '*+ ' .. Taxonomy.short(G[3]) .. '*+ '
            .. Taxonomy.short(G[4]) .. ' floor=0.5', 'the ranking marks + over the floor and ends with the floor')
local back, info = Model.parseRanking(ftext)
t.eq({ back[1].overFloor, back[2].overFloor, back[4].applies }, { nil, true, false }, 'and is read back')
t.eq(info, { noGenre = false, floor = 0.5 }, '... with the floor it was marked for')
t.eq(Model.suggest(back, {}, info.noGenre, true), Model.suggest(sc, {}, false, true),
     'a suggestion re-derived from the stored ranking equals the one from the model\'s answer')
local _, ng = Model.parseRanking('-* ' .. ftext)
t.eq(ng.noGenre, true, 'the no-genre mark is read back for re-deriving')
local _, old = Model.parseRanking(text2)
t.eq(old, { noGenre = false }, 'a ranking from a model without a floor has none')
t.eq(Model.rankingText(sc, false, nil), Model.rankingText(sc), 'without a floor the ranking is as before')

t.suite('GrModel — one process call, through GrCli')

-- Absolute: the process starts in its own work directory.
local cwd = io.popen('pwd'):read('*l')
Model.binary = (here:sub(1, 1) == '/' and here or (cwd .. '/' .. here)) .. '/fixtures/fake-localgenres'
local dir = '/tmp/genreator-test-model-run'
os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
local img = dir .. '/a.jpg'
local f = io.open(img, 'wb'); f:write('jpeg'); f:close()
local cfg = { modelTimeoutSeconds = 30 }

results, modelId = Model.run({ { requestId = 'p1', photoId = 7, imagePath = img, personal = true },
                               { requestId = 'p2', photoId = 8, imagePath = dir .. '/missing.jpg' } }, dir, cfg)
t.ok(results ~= nil, 'the call succeeds')
t.eq(modelId, 'fake-model', 'the model id comes from the response')
t.eq(results.p1.ranked[1].genre, G[2], 'the Personal flag reached the model (the stand-in swaps on it)')
t.eq(results.p2.error, 'model_error', 'a missing image is that photograph\'s error only')

f = io.open(dir .. '/fail', 'wb'); f:write('x'); f:close()
local res, failCode, failMsg = Model.run({ { requestId = 'p1', photoId = 7, imagePath = img } }, dir, cfg)
t.ok(res == nil and failCode == 'model_failed', 'a crashed model fails the call')
t.contains(failMsg, 'model exploded', 'with its message')
os.remove(dir .. '/fail')

local hint = Model.quarantineHint()
t.contains(hint, "xattr -dr com.apple.quarantine '" .. Taxonomy.pluginDir() .. "'",
           'a runtime that does not start: the quarantine command names this plugin folder (ADR-026)')

local cancel = dir .. '/cancel'
f = io.open(cancel, 'wb'); f:write('x'); f:close()
results = Model.run({ { requestId = 'p1', photoId = 7, imagePath = img } }, dir, cfg, cancel)
t.eq(results.p1.error, 'canceled', 'the cancel file stops the remaining photographs')

Model.binary = nil
os.execute("rm -rf '" .. dir .. "'")

t.suite('GrModel — the suggested rating (ADR-029)')

local function withRating(id, photo, genres, rating)
  local it = rankedItem(id, photo, genres)
  it.ranked.rating = rating
  return it
end
local good = { score = 1.62, bucket = { ['1.5'] = 3, ['2.0'] = 2 }, default_ratio = '1.5' }
results = Model.parseResponse(response {
  withRating('p1', '1', all(G[1]), good),
  rankedItem('p2', '2', all(G[1])),
  withRating('p3', '3', all(G[1]), { score = 'high', bucket = { ['1.5'] = 3 }, default_ratio = '1.5' }),
  withRating('p4', '4', all(G[1]), { score = 1.0, bucket = { ['1.5'] = 4 }, default_ratio = '1.5' }),
}, items)
t.eq(results.p1.rating, { score = 1.62, bucket = { ['1.5'] = 3, ['2.0'] = 2 }, defaultRatio = '1.5' },
     'the rating answer is read: score, a bucket per shipped ratio, the default ratio')
t.eq(results.p2.rating, nil, 'a model without a rating head answers none')
t.eq(results.p3.ratingError ~= nil and results.p3.rating == nil, true, 'a malformed rating is a rating error, never a guess')
t.ok(results.p3.ranked ~= nil, '... and does not fail the genres, which Classify reads alone')
t.ok(results.p4.ratingError ~= nil, 'a bucket outside 0–3 is a rating error')
results = Model.parseResponse(response {
  withRating('p1', '1', all(G[1]), { score = 1.0, bucket = { ['2.0'] = 1 }, default_ratio = '1.5' }),
  withRating('p2', '2', all(G[1]), { score = 1.0, bucket = { ['1.5'] = 1, ['2'] = 0 }, default_ratio = '2.0' }) },
  { items[1], items[2] })
t.ok(results.p1.ratingError ~= nil, 'a rating whose default ratio is not among its buckets is a rating error')
t.eq(results.p2.ratingError, nil, '"2" and "2.0" name the same ratio')

local manifest = { rating = { default_ratio = '1.5', thresholds = { ['1.5'] = { 0.3, 0.8, 1.4 }, ['2.0'] = { 0.5, 1.1, 1.8 } } } }
t.eq(Model.ratingRatio(manifest, 'recommended'), '1.5', 'the recommended setting takes the model\'s default ratio')
t.eq(Model.ratingRatio(manifest, 2), '2.0', 'a numeric setting names a shipped ratio, however it is spelt')
t.eq(Model.ratingRatio(manifest, '2.0'), '2.0', '... or as text')
t.eq(Model.ratingRatio(manifest, 3), nil, 'a ratio the model does not ship is not used')
t.eq(Model.ratingRatio({}, 'recommended'), nil, 'a model without a rating head has no ratio')

local sug = Model.ratingSuggestion(good and { score = 1.62, bucket = { ['1.5'] = 3, ['2.0'] = 2 }, defaultRatio = '1.5' }, '2.0')
t.eq(sug, { score = 1.62, bucket = 2, ratio = '2.0', buckets = '1.5=3 2.0=2' },
     'the suggestion takes the bucket under the chosen ratio and stores every bucket')
t.eq(Model.ratingSuggestion(nil, '1.5'), nil, 'no rating, no suggestion')
t.eq(Model.ratingSuggestion({ score = 1, bucket = { ['1.5'] = 1 }, defaultRatio = '1.5' }, '3'), nil,
     'a ratio the answer lacks gives no suggestion')
t.eq(Model.parseRatingBuckets('1.5=3 2.0=2'), { ['1.5'] = 3, ['2.0'] = 2 }, 'the stored buckets read back')
t.eq(Model.parseRatingBuckets(''), {}, 'nothing stored reads as empty')
t.eq(Model.ratingSuggestion({ score = 1, bucket = { ['1.5'] = 1, ['2'] = 0 }, defaultRatio = '1.5' }, '2.0').bucket, 0,
     'the suggestion finds a ratio however the answer spells it')
t.eq({ Model.rederiveBucket('1.5=3 2.0=2', '2') }, { 2, '2.0' }, 'a changed ratio is re-derived from the stored buckets')
t.eq(Model.rederiveBucket('1.5=3', '2.0'), nil, '... and not when they lack it')

return t
