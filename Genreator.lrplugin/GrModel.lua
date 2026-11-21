--[[
GrModel — the bundled genre model (ADR-021): the one classifier.

The model is a native program, `model/localgenres`, with its files beside it. One process
call classifies a batch: the plugin writes the request (rendition paths, the Personal flag)
to a file, runs the program through GrCli, and reads the response file. Nothing leaves the
computer.

The response ranks every genre by how likely it is the primary, and says for each whether it
reaches the model's cut-off for "applies". A model with a no-genre class also says whether
"no genre" reaches its own cut-off. The plugin keeps that as a ranking (`aiRanking`, e.g.
`Por* Str* Eve Doc …`, `*` = reaches the cut-off, a leading `-*` = no genre reaches its
cut-off) and derives the suggestion from it together with the genres the user tagged before
classifying (ADR-022, ADR-023):

  suggested genres = every genre that reaches its cut-off or is pre-tagged, in ranking order;
                     only the pre-tags when the model says no genre
  primary          = the first of them; NO_GENRE when there is none

On a personal photograph a model may bring a higher bar, its recommended floor
(`personal_floor` in the manifest, ADR-028): a genre counts there only when its applicability
reaches its cut-off and the floor. The no-genre answer is unchanged and still comes first. The
ranking marks such genres `+` (`Por*+`) and ends with the floor it was marked for
(`floor=0.5`), so a change of the user's setting (`personalFloor`) re-derives the suggestion
without the model.

A response that names a genre outside the taxonomy, or misses a photograph, is an error for
that photograph: never a guess.

A model with a keyword head (ADR-030) answers `ranked.keywords` too: every keyword of its
keyword taxonomy by score, the rules' cut-offs, a cap, the keywords that need both members to
agree, and the implied general keywords. `deriveKeywords` turns that into the suggestion.

Pure: buildRequest, parseResponse, personalFloor, markFloor, usesFloor, rankingText,
parseRanking, suggest, the suggested rating's ratingRatio, ratingSuggestion and
rederiveBucket (ADR-029), and deriveKeywords (ADR-030). Lightroom-bound: run, check, manifest.
]]

local Json     = require 'GrJson'
local Taxonomy = require 'GrTaxonomy'

local Model = {}

Model.SCHEMA_VERSION = 1
Model.TASK = 'genres'
Model.MAX_ITEMS = 20000
Model.APPLIES = '*'
Model.OVER_FLOOR = '+'
Model.FLOOR_TOKEN = 'floor='
-- The personalFloor setting (GrConfig): the model's recommended floor, or its cut-offs alone.
Model.FLOOR_MODES = { recommended = 'recommended', off = 'off' }

--- The model folder inside the plugin.
function Model.dir()
  return Taxonomy.pluginDir() .. '/model'
end

--- The runtime program. Tests point this at a stand-in script.
Model.binary = nil
function Model.binaryPath()
  return Model.binary or (Model.dir() .. '/localgenres')
end

--- What to do when the runtime does not start (ADR-026): a plugin unzipped from a download
-- carries macOS's quarantine flag, and the runtime is not notarized, so macOS may refuse it.
function Model.quarantineHint()
  local path = Taxonomy.pluginDir():gsub("'", "'\\''")
  return 'If you installed Genreator from a downloaded zip, macOS may be blocking its model '
    .. 'program. In Terminal, run:\n\n'
    .. "xattr -dr com.apple.quarantine '" .. path .. "'\n\nthen run Check Model again."
end

-- ------------------------------------------------------------ pure

--- Pure: the request table.
-- @param items array of { requestId, photoId, imagePath, personal = bool }
function Model.buildRequest(items, cancelFile)
  local list = {}
  for _, it in ipairs(items) do
    -- Renditions are exported upright, so the orientation is always AB (as stored).
    list[#list + 1] = Json.ordered({ 'request_id', 'photo_id', 'image_path', 'orientation', 'known_person' }, {
      request_id = it.requestId, photo_id = tostring(it.photoId), image_path = it.imagePath,
      orientation = 'AB', known_person = it.personal == true,
    })
  end
  local req = { schema_version = Model.SCHEMA_VERSION, task = Model.TASK, items = Json.array(list) }
  if cancelFile then req.cancel_file = cancelFile end
  return req
