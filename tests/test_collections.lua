--[[ Tests for GrCollections — the review smart collections (M3). ]]

local t = require 'harness'
local Collections = require 'GrCollections'
local LrApplication = require 'LrApplication'

local ID = 'com.genreator.lightroom'

t.suite('GrCollections — smart collection definitions')

local specs = Collections.specs(ID)
local byName = {}
-- Keyed by set and name: '1 Object' is a grid in each set.
for _, s in ipairs(specs) do byName[(s.set or '') .. '/' .. s.name] = s.searchDesc end

-- The exact shape Lightroom stored for a hand-made collection.
t.eq(byName['/' .. Collections.AWAITING],
     { { criteria = 'sdk:com.genreator.lightroom.reviewState', operation = '==', value = 'suggested' },
       combine = 'intersect' }, 'awaiting review = state suggested, in Lightroom\'s own syntax')
-- "is empty" as Lightroom stored it for a hand-made collection.
t.eq(byName['/' .. Collections.NOT_CLASSIFIED],
     { { criteria = 'sdk:com.genreator.lightroom.reviewState', operation = '==' },
       { criteria = 'sdk:com.genreator.lightroom.reviewState', operation = '==', value = 'unclassified' },
       combine = 'union' }, 'not classified = no review state, or reset to unclassified')
t.eq(byName['/' .. Collections.ERRORS][1].value, 'error', 'errors collection')

