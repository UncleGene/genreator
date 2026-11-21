--[[
GrCollections — the review smart collections (M3, R6.8): grid review by exception, so a
catalog-sized batch can be reviewed without reading each photo's metadata.

Lightroom lists a set's sub-sets first, then its collections, each kind sorted by name. The
two review steps and their grids are named for the order of the work (ADR-027); the overview
collections keep plain names, their alphabetical order being fine:

  Genreator/
    Step 1 · Genres/              one grid per genre anywhere in the suggestion, for removing
                                  the genres that do not belong (Remove Genre)
    Step 2 · Primary/             one grid per suggested Primary Genre (+ No genre), for Set
                                  Primary Genre… on the odd ones out
    Awaiting Review               every undecided suggestion; Accept here, once, at the end
    Errors
    Not Classified                where the next batch comes from
    Personal Candidates           personal photographs awaiting review that still have a genre:
                                  under the personal floor (ADR-028), the real genre candidates;
                                  emptied by review, like the grids
    Suggested Keywords/           the keyword review (ADR-030): photographs whose suggested
                                  keywords await Mark Keywords Verified, and keyword errors
    Suggested Rating/             one grid per rating bucket (ADR-029)

A grid's name is its number and genre only ('1 Object'): the panel is narrow, and the set
says what the grid is for. Remove Genre therefore knows a genre grid by its set.

Step 2's grids follow the taxonomy order, which is the order the user's decisions rank the
genres in when two apply (the fallback sequence), with No genre last. Step 1's grids are the
reverse: the genres most often suggested wrongly come first, and the ones that easily pass for
each other (things and places, then people) sit together. Both orders come from the model's
taxonomy file, never from code (ADR-012).

Plugin fields are searchable (GenreatorMetadata.lua). The criteria syntax is not in the SDK
reference; it was read from smart collections built by hand in Lightroom:
  is        { criteria = "sdk:<plugin id>.<field>",     operation = "==",  value = v }
  contains  { criteria = "sdktext:<plugin id>.<field>", operation = "any", value = v, value2 = "" }
  is empty  { criteria = "sdk:<plugin id>.<field>",     operation = "==" }   (no value)
"sdk:" with "any" matches nothing (the first genre grids showed 0).

Pure: the names, specs, genreOfGrid, sourceLabel, isOwnRule. Lightroom-bound: setUp,
removeStale, activeSource, activeGrid.
]]

local Metadata = require 'GrMetadata'
local Taxonomy = require 'GrTaxonomy'

local Collections = {}

Collections.SET_NAME       = 'Genreator'
Collections.GENRE_SET      = 'Step 1 · Genres'
Collections.PRIMARY_SET    = 'Step 2 · Primary'
Collections.NOT_CLASSIFIED = 'Not Classified'
Collections.AWAITING       = 'Awaiting Review'
Collections.ERRORS         = 'Errors'
Collections.PERSONAL       = 'Personal Candidates'
Collections.RATING_SET     = 'Suggested Rating'
-- The keyword review (ADR-030). The set sorts before Suggested Rating, the grid before errors.
Collections.KEYWORD_SET    = 'Suggested Keywords'
Collections.KEYWORDS_TO_VERIFY = '1 Keywords to Verify'
Collections.KEYWORD_ERRORS = '2 Keyword Errors'
-- One grid per bucket (ADR-029), named in the order of the work: candidates for 3 stars first.
Collections.RATING_GRIDS   = { { '3', '1 Candidates for 3★' }, { '2', '2 Maybe 2★' },
                               { '1', '3 Maybe 1★' }, { '0', '4 Likely 0★' } }

--- Pure: the genre grids' genres in display order: the taxonomy reversed (step 1).
function Collections.genreOrder()
  local out = {}
  for i = #Taxonomy.genres, 1, -1 do out[#out + 1] = Taxonomy.genres[i] end
  return out
end

