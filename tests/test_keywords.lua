--[[
Keyword suggestions, the pure parts (ADR-030, R10): the keyword taxonomy and its paths, the
model's keyword answer, the selection rule, the stored forms, the plans for Suggest Keywords,
Re-suggest Keywords and Apply Keyword Judgements…, and the judgements file.

Keyword names come from the bundled keyword taxonomy, never from this file, except in the
small taxonomy built here to test validation and paths.
]]

local t = require 'harness'

local Json  = require 'GrJson'
local KT    = require 'GrKeywordTaxonomy'
local Model = require 'GrModel'
local KW    = require 'GrKeywording'

-- ------------------------------------------------------------------ the taxonomy

t.suite('GrKeywordTaxonomy — validation and paths')

local function tax(keywords, version)
  return Json.encode { version = version or '0.1', keywords = keywords }
end
local SMALL = {
  { id = 'boat', name = 'Boat', category = 'Objects', subcategory = 'Transport' },
  { id = 'sailboat', name = 'Sailboat', category = 'Objects', subcategory = 'Transport', fallback = 'boat' },
  { id = 'dinghy', name = 'Dinghy', category = 'Objects', subcategory = 'Transport', fallback = 'sailboat' },
  { id = 'fog', name = 'Fog', category = 'Visual Features', subcategory = 'Weather' },
}
local spec = KT.parse(tax(SMALL))
t.ok(spec ~= nil, 'a well-formed taxonomy parses')
KT.apply(spec)
t.eq(KT.path('fog'), { 'Visual Features', 'Weather', 'Fog' }, 'a keyword sits under its category and subcategory')
t.eq(KT.path('dinghy'), { 'Objects', 'Transport', 'Boat', 'Sailboat', 'Dinghy' },
     'a specific keyword nests under its general keywords, outermost first')
t.eq(KT.idOfPath { 'objects', 'TRANSPORT', 'Boat', 'Sailboat' }, 'sailboat', 'a path is recognised case-insensitively')
t.eq(KT.idOfPath { 'Objects', 'Transport', 'Sailboat' }, nil, 'a keyword away from its taxonomy path is not the taxonomy\'s')
t.eq(KT.idOfPath { 'Objects', 'Transport' }, nil, 'a subcategory is never a taxonomy keyword')
t.eq(KT.idOfPath { 'Legacy', 'Visual Features', 'Weather', 'Fog' }, nil, 'nor the same name under another root')
t.eq(KT.sorted { 'fog', 'boat', 'nope' }, { 'boat', 'fog' }, 'ids sort in taxonomy order; unknown ones drop')

local function refused(keywords, fragment, label, version)
  local s, err = KT.parse(tax(keywords, version))
  t.ok(s == nil and tostring(err):find(fragment, 1, true) ~= nil, label .. ' (' .. tostring(err) .. ')')
end
refused({}, 'no keywords', 'an empty list is refused')
refused(SMALL, 'no version', 'a taxonomy without a version is refused', '')
refused({ { id = 'a', name = 'A', category = 'C' } }, 'subcategory', 'a keyword without a subcategory is refused')
refused({ { id = 'a', name = 'A > B', category = 'C', subcategory = 'S' } }, '">"', 'a name holding ">" is refused')
refused({ { id = 'a', name = 'A', category = 'C', subcategory = 'S' }, { id = 'a', name = 'B', category = 'C', subcategory = 'S' } },
        'listed twice', 'a duplicate id is refused')
refused({ { id = 'a', name = 'A', category = 'C', subcategory = 'S' }, { id = 'b', name = 'a', category = 'C', subcategory = 'S' } },
        'listed twice', 'a duplicate name, in any case, is refused')
refused({ { id = 'a', name = 'A', category = 'C', subcategory = 'S', fallback = 'z' } }, 'not in the taxonomy',
        'a general keyword outside the taxonomy is refused')
refused({ { id = 'a', name = 'A', category = 'C', subcategory = 'S', fallback = 'b' },
          { id = 'b', name = 'B', category = 'C', subcategory = 'S', fallback = 'a' } }, 'cycle', 'a cycle is refused')