-- Lightroom lists sub-sets first, then collections, each by name (seen 2026-11-02): each
-- kind's names put it in the order of the work (ADR-027).
local top = {}
for _, sp in ipairs(specs) do if not sp.set then top[#top + 1] = sp.name end end
table.sort(top)
t.eq(top, { 'Awaiting Review', 'Errors', 'Not Classified', 'Personal Candidates' },
     'the overview collections keep plain names')
local sets = { Collections.PRIMARY_SET, Collections.RATING_SET, Collections.GENRE_SET, Collections.KEYWORD_SET }
table.sort(sets)
t.eq(sets, { Collections.GENRE_SET, Collections.PRIMARY_SET, Collections.KEYWORD_SET, Collections.RATING_SET },
     '... and the sets: step 1, step 2, then the suggested keywords and rating')
-- The keyword review (ADR-030): the grid to vet, then the errors.
t.eq(byName[Collections.KEYWORD_SET .. '/' .. Collections.KEYWORDS_TO_VERIFY],
     { { criteria = 'sdk:com.genreator.lightroom.keywordState', operation = '==', value = 'suggested' }, combine = 'intersect' },
     'Keywords to Verify searches the suggested keyword state')
t.eq(byName[Collections.KEYWORD_SET .. '/' .. Collections.KEYWORD_ERRORS][1].value, 'error', '... and the errors grid its error')
local inKeywordSet = {}
for _, sp in ipairs(specs) do if sp.set == Collections.KEYWORD_SET then inKeywordSet[#inKeywordSet + 1] = sp.name end end
table.sort(inKeywordSet)
t.eq(inKeywordSet, { Collections.KEYWORDS_TO_VERIFY, Collections.KEYWORD_ERRORS }, '... in that order')
-- The rating grids (ADR-029): one per bucket, candidates first, whatever the review state.
t.eq(byName[Collections.RATING_SET .. '/1 Candidates for 3★'],
     { { criteria = 'sdk:com.genreator.lightroom.ratingBucket', operation = '==', value = '3' }, combine = 'intersect' },
     'the candidates grid searches bucket 3 alone')
t.eq(byName[Collections.RATING_SET .. '/4 Likely 0★'][1].value, '0', 'the last grid is the likely-0-star bucket')

local Taxonomy = require 'GrTaxonomy'
local primaries, genres = 0, 0
for _, sp in ipairs(specs) do
  if sp.set == Collections.PRIMARY_SET then primaries = primaries + 1 end
  if sp.set == Collections.GENRE_SET then genres = genres + 1 end
end
t.eq(primaries, #Taxonomy.genres + 1, 'one primary grid per genre, plus No genre')
t.eq(genres, #Taxonomy.genres, 'one genre grid per genre')
local G = Taxonomy.genres
local g1 = G[1]
local function grids(set)
  local out = {}
  for _, sp in ipairs(specs) do if sp.set == set then out[#out + 1] = sp.name end end
  return out
end
local sorted = function(list) local c = {} for i, v in ipairs(list) do c[i] = v end table.sort(c) return c end
local primaryGrids, genreGrids = grids(Collections.PRIMARY_SET), grids(Collections.GENRE_SET)
t.eq(primaryGrids[1], '1 ' .. G[1], 'step 2 starts with the first genre of the taxonomy')
t.eq(primaryGrids[#G], #G .. ' ' .. G[#G], '... and follows the taxonomy order')
t.eq(primaryGrids[#G + 1], (#G + 1) .. ' ' .. Taxonomy.NO_GENRE, 'No genre is the last fallback')
t.eq(genreGrids[1], '1 ' .. G[#G], 'step 1 is the taxonomy reversed: the last genre first')
t.eq(genreGrids[#G], #G .. ' ' .. G[1], '... the first genre last')
t.eq(sorted(primaryGrids), primaryGrids, 'Lightroom\'s name order is the display order (primary grids)')
t.eq(sorted(genreGrids), genreGrids, '... and the genre grids')
local P1 = '1 ' .. g1
t.eq(byName[Collections.PRIMARY_SET .. '/' .. P1],
     { { criteria = 'sdk:com.genreator.lightroom.reviewState', operation = '==', value = 'suggested' },
       { criteria = 'sdk:com.genreator.lightroom.reviewGenre', operation = '==', value = g1 },
       combine = 'intersect' }, 'primary grid: awaiting review AND the primary under review is the genre')
-- "contains" as Lightroom stored it for a hand-made collection;
-- "sdk:" with "any" matched nothing in Lightroom.
local GG1 = #G .. ' ' .. g1
t.eq(byName[Collections.GENRE_SET .. '/' .. GG1][2],
     { criteria = 'sdktext:com.genreator.lightroom.reviewGenres', operation = 'any', value = g1, value2 = '' },
     'genre grid: the list under review contains the genre (R6.9)')
t.eq(byName[Collections.PRIMARY_SET .. '/' .. (#G + 1) .. ' ' .. Taxonomy.NO_GENRE][2].value, Taxonomy.NO_GENRE, 'No genre has a primary grid (ADR-022)')

-- Personal photographs awaiting review that still have a genre (ADR-028): a staging grid that
-- review empties. Every genre name is a word of the "contains" value.
local anyGenre = table.concat(G, ' ')
t.eq(byName['/' .. Collections.PERSONAL],
     { { criteria = 'sdk:com.genreator.lightroom.reviewState', operation = '==', value = 'suggested' },
       { criteria = 'sdk:com.genreator.lightroom.personal', operation = '==', value = 'yes' },
       { criteria = 'sdktext:com.genreator.lightroom.reviewGenres', operation = 'any', value = anyGenre, value2 = '' },
       combine = 'intersect' },
     'personal candidates = awaiting review AND classified as personal AND a genre under review')
t.notContains(anyGenre, Taxonomy.NO_GENRE, 'No genre is not among the words, so it matches neither')

-- A field with searchable = false is not a smart-collection criterion, so a collection that
-- searches it would match nothing. The reverse holds too (schemaVersion 11): the criteria
-- list is the fields people filter on (FOR_PEOPLE) plus what these collections search, and the
-- Library filter is the single-valued ones of FOR_PEOPLE. Provenance stays in the Metadata panel.
-- The suggested rating's bucket is a single value people filter on too (ADR-029).
-- So is the keyword review state (ADR-030).
local FOR_PEOPLE = { reviewState = true, primaryGenre = true, secondaryGenres = true, ratingBucket = true,
                     keywordState = true }
local IN_FILTER  = { reviewState = true, primaryGenre = true, ratingBucket = true, keywordState = true }
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local searchable, browsable = {}, {}
for _, f in ipairs(dofile(here .. '/../Genreator.lrplugin/GenreatorMetadata.lua').metadataFieldsForPhotos) do
  searchable[f.id] = f.searchable == true
  browsable[f.id] = f.browsable == true
end
local used = {}
for _, sp in ipairs(specs) do
  for _, c in ipairs(sp.searchDesc) do
    local field = c.criteria:match('^sdk%w*:' .. ID:gsub('%.', '%%.') .. '%.(%w+)$')
    t.ok(field ~= nil, sp.name .. ': criterion is a plugin field (' .. c.criteria .. ')')
    if field then used[field] = true end
  end
end
for field in pairs(used) do
  t.ok(searchable[field], 'collections search ' .. field .. ', so it stays searchable')
end
t.ok(used.reviewState and used.reviewGenre and used.reviewGenres,
     'the check covers every field the collections search')
for field, on in pairs(searchable) do
  if on then t.ok(used[field] or FOR_PEOPLE[field], field .. ' is a criterion: filtered on, or searched by a review collection') end
end
for field, on in pairs(browsable) do
  if on then t.ok(IN_FILTER[field], field .. ' is in the Library filter only if it is a single-valued decision field') end
end
for field in pairs(FOR_PEOPLE) do
  t.ok(searchable[field], field .. ' is a smart-collection criterion (ADR-019)')
end
for field in pairs(IN_FILTER) do t.ok(browsable[field], field .. ' is in the Library filter') end

t.suite('GrCollections.setUp — against the catalog stub')

local catalog = LrApplication._fakeCatalog {}
local names = Collections.setUp(catalog, ID)
t.eq(#names, #specs, 'reports every collection')
local function find(kind, name, parent)
  for _, c in ipairs(catalog._collections) do
    if c.kind == kind and c.name == name and c.parent == parent then return c end
  end
end
local topSet = find('set', 'Genreator', nil)
t.ok(topSet ~= nil, 'a top-level Genreator set')
local ps = find('set', Collections.PRIMARY_SET, topSet)
local gs = find('set', Collections.GENRE_SET, topSet)
t.ok(ps ~= nil and gs ~= nil, 'both review sub-sets inside it')
t.ok(find('smart', Collections.AWAITING, topSet) ~= nil, 'overview collections directly in Genreator')
t.ok(find('smart', P1, ps) ~= nil, 'primary grids in their sub-set')
t.ok(find('smart', GG1, gs) ~= nil, 'genre grids in theirs')
t.eq(#catalog._writeTitles, 3, 'three write gates: set, sub-sets, collections')

local before = #catalog._collections
local stale = find('smart', GG1, gs)
stale.searchDesc = { { criteria = 'sdk:old', operation = 'any', value = g1 }, combine = 'intersect' }
Collections.setUp(catalog, ID)
t.eq(#catalog._collections, before, 'running again creates nothing new')
t.eq(stale.searchDesc[2].criteria, 'sdktext:com.genreator.lightroom.reviewGenres',
     '... and repairs an existing collection\'s rule')

t.suite('GrCollections.setUp — removes its own collections under old names')

-- A catalog set up by the version before ADR-027: un-numbered names, plus what the user added.
local ID_RULE = { { criteria = 'sdk:' .. ID .. '.reviewState', operation = '==', value = 'suggested' }, combine = 'intersect' }
local USER_RULE = { { criteria = 'rating', operation = '>=', value = 3 }, combine = 'intersect' }
local old = LrApplication._fakeCatalog {}
local oldTop, oldPrimary, userSet
old:withWriteAccessDo('old set-up', function()
  oldTop = old:createCollectionSet('Genreator', nil, true)
  old:createSmartCollection('Awaiting Review', ID_RULE, oldTop, true)
  oldPrimary = old:createCollectionSet('Review by Primary Genre', oldTop, true)
  old:createSmartCollection('Primary: ' .. g1, ID_RULE, oldPrimary, true)
  local oldGenre = old:createCollectionSet('Review by Genre', oldTop, true)
  old:createSmartCollection('Genre: ' .. g1, ID_RULE, oldGenre, true)
  -- The user's own: a smart collection with a foreign rule, a plain collection, a set.
  old:createSmartCollection('My best', USER_RULE, oldPrimary, true)
  old:createCollection('Keepers', oldTop, true)
  userSet = old:createCollectionSet('My set', oldTop, true)
end)
Collections.setUp(old, ID)
local function findIn(cat, kind, name, parent)
  for _, c in ipairs(cat._collections) do
    if c.kind == kind and c.name == name and c.parent == parent then return c end
  end
end
t.ok(findIn(old, 'smart', Collections.AWAITING, oldTop) ~= nil, 'an overview collection under its current name stays')
t.isNil(findIn(old, 'set', 'Review by Genre', oldTop), 'an old set emptied by the clean-up is removed')
t.ok(findIn(old, 'set', 'Review by Primary Genre', oldTop) ~= nil, 'an old set still holding the user\'s collection stays')
t.isNil(findIn(old, 'smart', 'Primary: ' .. g1, oldPrimary), '... though its old grid is gone')
t.ok(findIn(old, 'smart', 'My best', oldPrimary) ~= nil, 'a smart collection with the user\'s own rule stays')
t.ok(findIn(old, 'collection', 'Keepers', oldTop) ~= nil, 'a plain collection stays')
t.ok(findIn(old, 'set', 'My set', oldTop) ~= nil, 'an empty set that is not the plugin\'s old one stays... ')

-- The first numbered layout (2026-11-02): its sets and numbered collections go; a
-- collection whose name is current is kept.
local mid = LrApplication._fakeCatalog {}
local midTop
mid:withWriteAccessDo('numbered set-up', function()
  midTop = mid:createCollectionSet('Genreator', nil, true)
  mid:createSmartCollection('Awaiting Review', ID_RULE, midTop, true)
  mid:createSmartCollection('5 Errors', ID_RULE, midTop, true)
  mid:createSmartCollection('1 Not Classified', ID_RULE, midTop, true)
  local g = mid:createCollectionSet('3 Review by Genre', midTop, true)
  mid:createSmartCollection('1 Genre: ' .. G[#G], ID_RULE, g, true)
end)
local kept = findIn(mid, 'smart', 'Awaiting Review', midTop)
Collections.setUp(mid, ID)
t.ok(findIn(mid, 'smart', 'Awaiting Review', midTop) == kept, 'a current collection is kept as it is')
t.isNil(findIn(mid, 'smart', '5 Errors', midTop), 'an earlier numbering\'s collection is removed')
t.isNil(findIn(mid, 'smart', '1 Not Classified', midTop), '... each of them')
t.ok(findIn(mid, 'smart', 'Not Classified', midTop) ~= nil, '... replaced by the plain name')
t.isNil(findIn(mid, 'set', '3 Review by Genre', midTop), '... and its set')
t.ok(findIn(mid, 'smart', '1 ' .. G[#G], findIn(mid, 'set', Collections.GENRE_SET, midTop)) ~= nil,
     'the grid is in its new set')

t.ok(Collections.isOwnRule(ID_RULE, ID), 'a rule on the plugin\'s fields is its own')
t.ok(not Collections.isOwnRule(USER_RULE, ID), 'a rule on anything else is not')
t.ok(not Collections.isOwnRule({ ID_RULE[1], USER_RULE[1], combine = 'intersect' }, ID), 'nor a mixed one')
t.ok(not Collections.isOwnRule({ { criteria = 'sdk:' .. ID .. 'x.reviewState' } }, ID), 'nor another plugin\'s with a longer id')

t.suite('GrCollections — which genre grid is being viewed')

local GS, PS = Collections.GENRE_SET, Collections.PRIMARY_SET
t.eq(Collections.genreOfGrid(GG1, GS), g1, 'a grid in the genre set names its genre')
t.isNil(Collections.genreOfGrid(P1, PS), 'a primary grid is not a genre grid, though its name looks alike')
t.isNil(Collections.genreOfGrid(GG1, nil), 'a collection of that name outside the genre set is not one')
t.isNil(Collections.genreOfGrid('3 Genre: ' .. g1, '3 Review by Genre'), 'an old layout\'s grid is not one')
t.isNil(Collections.genreOfGrid('1 Abstract', GS), 'a name outside the taxonomy is ignored')
t.isNil(Collections.genreOfGrid(nil, GS), 'no name, no genre')
t.eq(Collections.sourceLabel(GG1, GS), GS .. '/' .. GG1, 'the trail names a grid with its set')
t.eq(Collections.sourceLabel('Trip', nil), 'Trip', '... and a top-level source by its name')
t.isNil(Collections.sourceLabel(nil, nil), '... and no source as nothing')

local function source(name, setName)
  return { getName = function() return name end,
           getParent = function() return setName and { getName = function() return setName end } or nil end }
end
catalog._sources = { source(GG1, GS) }
t.eq(Collections.activeGrid(catalog), g1, 'viewing one genre grid')
catalog._sources = { source(P1, PS) }
t.isNil(Collections.activeGrid(catalog), 'viewing a primary grid: no genre')
catalog._sources = { source(GG1, GS), source(genreGrids[1], GS) }
t.isNil(Collections.activeGrid(catalog), 'two sources: ambiguous, so no genre')
catalog._sources = { 'kAllPhotos' }
t.isNil(Collections.activeGrid(catalog), 'a special source string is not a grid')

return t
