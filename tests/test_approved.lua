--[[
Tests for GrApproved and Apply Approved Genres… (ADR-025): a file of approved genres becomes
decided photographs, matched by UUID and file name, never guessed; applying it again changes
nothing, and a changed file updates exactly what changed.
]]

local t = require 'harness'
local Approved = require 'GrApproved'
local Json = require 'GrJson'
local Metadata = require 'GrMetadata'
local Taxonomy = require 'GrTaxonomy'

local Photo         = require 'photo'
local LrApplication = require 'LrApplication'
local LrDialogs     = require 'LrDialogs'

local F = Metadata.FIELDS
local G = Taxonomy.genres
local NO = Taxonomy.NO_GENRE

local function file(items, version)
  return Json.encode { schema_version = 1, taxonomy_version = version or Taxonomy.version,
                       count = #items, items = Json.array(items) }
end
local function item(uuid, base, primary, genres)
  return { photo_uuid = uuid, file_base = base, primary = primary == nil and Json.null or primary,
           genres = Json.array(genres or {}) }
end

t.suite('GrApproved — reading the file: invalid items are listed, never guessed')

local parsed = assert(Approved.parse(file {
  item('U1', 'a', G[1], { G[1], G[2] }),
  item('U2', 'b', nil, {}),
  item('U3', 'c', 'Wedding', { 'Wedding' }),
  item('U4', 'd', nil, { G[1] }),
  item('U5', 'e', G[3], { G[1] }),
  { photo_uuid = 'U6' },
}))
t.eq(#parsed.items, 2, 'two good items')
t.eq(parsed.items[1], { uuid = 'U1', fileBase = 'a', primary = G[1], genres = { G[1], G[2] } }, 'a primary with its genres')
t.eq(parsed.items[2].primary, NO, 'primary null with no genres is No genre')
t.eq(#parsed.invalid, 4, 'four invalid items reported')
t.contains(parsed.invalid[1], 'not a genre', 'a genre outside the taxonomy')
t.contains(parsed.invalid[2], 'genres without a primary', 'genres without a primary')
t.contains(parsed.invalid[3], 'not among its genres', 'a primary missing from its genres')
t.contains(parsed.invalid[4], 'missing', 'an incomplete item')
t.ok(parsed.source:match('^approved:%x+$') ~= nil, 'the source names the file by fingerprint')

local none, why = Approved.parse(file({}, 'other-taxonomy'))
t.ok(none == nil and why:find('taxonomy') ~= nil, 'a file for another taxonomy is refused whole')
none = Approved.parse('not json')
t.isNil(none, 'a file that is not JSON is refused')

t.eq(Approved.fileBase('DSC_0042.NEF'), 'DSC_0042', 'file name without extension')
t.eq(Approved.fileBase('011208-00499.jpg'), '011208-00499', 'with dashes')

t.suite('GrApproved — the decision')

local it = parsed.items[1]
local d = Approved.decision({}, it, 'approved:x')
t.eq(d, { state = 'accepted', primary = G[1], genres = { G[1], G[2] }, source = 'approved:x' },
     'accepted, with the approved primary and genres, and the source')
d = Approved.decision({}, parsed.items[2], 'approved:x')
t.eq({ d.primary, #d.genres }, { NO, 0 }, 'No genre takes no genres')
local applied = { reviewState = 'accepted', humanGenre = G[1], humanGenres = G[1] .. ', ' .. G[2],
                  primaryGenre = G[1], decisionSource = 'approved:x' }
local again, reason = Approved.decision(applied, it, 'approved:x')
t.ok(again == nil and reason == 'already applied', 'the same file again changes nothing')
t.ok(Approved.decision(applied, it, 'approved:y') ~= nil, 'a newer file applies again')

t.suite('Apply Approved Genres… — end to end against the catalog stub')

local TMP = '/tmp/genreator-approved'
os.execute('rm -rf ' .. TMP .. ' && mkdir -p ' .. TMP)
local path = TMP .. '/approved.json'
local function writeFile(text)
  local fh = assert(io.open(path, 'w')); fh:write(text); fh:close()
end

local pre = Photo.new { raw = { uuid = 'U1' }, formatted = { fileName = 'a.NEF' },
                        keywordPaths = { 'Genre > ' .. G[5], '#PERSONAL > Family' },
                        plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = G[5] } }
local plain = Photo.new { raw = { uuid = 'U2' }, formatted = { fileName = 'b.jpg' } }
local renamed = Photo.new { raw = { uuid = 'U7' }, formatted = { fileName = 'other.jpg' } }
local catalog = LrApplication._fakeCatalog {}
catalog._all = { pre, plain, renamed }
LrApplication._setCatalog(catalog)

writeFile(file { item('U1', 'a', G[1], { G[1], G[2] }), item('U2', 'b', nil, {}),
                 item('U7', 'g', G[1], { G[1] }), item('U9', 'z', G[1], { G[1] }),
                 item('U1', 'a', G[3], { G[3] }) })
LrDialogs._reset()
LrDialogs._openPanel = { path }
dofile((arg[0]:match('^(.*)/[^/]*$') or '.') .. '/../Genreator.lrplugin/GrMenuApplyApproved.lua')

t.contains(LrDialogs._confirms[1].title, 'Apply approved genres to 2 photographs', 'confirms with the count')
t.contains(LrDialogs._confirms[1].body, 'Skipped 1: file name does not match', 'a renamed photograph is skipped')
t.contains(LrDialogs._confirms[1].body, 'Skipped 1: not in this catalog', 'an unknown UUID is skipped')
t.contains(LrDialogs._confirms[1].body, 'Skipped 1: listed twice', 'a UUID listed twice is applied once')
t.contains(LrDialogs._confirms[1].body, 'pause sync first', 'the confirmation reminds to pause sync')
t.eq({ pre._plugin[F.reviewState], pre._plugin[F.primaryGenre], pre._plugin[F.secondaryGenres] },
     { 'accepted', G[1], G[2] }, 'a matched photograph is decided with the approved genres')
local want = { 'Genre > ' .. G[1], 'Genre > ' .. G[2], '#PERSONAL > Family' }
table.sort(want)
t.eq(pre:_keywordPaths(), want,
     'its genre keywords are replaced (the pre-tag included); other keywords stay')
t.ok(pre._plugin[F.decisionSource]:match('^approved:') ~= nil, 'the source is recorded')
t.eq(pre._plugin[F.decisionModelVersion], '', 'an approved decision answered no model version')
t.eq(pre._plugin[F.decisionPersonal], '', '... and is not marked personal or not: the flag is a review decision\'s (ADR-028)')
t.eq({ plain._plugin[F.reviewState], plain._plugin[F.primaryGenre] }, { 'accepted', NO },
     'No genre is recorded, filterable')
t.ok(renamed._plugin[F.reviewState] == nil, 'the renamed photograph is untouched')
t.contains(LrDialogs._allText(), 'Applied: 2', 'the summary counts them')

LrDialogs._reset()
LrDialogs._openPanel = { path }
dofile((arg[0]:match('^(.*)/[^/]*$') or '.') .. '/../Genreator.lrplugin/GrMenuApplyApproved.lua')
t.contains(LrDialogs._allText(), 'Applied: 0', 'applying the same file again changes nothing')
t.contains(LrDialogs._allText(), 'already applied', 'and says why')

writeFile(file { item('U1', 'a', G[2], { G[2] }), item('U2', 'b', nil, {}) })
LrDialogs._reset()
LrDialogs._openPanel = { path }
dofile((arg[0]:match('^(.*)/[^/]*$') or '.') .. '/../Genreator.lrplugin/GrMenuApplyApproved.lua')
t.eq({ pre._plugin[F.primaryGenre], pre:_keywordPaths() }, { G[2], { '#PERSONAL > Family', 'Genre > ' .. G[2] } },
     'a changed judgement in a newer file is applied')

LrDialogs._reset()
LrDialogs._openPanel = nil
LrApplication._setCatalog(nil)
os.execute('rm -rf ' .. TMP)

return t