--- Pure: the primary grids' genres in display order: the taxonomy, then No genre (step 2).
function Collections.primaryOrder()
  local out = {}
  for _, g in ipairs(Taxonomy.genres) do out[#out + 1] = g end
  out[#out + 1] = Taxonomy.NO_GENRE
  return out
end

-- Numbers padded to one width, so "10" does not sort before "2" with a larger taxonomy.
local function numbered(i, count, label)
  return string.format('%0' .. #tostring(count) .. 'd %s', i, label)
end

--- Pure: the genre a genre grid is for, from the collection's name and its set's
-- ('8 Street' in GENRE_SET -> 'Street'); nil for any other source. Lets Remove Genre act
-- without a dialog.
function Collections.genreOfGrid(name, setName)
  if setName ~= Collections.GENRE_SET then return nil end
  local g = type(name) == 'string' and name:match('^%d+ (.+)$') or nil
  if g and Taxonomy.isGenre(g) then return g end
  return nil
end

local function is(pluginId, field, value)
  return { criteria = 'sdk:' .. pluginId .. '.' .. field, operation = '==', value = value }
end

local function contains(pluginId, field, value)
  return { criteria = 'sdktext:' .. pluginId .. '.' .. field, operation = 'any', value = value, value2 = '' }
end

--- Pure: is every criterion of a smart collection's rule one of this plugin's fields? Only
-- such a collection is the plugin's to remove when its name is no longer current.
function Collections.isOwnRule(searchDesc, pluginId)
  if type(searchDesc) ~= 'table' or #searchDesc == 0 then return false end
  for _, c in ipairs(searchDesc) do
    local crit = type(c) == 'table' and c.criteria
    if type(crit) ~= 'string' then return false end
    local prefix = crit:match('^(sdk%w*:)')
    if not prefix or crit:sub(#prefix + 1, #prefix + #pluginId + 1) ~= pluginId .. '.' then return false end
  end
  return true
end

--- Pure: the collections to create, as { set = nil | GENRE_SET | PRIMARY_SET, name, searchDesc }
-- in display order. `set == nil` means directly in the Genreator set.
function Collections.specs(pluginId)
  local F, S = Metadata.FIELDS, Metadata.STATE
  local suggested = is(pluginId, F.reviewState, S.suggested)
  local out = {
    -- Where the next batch comes from: never touched by the plugin (no review state at all)
    -- or reset by Clear Plugin Data. Classify skips finished photographs and retries
    -- errors, so classifying from here again continues an interrupted run.
    { name = Collections.NOT_CLASSIFIED,
      searchDesc = { { criteria = 'sdk:' .. pluginId .. '.' .. F.reviewState, operation = '==' },
                     is(pluginId, F.reviewState, S.unclassified), combine = 'union' } },
    { name = Collections.AWAITING,
      searchDesc = { suggested, combine = 'intersect' } },
  }
  local genres = Collections.genreOrder()
  for i, g in ipairs(genres) do
    -- reviewGenres is "Street, Portrait" — the list under review, so Remove Genre takes a
    -- photograph out of the grid at once (R6.9). Genre names are single distinct words,
    -- so a word match cannot confuse two genres.
    out[#out + 1] = { set = Collections.GENRE_SET, name = numbered(i, #genres, g),
      searchDesc = { suggested, contains(pluginId, F.reviewGenres, g), combine = 'intersect' } }
  end
  local primaries = Collections.primaryOrder()
  for i, g in ipairs(primaries) do
    out[#out + 1] = { set = Collections.PRIMARY_SET, name = numbered(i, #primaries, g),
      searchDesc = { suggested, is(pluginId, F.reviewGenre, g), combine = 'intersect' } }
  end
  out[#out + 1] = { name = Collections.ERRORS,
    searchDesc = { is(pluginId, F.reviewState, S.error), combine = 'intersect' } }
  -- Personal photographs awaiting review that still have a genre (ADR-028): a staging grid,
  -- emptied by deciding them or removing their last genre. "Contains" matches any of the
  -- words, and genre names are single words, so No genre does not match.
  out[#out + 1] = { name = Collections.PERSONAL,
    searchDesc = { suggested, is(pluginId, F.personal, Metadata.YES),
                   contains(pluginId, F.reviewGenres, table.concat(Taxonomy.genres, ' ')),
                   combine = 'intersect' } }
  -- The suggested rating's buckets (ADR-029), whatever the review state: where a rating
  -- round starts (candidates first) and what to look at last (likely 0 stars).
  for _, grid in ipairs(Collections.RATING_GRIDS) do
    out[#out + 1] = { set = Collections.RATING_SET, name = grid[2],
      searchDesc = { is(pluginId, F.ratingBucket, grid[1]), combine = 'intersect' } }
  end
  -- The keyword review (ADR-030): vetted in the first grid, then Mark Keywords Verified.
  local KS = Metadata.KEYWORD_STATE
  out[#out + 1] = { set = Collections.KEYWORD_SET, name = Collections.KEYWORDS_TO_VERIFY,
    searchDesc = { is(pluginId, F.keywordState, KS.suggested), combine = 'intersect' } }
  out[#out + 1] = { set = Collections.KEYWORD_SET, name = Collections.KEYWORD_ERRORS,
    searchDesc = { is(pluginId, F.keywordState, KS.error), combine = 'intersect' } }
  return out
end

-- ------------------------------------------------------------ Lightroom-bound

local function gate(catalog, title, fn)
  local ok, err = (import 'LrTasks').pcall(function()
    catalog:withWriteAccessDo(title, fn, { timeout = 30 })
  end)
  if not ok then error(title .. ' failed: ' .. tostring(err), 0) end
end

--- Create the sets and collections. Existing ones are reused (canReturnPrior) and their
-- search rules rewritten, so running it again adds what is missing (e.g. after a taxonomy
-- change) and repairs a collection whose rule changed in a plugin update.
-- Each level gets its own write gate: a set is created before anything goes inside it, as
-- with keywords (Lightroom rejects using some objects in the gate that created them).
-- @param onlySet optional: set up only this sub-set's collections (the keyword commands make
--        sure of theirs, ADR-030), and remove nothing
-- @return list of collection names
function Collections.setUp(catalog, pluginId, onlySet)
  local top, sets = nil, {}
  gate(catalog, 'Genreator: review collections (set)', function()
    top = catalog:createCollectionSet(Collections.SET_NAME, nil, true)
  end)
  if not top then error('could not create the collection set ' .. Collections.SET_NAME, 0) end
  gate(catalog, 'Genreator: review collections (sub-sets)', function()
    for _, name in ipairs { Collections.PRIMARY_SET, Collections.GENRE_SET, Collections.RATING_SET,
                            Collections.KEYWORD_SET } do
      if not onlySet or name == onlySet then
        sets[name] = catalog:createCollectionSet(name, top, true)
        if not sets[name] then error('could not create the collection set ' .. name, 0) end
      end
    end
  end)
  local specs, names, current = {}, {}, {}
  for _, spec in ipairs(Collections.specs(pluginId)) do
    if not onlySet or spec.set == onlySet then specs[#specs + 1] = spec end
    current[(spec.set or '') .. '/' .. spec.name] = true
  end
  gate(catalog, 'Genreator: review collections', function()
    for _, spec in ipairs(specs) do
      local c = catalog:createSmartCollection(spec.name, spec.searchDesc, spec.set and sets[spec.set] or top, true)
      if not c then error('could not create the collection ' .. spec.name, 0) end
      c:setSearchDescription(spec.searchDesc)
      names[#names + 1] = spec.set and (spec.set .. ' / ' .. spec.name) or spec.name
    end
  end)
  if not onlySet then Collections.removeStale(catalog, top, pluginId, current) end
  return names
end

-- The children of a set, or nil when Lightroom cannot list them (a catalog read).
local function children(set)
  local LrTasks = import 'LrTasks'
  local ok, sets, colls = LrTasks.pcall(function()
    return set:getChildCollectionSets() or {}, set:getChildCollections() or {}
  end)
  if not ok then return nil end
  return sets, colls
end

--- Remove what an earlier plugin version set up and this one no longer does: a smart
-- collection in the Genreator set (or a set directly in it) whose name is not current and
-- whose rule searches only the plugin's fields — the names of an earlier layout, or a
-- grid of a genre a new model dropped. A set this leaves empty goes too. A collection the
-- user made or put there is never touched. Best effort: if Lightroom cannot list or delete,
-- the old collections stay and the new ones work beside them.
function Collections.removeStale(catalog, top, pluginId, current)
  local LrTasks = import 'LrTasks'
  local stale, emptied = {}, {}
  local function scan(set, setName, isCurrentSet)
    local sets, colls = children(set)
    if not sets then return false end
    local kept, removed = #sets, 0
    for _, c in ipairs(colls) do
      local ok, own = LrTasks.pcall(function()
        return c:isSmartCollection() and not current[setName .. '/' .. c:getName()]
               and Collections.isOwnRule(c:getSearchDescription(), pluginId)
      end)
      if ok and own then stale[#stale + 1] = c; removed = removed + 1 else kept = kept + 1 end
    end
    -- Only a set this clean-up empties: an empty set of the user's own stays.
    return kept == 0 and removed > 0 and not isCurrentSet
  end
  local sets = children(top)
  if not sets then return 0 end
  scan(top, '', true)
  for _, set in ipairs(sets) do
    local okName, name = LrTasks.pcall(function() return set:getName() end)
    if okName then
      local isCurrent = name == Collections.GENRE_SET or name == Collections.PRIMARY_SET
      if scan(set, name, isCurrent) then emptied[#emptied + 1] = set end
    end
  end
  if #stale == 0 and #emptied == 0 then return 0 end
  local ok = LrTasks.pcall(function()
    catalog:withWriteAccessDo('Genreator: remove old review collections', function()
      for _, c in ipairs(stale) do c:delete() end
      for _, set in ipairs(emptied) do set:delete() end
    end, { timeout = 30 })
  end)
  if not ok then
    require('GrLog').warnf('could not remove %d old review collections', #stale)
    return 0
  end
  return #stale
end

--- The one source the user is looking at (a collection, folder or set): its name and its
-- parent set's name; nil when there are several, or a special source such as All
-- Photographs. Names are catalog reads, hence LrTasks.pcall.
function Collections.activeSource(catalog)
  local LrTasks = import 'LrTasks'
  local ok, sources = LrTasks.pcall(function() return catalog:getActiveSources() end)
  if not ok or type(sources) ~= 'table' or #sources ~= 1 then return nil end
  local src = sources[1]
  if type(src) ~= 'table' or type(src.getName) ~= 'function' then return nil end
  local okName, name = LrTasks.pcall(function() return src:getName() end)
  if not okName then return nil end
  local okParent, parent = LrTasks.pcall(function()
    local p = type(src.getParent) == 'function' and src:getParent() or nil
    return p and p:getName() or nil
  end)
  return name, okParent and parent or nil
end

--- Pure: how the review trail names a source: 'Step 1 · Genres/1 Object', or the name alone.
function Collections.sourceLabel(name, setName)
  if not name then return nil end
  return setName and (setName .. '/' .. name) or name
end

--- The genre of the grid the user is looking at, or nil when the active source is not
-- exactly one genre grid.
function Collections.activeGrid(catalog)
  return Collections.genreOfGrid(Collections.activeSource(catalog))
end

return Collections
