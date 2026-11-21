--[[ Tests for GrReport — the CSV report and the Quality Summary per model version. ]]

local t = require 'harness'
local Report = require 'GrReport'
local Metadata = require 'GrMetadata'
local Photo = require 'photo'

t.suite('GrReport — CSV quoting')

t.eq(Report.csvField('plain'), 'plain', 'plain text unquoted')
t.eq(Report.csvField('a, b'), '"a, b"', 'comma quoted')
t.eq(Report.csvField('say "hi"'), '"say ""hi"""', 'embedded quotes doubled')
t.eq(Report.csvField('two\nlines'), '"two\nlines"', 'newline quoted')
t.eq(Report.csvField(nil), '', 'nil is empty')

t.suite('GrReport — rows from a photo\'s plugin fields')

local F = Metadata.FIELDS
local photo = Photo.new {
  formatted = { fileName = '260420-DSCF0927.raf' },
  plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Landscape',
             [F.aiGenres] = 'Landscape, Nature', [F.aiRanking] = 'Lan* Nat* Str',
             [F.userGenres] = 'Nature', [F.modelVersion] = 'v1', [F.personal] = 'yes',
             [F.decisionPersonal] = 'no' },
}
local csv = Report.toCsv { Report.readPhoto(photo) }
local header, row = csv:match('^([^\n]+)\n(.+)\n$')
t.eq(header, 'file,review_state,primary_genre,genres,ranking,personal,rating_bucket,rating_ratio,rating_score,rating_buckets,rating_model_version,keyword_state,keywords_suggested,keywords_agreed,keywords_implied,keyword_rule,keyword_model_version,keyword_taxonomy,keywords_decided,keyword_decision_source,keyword_error,user_genres,later_user_genres,review_primary,review_genres,' ..
             'human_genre,human_genres,decision_source,decision_model_version,decision_personal,model,model_version,' ..
             'pick_reason,review_trail,run_id,error', 'header')
t.contains(row, '260420-DSCF0927.raf,suggested,Landscape,"Landscape, Nature",Lan* Nat* Str,yes,,,,,,,,,,,,,,,,Nature,', 'values in order')
t.contains(row, ',no,,v1,', '... the personal flag of the decision too (ADR-028)')

-- The keyword review (ADR-030): keyword ids read as their names.
local KT = require 'GrKeywordTaxonomy'
assert(KT.load(require('GrModel').dir()))
local k1, k2 = KT.keywords[1], KT.keywords[2]
local kwRow = Report.rowFor { fileName = 'k.jpg', fields = {
  keywordState = 'verified', keywordSuggestion = 'v1|mv|' .. KT.version .. '|balanced|T|' .. k1.id .. ',' .. k2.id .. '|' .. k1.id .. '|',
  keywordDecided = 'v1|verified|T|' .. k2.id } }
t.contains(kwRow, ',verified,' .. Report.csvField(k1.name .. '; ' .. k2.name) .. ',' .. k1.name .. ',,balanced,mv,' .. KT.version
           .. ',' .. k2.name .. ',verified,', 'the keyword columns name the keywords, the rule, the model and the decision')

t.suite('GrReport — Quality Summary outcomes (R7.8)')

local function fields(state, ai, human, version, source)
  local reviewed = (state == 'accepted' or state == 'corrected') and not (source or ''):match('^approved')
  return { reviewState = state, aiGenre = ai, humanGenre = human, modelVersion = version or 'v2',
           decisionSource = source, decisionModelVersion = reviewed and (version or 'v2') or nil }
end
t.eq(Report.outcome(fields('suggested', 'Street')), 'pending', 'a suggestion awaits review')
t.eq(Report.outcome(fields('error')), 'error', 'an error is counted, not decided')
t.isNil(Report.outcome(fields('unclassified')), 'cleared photographs are skipped')
t.isNil(Report.outcome({}), 'no state is skipped')
t.eq(Report.outcome(fields('accepted', 'Street', 'Street')), 'agreed', 'accepted = agreed')
t.eq(Report.outcome(fields('accepted', 'No genre', 'No genre')), 'agreed', 'accepting No genre is agreement')
t.eq(Report.outcome(fields('corrected', 'Street', 'Street')), 'listCorrected',
     'same primary, different list = list correction, not a primary change')
t.eq(Report.outcome(fields('corrected', 'Street', 'Portrait')), 'primaryDefect', 'primary changed')
t.eq(Report.outcome(fields('corrected', 'Street', 'No genre')), 'primaryDefect', 'changed to No genre')
local moved = fields('accepted', 'Street', 'Street', 'v3')
moved.decisionModelVersion = 'v2'
local old = fields('accepted', 'Street', 'Street', 'v3')
old.decisionModelVersion = nil
t.ok(Report.summarize({ old }, 'v3').versions['(unknown)'] ~= nil,
     'a review decision from before decision versions is not credited to the current model')
t.eq(Report.summarize({ moved }, 'v3').versions.v2.decided, 1,
     'a decision counts under the model version it answered, not the one a reclassification wrote since')
