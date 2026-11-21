--[[
Tests for GrMetadata: the model's inputs read from the user's keywords (ADR-023, ADR-024),
and the plugin fields it writes.
]]

local t = require 'harness'
local Metadata = require 'GrMetadata'
local Taxonomy = require 'GrTaxonomy'
local Photo = require 'photo'

local G = Taxonomy.genres
local F = Metadata.FIELDS

t.suite('GrMetadata — the model\'s inputs come from the user\'s keywords')

local PERSONAL = require('GrConfig').keywordPath('#PERSONAL')
local tagged = Photo.new { keywords = { 'Iceland' },
                           keywordPaths = { '#PERSONAL', 'Genre > ' .. G[3], 'Genre > ' .. G[1],
                                            'Genre > Wedding', 'Travel > ' .. G[2] } }
local inp = Metadata.inputsOf(tagged, PERSONAL)
t.eq(inp.personal, true, 'the Personal keyword itself marks the photograph personal')
t.eq(inp.preTags, { G[1], G[3] }, 'Genre > X keywords of the taxonomy are pre-tags, in taxonomy order')

local nested = Photo.new { keywordPaths = { '#PERSONAL > Family > Anna' } }
t.eq(Metadata.inputsOf(nested, PERSONAL).personal, true, 'a keyword nested under it does too (ADR-024)')
local person = Photo.new { keywords = { 'Anna' }, personKeywords = { 'Anna' } }
t.eq(Metadata.inputsOf(person, PERSONAL).personal, false, 'a person keyword outside it does not')
local elsewhere = Photo.new { keywordPaths = { 'Archive > #PERSONAL' } }
t.eq(Metadata.inputsOf(elsewhere, PERSONAL).personal, false, 'the same name elsewhere in the tree does not')
local custom = Photo.new { keywordPaths = { 'Me > Personal > Trips' } }
t.eq(Metadata.inputsOf(custom, require('GrConfig').keywordPath('Me > Personal')).personal, true,
     'a configured nested keyword works as a path')
t.eq(Metadata.inputsOf(Photo.new {}, PERSONAL), { personal = false, preTags = {} }, 'no keywords: not personal, no pre-tags')

t.suite('GrMetadata — whose genre keywords they are (ADR-023)')

local U = Metadata.userTags
t.eq(U({ G[1], G[3] }, {}), { preTags = { G[1], G[3] }, userGenres = { G[1], G[3] }, laterUserGenres = {} },
     'first suggestion: the genre keywords present are the user\'s pre-tags')
t.eq(U({ G[1], G[3] }, { aiGenre = G[2], userGenres = G[1] }),
     { preTags = { G[1], G[3] }, userGenres = { G[1] }, laterUserGenres = { G[3] } },
     'reclassified: the pre-tags stay as recorded; one added since is a later user genre')
t.eq(U({ G[2], G[4] }, { aiGenre = G[2], userGenres = '', reviewState = 'accepted', humanGenres = G[2] .. ', ' .. G[4] }),
     { preTags = {}, userGenres = {}, laterUserGenres = {} },
     'a decided photograph\'s genres are the plugin\'s decision, not pre-tags')
t.eq(U({ G[2], G[4] }, { aiGenre = G[2], userGenres = G[4], reviewState = 'corrected', humanGenres = G[2] .. ', ' .. G[4] }).preTags,
     { G[4] }, 'a pre-tag the decision kept is still the user\'s')
t.eq(U({ G[2], G[5] }, { aiGenre = '', reviewState = 'accepted', humanGenres = G[2] }).userGenres, { G[5] },
     'an approved photograph never suggested: only a hand-added genre is the user\'s')
local kept = { aiGenre = G[3], userGenres = G[1], laterUserGenres = G[2], reviewState = 'accepted',
               humanGenres = G[3] .. ', ' .. G[1] .. ', ' .. G[2] }
t.eq(U({ G[1], G[2], G[3] }, kept), { preTags = { G[1], G[2] }, userGenres = { G[1] }, laterUserGenres = { G[2] } },
     'a later genre a decision kept stays the user\'s on reclassification, and stays recorded')
t.eq(U({ G[1], G[2], G[3], G[4] }, kept).laterUserGenres, { G[2], G[4] },
     'another genre added after that decision joins it, the earlier one kept')

t.suite('GrMetadata — review state')