end

--- Pure: the rating head's answer (ADR-029): { score, bucket = { [ratio] = 0..3 }, defaultRatio },
-- nil when the model has no rating head; or nil, message when it is malformed.
local function ratingOf(r)
  if r == nil or r == Json.null then return nil end
  if type(r) ~= 'table' or type(r.score) ~= 'number' or r.score ~= r.score
     or type(r.bucket) ~= 'table' or type(r.default_ratio) ~= 'string' then
    return nil, 'rating has no score, buckets or default ratio'
  end
  local bucket, any = {}, false
  for ratio, b in pairs(r.bucket) do
    if type(ratio) ~= 'string' or type(b) ~= 'number' or b < 0 or b > 3 or b ~= math.floor(b) then
      return nil, 'rating has a malformed bucket'
    end
    bucket[ratio] = b
    any = true
  end
  if not any or not Model.ratioKey(bucket, r.default_ratio) then return nil, 'rating lacks its default ratio' end
  return { score = r.score, bucket = bucket, defaultRatio = r.default_ratio }
end

-- The keyword rules (ADR-030): `balanced` (the model's best F1, the default) or
-- `recall_first` (more suggestions at lower precision).
Model.KEYWORD_RULES = { 'balanced', 'recall_first' }
Model.KEYWORD_RULE_DEFAULT = 'balanced'

local function num(x) return type(x) == 'number' and x == x end

--- Pure: the keyword head's answer (ADR-030), validated against the bundled keyword taxonomy:
-- { cap, cutoffs = {rule = n}, memberCutoffs = {rule = {zeroShot, probe}}, agreementOnly = {name = true},
--   implied = {name = name}, ranked = { {keyword, score, zeroShot, probe} } }; nil when the
-- model or the bundle has no keyword head; or nil, message when it is malformed.
local function keywordsOf(k)
  if k == nil or k == Json.null then return nil end
  local KT = require 'GrKeywordTaxonomy'
  if not KT.available() then return nil end
  if type(k) ~= 'table' or not num(k.cap) or k.cap < 0 or type(k.cutoffs) ~= 'table'
     or type(k.member_cutoffs) ~= 'table' or type(k.ranked) ~= 'table' then
    return nil, 'keywords have no cap, cut-offs or ranking'
  end
  local out = { cap = k.cap, cutoffs = {}, memberCutoffs = {}, agreementOnly = {}, implied = {}, ranked = {} }
  for _, rule in ipairs(Model.KEYWORD_RULES) do
    local m = k.member_cutoffs[rule]
    if not num(k.cutoffs[rule]) or type(m) ~= 'table' or not num(m.zero_shot) or not num(m.probe) then
      return nil, string.format('keywords have no cut-offs for the rule %s', rule)
    end
    out.cutoffs[rule] = k.cutoffs[rule]
    out.memberCutoffs[rule] = { zeroShot = m.zero_shot, probe = m.probe }
  end
  local function known(name) return type(name) == 'string' and KT.idOfName(name) ~= nil end
  for _, name in ipairs(type(k.agreement_only) == 'table' and k.agreement_only or {}) do
    if not known(name) then return nil, string.format('keyword %q is not in the keyword taxonomy', tostring(name)) end
    out.agreementOnly[name] = true
  end
  for name, general in pairs(type(k.implied) == 'table' and k.implied or {}) do
    if not known(name) or not known(general) then
      return nil, string.format('implied keyword %q > %q is not in the keyword taxonomy', tostring(general), tostring(name))
    end
    out.implied[name] = general
  end
  local seen = {}
  for _, r in ipairs(k.ranked) do
    if type(r) ~= 'table' or not known(r.keyword) then
      return nil, string.format('keyword %q is not in the keyword taxonomy', tostring(type(r) == 'table' and r.keyword))
    end
    if seen[r.keyword] then return nil, string.format('keyword %q listed twice', r.keyword) end
    if not num(r.score) or not num(r.zero_shot) or not num(r.probe) then
      return nil, string.format('keyword %q has no score', r.keyword)
    end
    seen[r.keyword] = true
    out.ranked[#out.ranked + 1] = { keyword = r.keyword, score = r.score, zeroShot = r.zero_shot, probe = r.probe }
  end
  return out
end

--- Pure: the suggestion from the keyword head's answer under `rule` (R10.3): walk the ranking,
-- take each keyword at or over the rule's cut-off until `cap` are taken; an agreement-only
-- keyword is taken only when both members reach their own cut-offs, and otherwise uses no
-- slot. A taken keyword is agreed when both members reach their cut-offs. The implied general
-- keywords of those taken, unless taken themselves, are reported apart. All as keyword ids.
-- @return { ids, agreed, implied } (ids in the model's order; none is a valid answer)
function Model.deriveKeywords(kw, rule)
  local KT = require 'GrKeywordTaxonomy'
  rule = kw.cutoffs[rule] and rule or Model.KEYWORD_RULE_DEFAULT
  local cut, member = kw.cutoffs[rule], kw.memberCutoffs[rule]
  local taken, agreed, isTaken = {}, {}, {}
  for _, r in ipairs(kw.ranked) do
    if #taken >= kw.cap then break end
    if r.score >= cut then
      local both = r.zeroShot >= member.zeroShot and r.probe >= member.probe
      if both or not kw.agreementOnly[r.keyword] then
        local id = KT.idOfName(r.keyword)
        taken[#taken + 1] = id
        isTaken[r.keyword] = true
        if both then agreed[#agreed + 1] = id end
      end
    end
  end
  local implied, isImplied = {}, {}
  for _, id in ipairs(taken) do
    local general = kw.implied[KT.nameOf(id)]
    if general and not isTaken[general] and not isImplied[general] then
      isImplied[general] = true
      implied[#implied + 1] = KT.idOfName(general)
    end
  end
  return { ids = taken, agreed = agreed, implied = implied }
end

--- Pure: one item's ranked list, validated against the taxonomy. Each entry keeps the
-- model's numbers too, for picking photos to review (GrPick); they are never stored (ADR-004).
-- @return array of { genre, applies, applicability, cutoff, primaryProbability } in the model's
--         order, nil, nil, noGenre, noGenreProbability; or nil, code, message
local function rankedOf(item)
  local genres = type(item.ranked) == 'table' and item.ranked.genres
  if type(genres) ~= 'table' then return nil, 'bad_response', 'no ranked genres' end
  local out, seen = {}, {}
  for _, g in ipairs(genres) do
    if type(g) ~= 'table' or type(g.genre) ~= 'string' then
      return nil, 'bad_response', 'a ranked entry has no genre'
    end
    if not Taxonomy.isGenre(g.genre) then
      return nil, 'unknown_genre', string.format('genre %q is not in the taxonomy', g.genre)
    end
    if seen[g.genre] then return nil, 'bad_response', string.format('genre %q listed twice', g.genre) end
    if type(g.applicability) ~= 'number' or type(g.cutoff) ~= 'number' then
      return nil, 'bad_response', string.format('genre %q has no applicability or cut-off', g.genre)
    end
    seen[g.genre] = true
    out[#out + 1] = { genre = g.genre, applies = g.applicability >= g.cutoff,
                      applicability = g.applicability, cutoff = g.cutoff,
                      primaryProbability = type(g.primary_probability) == 'number' and g.primary_probability or nil }
  end
  for _, g in ipairs(Taxonomy.genres) do
    if not seen[g] then return nil, 'bad_response', string.format('genre %q is missing from the ranking', g) end
  end
  -- A model with a no-genre class answers it too; one without leaves it out.
  local ng = item.ranked.no_genre
  local noGenre, noGenreProbability = false, nil
  if ng ~= nil and ng ~= Json.null then
    if type(ng) ~= 'table' or type(ng.probability) ~= 'number' or type(ng.cutoff) ~= 'number' then
      return nil, 'bad_response', 'no_genre has no probability or cut-off'
    end
    noGenre = ng.probability >= ng.cutoff
    noGenreProbability = ng.probability
  end
  return out, nil, nil, noGenre, noGenreProbability
end

--- Pure: read a response against the request items. A model with a rating head (ADR-029)
-- answers a rating too; it is read beside the genres, and a malformed one is `ratingError`, so
-- it fails Suggest Ratings for that photograph and never a classification, which ignores it.
-- The keyword head's answer (ADR-030) is read the same way: `keywords`, or `keywordError`.
-- @return { [requestId] = { ranked = {…}, noGenre = bool, rating = {…} | nil, ratingError = text | nil,
--                           keywords = {…} | nil, keywordError = text | nil }
--           | { error = code, message = text } }, modelId;
--         or nil, code, message when the whole response is unusable
function Model.parseResponse(text, items)
  local ok, data = pcall(Json.decode, text or '')
  if not ok or type(data) ~= 'table' or type(data.items) ~= 'table' then
    return nil, 'bad_response', 'the model wrote no readable response'
  end
  if data.taxonomy_version ~= Taxonomy.version then
    return nil, 'model_mismatch', string.format('the model answers for taxonomy %s, the plugin has %s',
      tostring(data.taxonomy_version), Taxonomy.version)
  end
  local byId = {}
  for _, item in ipairs(data.items) do
    if type(item) == 'table' and type(item.request_id) == 'string' then byId[item.request_id] = item end
  end
  local out = {}
  for _, it in ipairs(items) do
    local item = byId[it.requestId]
    if not item or item.photo_id ~= tostring(it.photoId) then
      out[it.requestId] = { error = 'no_answer', message = 'the model returned nothing for this photograph' }
    elseif item.error ~= nil then
      out[it.requestId] = { error = item.error == 'Canceled' and 'canceled' or 'model_error',
                            message = tostring(item.error) }
    else
      local ranked, code, msg, noGenre, noGenreProbability = rankedOf(item)
      local rating, ratingError = ratingOf(item.ranked and item.ranked.rating)
      local keywords, keywordError = keywordsOf(item.ranked and item.ranked.keywords)
      out[it.requestId] = ranked and { ranked = ranked, noGenre = noGenre, noGenreProbability = noGenreProbability,
                                       rating = rating, ratingError = ratingError,
                                       keywords = keywords, keywordError = keywordError }
                          or { error = code, message = msg }
    end
  end
  return out, data.model_id
end

-- ------------------------------------------------------------ suggested rating (ADR-029)

Model.RATING_RECOMMENDED = 'recommended'

--- Pure: the bucket ratio to use: the model's default under the `recommended` setting, else
-- the setting when the model ships that ratio; nil, reason when the model has no rating head
-- or does not ship the ratio.
function Model.ratingRatio(manifest, setting)
  local r = type(manifest) == 'table' and manifest.rating or nil
  if type(r) ~= 'table' or type(r.default_ratio) ~= 'string' then return nil, 'this model has no rating head' end
  if setting == nil or setting == Model.RATING_RECOMMENDED then return r.default_ratio end
  local shipped = type(r.thresholds) == 'table' and r.thresholds or {}
  local ratio = Model.ratioKey(shipped, setting)
  if ratio then return ratio end
  return nil, string.format('the model does not ship bucket ratio %s', tostring(setting))
end

--- Pure: the key of `byRatio` naming `ratio`: "2" and "2.0" name the same ratio.
function Model.ratioKey(byRatio, ratio)
  if type(byRatio) ~= 'table' or ratio == nil then return nil end
  if byRatio[tostring(ratio)] ~= nil then return tostring(ratio) end
  for key in pairs(byRatio) do
    if tonumber(key) ~= nil and tonumber(key) == tonumber(ratio) then return key end
  end
  return nil
end

--- Pure: the stored form of every bucket, "1.5=3 2.0=2" (ratios in numeric order), and back.
function Model.ratingBucketsText(bucket)
  local ratios = {}
  for ratio in pairs(bucket or {}) do ratios[#ratios + 1] = ratio end
  table.sort(ratios, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
  local parts = {}
  for _, ratio in ipairs(ratios) do parts[#parts + 1] = ratio .. '=' .. tostring(bucket[ratio]) end
  return table.concat(parts, ' ')
end
function Model.parseRatingBuckets(text)
  local out = {}
  for ratio, b in (text or ''):gmatch('(%S+)=(%d)') do out[ratio] = tonumber(b) end
  return out
end

--- Pure: the suggestion from the model's rating answer under `ratio` (Model.ratingRatio):
-- { score, bucket, ratio, buckets = text }, or nil without a rating or a usable ratio. The
-- bucket is 0 (likely 0 stars) to 3 (a candidate for 3 stars and above).
function Model.ratingSuggestion(rating, ratio)
  if type(rating) ~= 'table' then return nil end
  local key = Model.ratioKey(rating.bucket, ratio)
  if not key then return nil end
  return { score = rating.score, bucket = rating.bucket[key], ratio = key,
           buckets = Model.ratingBucketsText(rating.bucket) }
end

--- Pure: the bucket under `ratio` from the stored buckets ("1.5=3 2.0=2"), without the model,
-- for a changed ratio setting; nil when they do not hold that ratio.
function Model.rederiveBucket(bucketsText, ratio)
  local stored = Model.parseRatingBuckets(bucketsText)
  local key = Model.ratioKey(stored, ratio)
  return key and stored[key] or nil, key
end

--- Pure: a manifest's recommended floor for personal photographs (ADR-028), or nil when it
-- has none. The import tool refuses a floor that is not a number from 0 to 1.
function Model.personalFloor(manifest)
  local f = type(manifest) == 'table' and manifest.personal_floor or nil
  if type(f) == 'number' and f >= 0 and f <= 1 then return f end
  return nil
end

--- Pure: mark the genres of a ranked list (parseResponse) that reach the floor as well as
-- their cut-off: `overFloor = true`. Without a floor, nothing is marked.
function Model.markFloor(ranked, floor)
  for _, r in ipairs(ranked or {}) do
    if floor and r.applies and type(r.applicability) == 'number' and r.applicability >= floor then
      r.overFloor = true
    end
  end
  return ranked
end

--- Pure: does the floor apply to this photograph? Only to a personal one, with the setting
-- at its recommended default, and a ranking marked for a floor.
function Model.usesFloor(personal, mode, floor)
  return personal == true and mode ~= Model.FLOOR_MODES.off and floor ~= nil
end

--- Pure: { {genre, applies, overFloor}, … } -> "Por*+ Str* Eve … floor=0.5"; a leading "-*"
-- when the model says no genre; the trailing floor only when the model has one.
Model.NO_GENRE_MARK = '-' .. Model.APPLIES
function Model.rankingText(ranked, noGenre, floor)
  local parts = { noGenre and Model.NO_GENRE_MARK or nil }
  for _, r in ipairs(ranked or {}) do
    parts[#parts + 1] = Taxonomy.short(r.genre) .. (r.applies and Model.APPLIES or '')
                        .. (r.applies and r.overFloor and floor and Model.OVER_FLOOR or '')
  end
  if floor then parts[#parts + 1] = Model.FLOOR_TOKEN .. tostring(floor) end
  return table.concat(parts, ' ')
end

--- Pure: "Por*+ Str* Eve … floor=0.5" -> { {genre, applies, overFloor = true | nil}, … }, and
-- { noGenre = bool, floor = number | nil }; unknown short forms are skipped.
function Model.parseRanking(text)
  local out, info = {}, { noGenre = false }
  for token in (text or ''):gmatch('%S+') do
    local short, mark, over = token:match('^(%a+)(%*?)(%+?)$')
    local genre = short and Taxonomy.fromShort(short)
    if genre then
      local applies = mark == Model.APPLIES
      out[#out + 1] = { genre = genre, applies = applies, overFloor = (applies and over == Model.OVER_FLOOR) or nil }
    elseif token == Model.NO_GENRE_MARK then
      info.noGenre = true
    elseif token:sub(1, #Model.FLOOR_TOKEN) == Model.FLOOR_TOKEN then
      info.floor = tonumber(token:sub(#Model.FLOOR_TOKEN + 1))
    end
  end
  return out, info
end

--- Pure: the suggestion from a ranking and the user's pre-tagged genres (ADR-023).
-- A pre-tag the ranking does not list (it always lists every genre) goes last. When the model
-- says no genre, only the pre-tags count: they are present by the user's word. With
-- `useFloor` (a personal photograph, Model.usesFloor), a genre counts only when it reaches
-- the floor as well as its cut-off (ADR-028); pre-tags still count.
-- @param preTags array or set of genre names
-- @param noGenre the model's no-genre answer (a model without that class: false)
-- @return { primary = genre | NO_GENRE, genres = {…} in ranking order }
function Model.suggest(ranked, preTags, noGenre, useFloor)
  local tagged = {}
  for k, v in pairs(preTags or {}) do
    local g = type(k) == 'number' and v or k
    if Taxonomy.isGenre(g) then tagged[g] = true end
  end
  local genres, listed = {}, {}
  for _, r in ipairs(ranked or {}) do
    local counts = r.applies and (r.overFloor or not useFloor)
    if ((counts and not noGenre) or tagged[r.genre]) and not listed[r.genre] then
      genres[#genres + 1] = r.genre
      listed[r.genre] = true
    end
  end
  for _, g in ipairs(Taxonomy.genres) do
    if tagged[g] and not listed[g] then genres[#genres + 1] = g end
  end
  return { primary = genres[1] or Taxonomy.NO_GENRE, genres = genres }
end

-- ------------------------------------------------------------ Lightroom-bound

--- The bundled manifest (version, model_id, …), or nil.
function Model.manifest()
  local text = Taxonomy.readFile(Model.dir() .. '/manifest.json')
  local ok, data = pcall(Json.decode, text or '')
  if ok and type(data) == 'table' then return data end
  return nil
end

--- Are the model's files in place? The encoder comes in the release zip, or from `make install`
-- in a source checkout (ADR-026).
-- @return true; or nil, message
function Model.check()
  local LrFileUtils = import 'LrFileUtils'
  local m = Model.manifest()
  if not m then return nil, 'the model manifest is missing from the plugin folder' end
  for path in pairs(m.files or {}) do
    if not LrFileUtils.exists(Model.dir() .. '/' .. path) then
      if path:match('^encoders/') then
        return nil, 'the image encoder is missing: download and unzip the release again '
          .. '(in a source checkout, run `make install`)'
      end
      return nil, 'missing model file: ' .. path
    end
  end
  return true
end

--- Classify a batch: one process call. Must run inside a task (LrTasks.execute yields).
-- @param items as buildRequest; every imagePath must exist
-- @param workDir a directory the request, response and logs go into
-- @return results (as parseResponse), modelId; or nil, code, message
function Model.run(items, workDir, cfg, cancelFile)
  local Cli = require 'GrCli'
  local req = workDir .. '/request.json'
  local resp = workDir .. '/response.json'
  -- A runtime that exits 0 without answering must not leave the previous chunk's answer.
  -- LrFileUtils, not os.remove: Lightroom's embedded os has no remove (seen 2026-10-28).
  local LrFileUtils = import 'LrFileUtils'
  if LrFileUtils.exists(resp) then LrFileUtils.delete(resp) end
  local ok, err = Cli.writeFile(req, Json.encode(Model.buildRequest(items, cancelFile)))
  if not ok then return nil, 'io', 'could not write the request: ' .. tostring(err) end
  local status, _, stderr = Cli.run {
    bin = Model.binaryPath(),
    args = { 'infer', req, resp, Model.dir() .. '/model.json' },
    stdout = workDir .. '/stdout.txt', stderr = workDir .. '/stderr.txt',
    timeout = cfg.modelTimeoutSeconds,
  }
  if status == Cli.TIMEOUT_STATUS then
    return nil, 'timeout', string.format('the model did not finish within %d seconds', cfg.modelTimeoutSeconds)
  end
  if status ~= 0 then
    return nil, 'model_failed', string.format('the model exited with %s: %s', tostring(status),
      (stderr or ''):gsub('%s+$', ''):sub(1, 300))
  end
  return Model.parseResponse(Cli.readFile(resp), items)
end

return Model