t.eq(Report.outcome(fields('accepted', 'Street', 'Street', 'v2', 'approved:2026.10.27')), 'approved',
     'a decision from an approved genres file is counted apart: no suggestion was judged')

t.suite('GrReport — Quality Summary tallies per model version')

local rows = {
  fields('accepted', 'Street', 'Street'), fields('accepted', 'Nature', 'Nature'),
  fields('corrected', 'Object', 'Object'),
  fields('corrected', 'Street', 'Portrait'), fields('corrected', 'Street', 'Portrait'),
  fields('corrected', 'Event', 'No genre'), fields('suggested', 'Street'), fields('error'),
  fields('accepted', 'Street', 'Street', 'v2', 'approved'),
  fields('corrected', 'Street', 'Nature', 'v1'), fields('accepted', 'Street', 'Street', 'v1'),
  fields('unclassified'),
}
local sum = Report.summarize(rows, 'v2')
local v2 = sum.versions.v2
t.eq({ v2.decided, v2.agreed, v2.listCorrected, v2.primaryDefect, v2.pending, v2.error, v2.approved },
     { 6, 2, 1, 3, 1, 1, 1 }, 'current version counts')
t.eq({ sum.versions.v1.decided, sum.versions.v1.primaryDefect }, { 2, 1 }, 'an older model kept apart')
t.eq(sum.order, { 'v2', 'v1' }, 'current version first')
t.eq(sum.confusion[1], { ai = 'Street', human = 'Portrait', n = 2 }, 'most frequent change first')
t.eq(sum.confusion[2], { ai = 'Event', human = 'No genre', n = 1 }, 'a change to No genre shown as such')
t.eq(#sum.confusion, 2, 'changes cover the current version only')

local short = Report.summaryShort(sum, '/tmp/full.txt')
t.contains(short, 'Model v2: 6 reviewed — primary kept 3 (50%)', 'the headline counts kept primaries')
t.contains(short, 'from an approved genres file 1', 'approved decisions are reported apart')
t.contains(short, 'Street -> Portrait 2', 'changes listed')
t.contains(short, 'v1: 2 reviewed', 'older versions one line each')
t.contains(short, 'Full report: /tmp/full.txt', 'points to the full report')
t.notContains(short, 'REASSESSMENT', 'no reassessment verdict: editing definitions no longer steers the model')

local text = Report.summaryText(sum)
t.contains(text, 'v2  (current)', 'current version marked')
t.contains(text, 'Street -> Portrait: 2', 'change line')
t.contains(Report.summaryText(Report.summarize({}, 'v3')), 'No classified photographs', 'empty catalog says so')

t.suite('GrReport — genre-list edits')

local function dec(state, ai, aiList, human, humanList)
  return { reviewState = state, aiGenre = ai, aiGenres = aiList, humanGenre = human,
           humanGenres = humanList, modelVersion = 'v9', decisionModelVersion = 'v9' }
end
t.eq(Report.listChange(dec('corrected', 'Landscape', 'Landscape, Architecture', 'Landscape', 'Landscape')),
     { added = {}, removed = { 'Architecture' } }, 'a removed genre')
t.eq(Report.listChange(dec('corrected', 'Street', 'Street', 'Portrait', 'Portrait, Street')),
     { added = { 'Portrait' }, removed = {} }, 'a changed primary that keeps the old one is an addition')
t.eq(Report.listChange(dec('corrected', 'Street', 'Street, Object', 'No genre', '')).removed,
     { 'Street', 'Object' }, 'No genre removes everything')
local ls = Report.summarize({
  dec('accepted', 'Landscape', 'Landscape, Nature', 'Landscape', 'Landscape, Nature'),
  dec('corrected', 'Landscape', 'Landscape, Architecture', 'Landscape', 'Landscape'),
  dec('corrected', 'Object', 'Object, Architecture, Landscape', 'Object', 'Object'),
}, 'v9')
t.eq(ls.versions.v9.listChanged, 2, 'two of three lists edited')
t.eq(ls.removed, { { genre = 'Architecture', n = 2 }, { genre = 'Landscape', n = 1 } },
     'removals tallied, most frequent first')

t.suite('GrReport — Quality Summary reads the whole catalog, not the selection')

local LrApplication = require 'LrApplication'
local catalog = LrApplication._fakeCatalog {}
catalog._all = {
  Photo.new { plugin = { [F.reviewState] = 'corrected', [F.aiGenre] = 'Street',
                         [F.humanGenre] = 'Portrait', [F.modelVersion] = 'v2' } },
  Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Nature', [F.modelVersion] = 'v2' } },
  Photo.new {},
}
local got = Report.catalogDecisions(catalog)
t.eq(#got, 2, 'only photographs the plugin has touched')
t.eq(got[1], { reviewState = 'corrected', aiGenre = 'Street', humanGenre = 'Portrait', modelVersion = 'v2' },
     'decision fields read')
local Scope = require 'LrProgressScope'
Scope._reset(); Scope._cancelAfter = 1
local cancelled, why = Report.catalogDecisions(catalog, Scope { title = 't' })
t.isNil(cancelled, 'cancel stops the read'); t.eq(why, 'cancelled', '... and says so')
Scope._reset()

return t