local fresh = Photo.new {}
t.eq(Metadata.reviewState(fresh), 'unclassified', 'a fresh photo is unclassified')
t.ok(not Metadata.isClassified(fresh), 'a fresh photo is not classified')
t.ok(Metadata.isClassified(Photo.new { plugin = { reviewState = 'suggested' } }), 'a suggested photo counts as classified')
t.eq(Metadata.reviewState(Photo.new { plugin = { reviewState = '' } }), 'unclassified', 'an empty state reads as unclassified')
t.ok(Metadata.isDecided(Photo.new { plugin = { reviewState = 'corrected' } }), 'a corrected photo is decided')
t.ok(not Metadata.isDecided(Photo.new { plugin = { reviewState = 'suggested' } }), 'a suggestion is not a decision')

t.suite('GrMetadata — writing a suggestion')

local target = Photo.new {}
Metadata.writeSuggestion(target, { primary = G[1], genres = { G[1], G[4] }, ranking = 'Abc* Def',
                                   userGenres = { G[4] } },
                         { runId = 'r-test-0001', model = 'm1', modelVersion = 'v1' })
t.eq(target._plugin[F.reviewState], 'suggested', 'state: suggested')
t.eq(target._plugin[F.aiGenre], G[1], 'the suggested primary')
t.eq(target._plugin[F.aiGenres], G[1] .. ', ' .. G[4], 'the suggested genres, in priority order')
t.eq(target._plugin[F.aiRanking], 'Abc* Def', 'the ranking')
t.eq(target._plugin[F.userGenres], G[4], 'the user\'s pre-tags')
t.eq(target._plugin[F.reviewGenre], G[1], 'review starts from the suggested primary')
t.eq(target._plugin[F.reviewGenres], G[1] .. ', ' .. G[4], 'and the suggested genres')
t.eq(target._plugin[F.model], 'm1', 'the model id')
t.eq(target._plugin[F.modelVersion], 'v1', 'the model version')
t.eq(target._plugin[F.runId], 'r-test-0001', 'the run id')
t.ok(target._plugin[F.classifiedAt]:match('^%d%d%d%d%-%d%d%-%d%d'), 'an ISO timestamp')
t.ok(target._plugin[F.humanGenre] == nil, 'a suggestion does not set humanGenre (ADR-002)')
for key, value in pairs(target._plugin) do
  t.eq(type(value), 'string', 'stored value is a string: ' .. key)
end

local nothing = Photo.new {}
Metadata.writeSuggestion(nothing, { primary = Taxonomy.NO_GENRE, genres = {} }, {})
t.eq(nothing._plugin[F.aiGenre], Taxonomy.NO_GENRE, 'a No genre suggestion is stored as No genre')
t.eq(nothing._plugin[F.reviewGenres], '', 'with no genres')

local decided = Photo.new { plugin = { reviewState = 'accepted' } }
Metadata.writeSuggestion(decided, { primary = G[2], genres = { G[2] } }, {})
t.eq(decided._plugin[F.reviewState], 'accepted', 'reclassifying keeps a decision (R2.7)')

local errored = Photo.new {}
Metadata.writeError(errored, 'model_error', 'unreadable', { runId = 'r-test-0002' })
t.eq(errored._plugin[F.reviewState], 'error', 'an error sets state error')
t.contains(errored._plugin[F.errorText], 'model_error', 'with the code')

t.suite('GrMetadata — decisions and clear')

local d = Photo.new {}
Metadata.writeDecision(d, { state = 'accepted', primary = G[1], genres = { G[1] } })
t.eq(d._plugin[F.decisionSource], 'review', 'a decision is from review unless said otherwise')
Metadata.writeDecision(d, { state = 'accepted', primary = G[1], genres = { G[1] }, source = 'approved:v2' })
t.eq(d._plugin[F.decisionSource], 'approved:v2', 'an approved file\'s decision says so')

local dirty = Photo.new { plugin = { reviewState = 'accepted', aiGenre = G[1], humanGenre = G[1],
                                     primaryGenre = G[1], runId = 'r-old', keywordState = 'verified',
                                     keywordDecided = 'v1|verified|T|a' } }
Metadata.clear(dirty)
t.eq(dirty._plugin[F.reviewState], 'unclassified', 'clear resets the review state')
t.eq(dirty._plugin[F.aiGenre], '', 'clear empties the suggestion')
t.eq(dirty._plugin[F.humanGenre], '', 'clear empties the decision')
t.eq(dirty._plugin[F.primaryGenre], G[1], 'clear leaves the genre fields, as it leaves the keywords')
t.eq({ dirty._plugin[F.keywordState], dirty._plugin[F.keywordDecided] }, { '', '' },
     'clear blanks the keyword review and its record, leaving the keywords (ADR-030)')

return t