t.suite('GrKeywordTaxonomy — the bundled one')

t.ok(KT.load(Model.dir()), 'the bundled keyword taxonomy loads')
t.eq(KT.version, (Model.manifest().keywords or {}).taxonomy_version, 'its version is the manifest\'s')
local K = KT.keywords
t.ok(#K > 10, 'it lists the keywords')
local specific
for _, k in ipairs(K) do if k.fallback then specific = k; break end end
t.ok(specific ~= nil, 'it has a specific keyword with a general form')
t.eq(#KT.path(specific.id), 4, '... nested one level under it')

-- ------------------------------------------------------------------ the model's answer

t.suite('GrModel — the keyword answer (ADR-030)')

local items = { { requestId = 'p1', photoId = 1 }, { requestId = 'p2', photoId = 2 }, { requestId = 'p3', photoId = 3 } }
local Taxonomy = require 'GrTaxonomy'
local function genres()
  local out = {}
  for i, g in ipairs(Taxonomy.genres) do out[i] = { genre = g, applicability = i == 1 and 0.9 or 0.1, cutoff = 0.5 } end
  return out
end
local function head(ranked, extra)
  local k = { cap = 3, cutoffs = { balanced = 2, recall_first = 1 },
              member_cutoffs = { balanced = { zero_shot = 2, probe = 2 }, recall_first = { zero_shot = 1, probe = 1 } },
              agreement_only = {}, implied = { [specific.name] = KT.nameOf(specific.fallback) }, ranked = ranked }
  for key, v in pairs(extra or {}) do k[key] = v end
  return k
end
local function r(name, score, zs, probe) return { keyword = name, score = score, zero_shot = zs or score, probe = probe or score } end
local function respond(kws)
  local list = {}
  for i, kw in ipairs(kws) do
    list[i] = { request_id = 'p' .. i, photo_id = tostring(i), ranked = { genres = genres(), keywords = kw } }
  end
  return Json.encode { taxonomy_version = Taxonomy.version, model_id = 'm', items = list }
end

local results = Model.parseResponse(respond {
  head { r(K[1].name, 3), r(K[2].name, 1) },
  head { r('Not A Keyword', 3) },
  'malformed',
}, items)
t.eq(#results.p1.keywords.ranked, 2, 'a keyword answer is read beside the genres')
t.isNil(results.p1.keywordError, '... without an error')
t.contains(results.p2.keywordError, 'not in the keyword taxonomy', 'a keyword outside the taxonomy is an error, never a guess')
t.ok(results.p2.ranked ~= nil, '... of the keywords alone: the genres stand')
t.ok(results.p3.keywordError ~= nil, 'a malformed answer is an error')
local none = Model.parseResponse(Json.encode { taxonomy_version = Taxonomy.version, items = {
  { request_id = 'p1', photo_id = '1', ranked = { genres = genres() } } } }, { items[1] })
t.isNil(none.p1.keywords, 'a model without a keyword head answers none')
t.isNil(none.p1.keywordError, '... and that is no error')
local noCut = head { r(K[1].name, 3) }
noCut.cutoffs.recall_first = nil
t.contains(Model.parseResponse(respond { noCut }, { items[1] }).p1.keywordError, 'recall_first',
           'an answer without a rule\'s cut-offs is an error')

t.suite('GrModel.deriveKeywords — the selection rule (R10.3)')

local function derive(ranked, rule, extra)
  return Model.deriveKeywords(Model.parseResponse(respond { head(ranked, extra) }, { items[1] }).p1.keywords, rule)
end
local s = derive({ r(K[1].name, 3), r(K[2].name, 2.5, 1.5, 3), r(K[3].name, 1.5), r(K[4].name, 0.5) }, 'balanced')
t.eq(s.ids, { K[1].id, K[2].id }, 'keywords at or over the cut-off, in the model\'s order')
t.eq(s.agreed, { K[1].id }, 'agreed: both members over their own cut-offs')
t.eq(derive({ r(K[1].name, 3), r(K[3].name, 1.5) }, 'recall_first').ids, { K[1].id, K[3].id },
     'the recall-first rule takes more')
t.eq(#derive({ r(K[1].name, 3), r(K[2].name, 3), r(K[3].name, 3), r(K[4].name, 3) }, 'balanced').ids, 3,
     'no more than the cap')
s = derive({ r(K[1].name, 3, 1, 3), r(K[2].name, 3), r(K[3].name, 3), r(K[4].name, 3) }, 'balanced',
           { agreement_only = { K[1].name } })
t.eq(s.ids, { K[2].id, K[3].id, K[4].id }, 'an agreement-only keyword without both members is skipped and uses no slot')
t.eq(derive({ r(K[1].name, 3) }, 'balanced', { agreement_only = { K[1].name } }).ids, { K[1].id },
     '... and taken when both agree')
t.eq(derive({ r(K[1].name, 1) }, 'balanced').ids, {}, 'no keyword is a valid answer')
s = derive({ r(specific.name, 3) }, 'balanced')
t.eq({ s.ids, s.implied }, { { specific.id }, { specific.fallback } }, 'the implied general keyword is reported apart')
s = derive({ r(specific.name, 3), r(KT.nameOf(specific.fallback), 3) }, 'balanced')
t.eq(s.implied, {}, '... unless it is suggested itself')

-- ------------------------------------------------------------------ stored forms and plans

t.suite('GrKeywording — stored forms')

local text = KW.suggestionText { modelVersion = 'v1', taxonomyVersion = '0.14', rule = 'balanced', at = 'T',
                                 ids = { 'a', 'b' }, agreed = { 'a' }, implied = {} }
t.eq(text, 'v1|v1|0.14|balanced|T|a,b|a|', 'the suggestion is one line of fields')
t.eq(KW.parseSuggestion(text), { modelVersion = 'v1', taxonomyVersion = '0.14', rule = 'balanced', at = 'T',
                                 ids = { 'a', 'b' }, agreed = { 'a' }, implied = {} }, '... and reads back')
t.isNil(KW.parseSuggestion(''), 'an empty field holds no suggestion')
t.eq(KW.parseDecided(KW.decidedText { source = 'golden:ab12', at = 'T', ids = {} }),
     { source = 'golden:ab12', at = 'T', ids = {} }, 'the decision reads back, no keywords included')

t.suite('GrKeywording — what a run changes (R10.1, R10.4, R10.5)')

local a, b, c, d = K[1].id, K[2].id, K[3].id, K[4].id
t.eq(KW.syncPlan('suggest', '', { d }, {}, { a, b }), { add = { a, b }, remove = {} },
     'a new photograph gets the suggested keywords; its own stay')
t.eq(KW.syncPlan('suggest', 'error', { a }, {}, { a, b }), { add = { b }, remove = {} },
     'after an error: the missing suggestions only')
t.eq(KW.syncPlan('suggest', 'suggested', { a, c, d }, { a, c }, { a, b }), { add = { b }, remove = { c } },
     'awaiting verification: a keyword the plugin suggested before and no longer does is removed; '
     .. 'the user\'s own (not in the previous suggestion) stays')
t.eq(KW.syncPlan('suggest', 'suggested', { a }, { a, c }, { a }), { add = {}, remove = {} },
     '... and one the user already removed is not added back unless suggested again')
t.eq({ KW.syncPlan('suggest', 'verified', {}, {}, { a }) }, { nil, 'decided' }, 'a verified photograph is left alone')
t.eq({ KW.syncPlan('suggest', 'golden', {}, {}, { a }) }, { nil, 'decided' }, '... and a judged one')
t.eq(KW.syncPlan('resuggest', 'verified', { a, c }, { a, c }, { b }), { add = { b }, remove = {} },
     'Re-suggest adds new suggestions to a verified photograph and removes nothing')
t.eq({ KW.syncPlan('resuggest', 'golden', {}, {}, { a }) }, { nil, 'not verified' }, '... and never touches a judged one')
t.eq(KW.exactPlan({ a, c, d }, { a, b }), { add = { b }, remove = { c, d } }, 'a judgement leaves exactly its keywords')

-- Lightroom's parent filters miss a photograph tagged only with the child (checked 2026-11-06):
-- the general keyword is assigned beside the specific one.
local sp, gen = specific.id, specific.fallback
t.eq(KW.withImplied { a, sp }, KT.sorted { a, sp, gen }, 'a specific keyword brings its general one')
t.eq(KW.syncPlan('suggest', '', {}, {}, { sp }), { add = KT.sorted { sp, gen }, remove = {} },
     'Suggest Keywords assigns the general keyword beside the specific one')
t.eq(KW.syncPlan('suggest', '', { gen }, {}, { sp }), { add = { sp }, remove = {} }, '... unless it is there already')
t.eq(KW.syncPlan('suggest', 'suggested', { sp, gen }, { sp }, { a }), { add = { a }, remove = KT.sorted { sp, gen } },
     're-synchronising removes both when the specific one is no longer suggested')
t.eq(KW.syncPlan('suggest', 'suggested', { sp, gen }, { sp }, { gen }), { add = {}, remove = { sp } },
     '... and keeps the general one when that is what the model now suggests')

local photos = {}
local infos = {
  { photo = 1, state = '' }, { photo = 2, state = 'suggested' }, { photo = 3, state = 'verified' },
  { photo = 4, state = 'golden' }, { photo = 5, isVideo = true }, { photo = 6, state = 'error' }, { photo = 7, state = '' },
}
local run, skipped = KW.plan(infos, 'suggest', function(p) return p == 7 end)
t.eq({ run, skipped }, { { 1, 2, 6 }, { video = 1, decided = 2, notVerified = 0, missing = 1 } },
     'Suggest Keywords renders new, awaiting and failed photographs')
run, skipped = KW.plan(infos, 'resuggest', function() return false end)
t.eq({ run, skipped.notVerified }, { { 3 }, 5 }, 'Re-suggest renders verified photographs only')
local _ = photos

t.suite('GrKeywording — the judgements file (R10.6)')

local function file(items, version)
  return Json.encode { schema_version = 1, taxonomy_version = version or KT.version, count = #items, items = items }
end
local parsed = KW.parseJudgements(file {
  { photo_uuid = 'U1', file_base = 'DSC_1', keywords = { K[2].name, K[1].name } },
  { photo_uuid = 'U2', file_base = 'DSC_2', keywords = {} },
  { photo_uuid = 'U3', file_base = 'DSC_3', keywords = { 'Not A Keyword' } },
  { file_base = 'DSC_4', keywords = {} },
})
t.eq(parsed.items, { { uuid = 'U1', fileBase = 'DSC_1', ids = { K[1].id, K[2].id } }, { uuid = 'U2', fileBase = 'DSC_2', ids = {} } },
     'items read as keyword ids; [] means none')
t.eq(#parsed.invalid, 2, 'an unknown keyword or a missing UUID makes an item invalid, listed not applied')
t.ok(parsed.source:match('^golden:%x+$') ~= nil, 'the source names the file by its fingerprint')
t.contains(select(2, KW.parseJudgements(file({}, '0.0'))), 'keyword taxonomy 0.0', 'a file for another taxonomy is refused')
local item = parsed.items[1]
local applied = KW.decidedText { source = parsed.source, at = 'T', ids = item.ids }
t.eq(KW.judgementAction('golden', applied, item.ids, item, parsed.source), 'unchanged', 'the same file twice changes nothing')
local withGeneral = KW.parseJudgements(file { { photo_uuid = 'U9', file_base = 'X', keywords = { specific.name } } })
t.eq(withGeneral.items[1].ids, KT.sorted { specific.id, specific.fallback }, 'a judged specific keyword brings its general one')
t.eq(KW.judgementAction('golden', KW.decidedText { source = 'golden:old', ids = { a } }, { a }, item, parsed.source), 'apply',
     'a newer file updates a photograph the user has not changed')
t.eq(KW.judgementAction('golden', KW.decidedText { source = 'golden:old', ids = { a } }, { a, c }, item, parsed.source), 'conflict',
     '... and keeps the user\'s change since the last application')
t.eq(KW.judgementAction('verified', KW.decidedText { source = 'verified', ids = { c } }, { c }, item, parsed.source), 'apply',
     'a verified photograph takes the judgement')

return t
