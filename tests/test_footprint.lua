--[[
The plugin's footprint (R5.6, ADR-002, ADR-019): whatever a command does, it writes only its
own plugin fields, the `Genre > X` keywords of the taxonomy, the keywords at the keyword
taxonomy's paths (ADR-030), its own `Genreator` collections, and the Personal keyword it
creates for the user to apply when missing (ADR-024). Every menu command runs against a photo and a catalog that check every method
the plugin calls: anything but a known read or one of those writes is a violation. A future
bug that sets a rating, a flag, a title, a develop setting or a foreign keyword therefore
fails here, whatever the SDK method is called.

Correct Genres… and the genre dialogs need LrView, which has no stub; their decisions run
through the same GrReview.run as every other command, and are driven here directly.
]]

local t = require 'harness'

local Json        = require 'GrJson'
local Taxonomy    = require 'GrTaxonomy'
local Collections = require 'GrCollections'

local Photo           = require 'photo'
local LrApplication   = require 'LrApplication'
local LrDialogs       = require 'LrDialogs'
local LrExportSession = require 'LrExportSession'
local LrFileUtils     = require 'LrFileUtils'
local LrProgressScope = require 'LrProgressScope'

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local PLUGIN_DIR = here .. '/../Genreator.lrplugin/'

local FIELD = {}
for _, f in ipairs(dofile(PLUGIN_DIR .. 'GenreatorMetadata.lua').metadataFieldsForPhotos) do
  FIELD[f.id] = true
end

-- ------------------------------------------------------------------ the guards

-- Each kind of violation once, so a write repeated per photo stays one readable line.
local violations, seen, writes = {}, {}, {}
local function violation(fmt, ...)
  local v = string.format(fmt, ...)
  if not seen[v] then seen[v] = true; violations[#violations + 1] = v end
end
local function wrote(kind) writes[kind] = (writes[kind] or 0) + 1 end

local function isGenreRoot(kw)
  return kw ~= nil and kw._name == 'Genre' and kw._parent == nil
end
-- The default Personal keyword, `#PERSONAL`, at the top of the tree.
local PERSONAL = require('GrConfig').defaults.personalKeyword
local function isGenreKeyword(kw)
  return isGenreRoot(kw._parent) and Taxonomy.isGenre(kw._name)
end
-- The keyword taxonomy's keywords (ADR-030): a keyword at one of its paths, and the levels on
-- the way (categories, subcategories, general keywords), which are created but never assigned.
local KT = require 'GrKeywordTaxonomy'
assert(KT.load(require('GrModel').dir()))
local function pathOf(kw)
  local path = {}
  while kw do table.insert(path, 1, kw._name); kw = kw._parent end
  return path
end
local onTaxonomyPath = {}
for _, k in ipairs(KT.keywords) do
  local path = KT.path(k.id)
  for i = 1, #path do onTaxonomyPath[KT.pathKey { unpack(path, 1, i) }] = true end
end
local function isTaxonomyKeyword(kw) return KT.idOfPath(pathOf(kw)) ~= nil end

-- Reads the plugin may make; every other photo method must be one of the writes below.
local PHOTO_READS = { getRawMetadata = true, getFormattedMetadata = true,
                      getPropertyForPlugin = true, checkPhotoAvailability = true }

local function guardPhoto(photo)
  return setmetatable(photo, { __index = function(_, name)
    local method = Photo[name]
    if PHOTO_READS[name] or name:sub(1, 1) == '_' then return method end
    if name == 'setPropertyForPlugin' then
      return function(self, plugin, key, value)
        if not FIELD[key] then violation('photo:setPropertyForPlugin(%s): not a declared field', tostring(key)) end
        wrote('field')
        return method(self, plugin, key, value)
      end
    end
    if name == 'addKeyword' or name == 'removeKeyword' then
      return function(self, kw)
        if not isGenreKeyword(kw) and not isTaxonomyKeyword(kw) then
          violation('photo:%s(%s): not a Genre keyword or a keyword of the keyword taxonomy', name, tostring(kw._name))
        end
        wrote(name)
        return method(self, kw)
      end
    end
    violation('photo:%s()', tostring(name))
    return function() end
  end })
end

local function inPluginSet(set)
  while set do
    if set.parent == nil then return set.kind == 'set' and set.name == Collections.SET_NAME end
    set = set.parent
  end
  return false
end

local CATALOG_READS = { getTargetPhotos = true, getActiveSources = true, findPhotoByUuid = true,
                        findPhotosWithProperty = true, batchGetRawMetadata = true,
                        batchGetPropertyForPlugin = true, withWriteAccessDo = true }
-- Collections and sets are objects of their own, not catalog methods: Set Up deletes only its
-- own old smart collections (test_collections.lua checks which).
local CATALOG_WRITES = {
  createKeyword = function(name, _, includeOnExport, parent)
    local path = pathOf(parent)
    path[#path + 1] = name
    if not ((name == 'Genre' and parent == nil) or (isGenreRoot(parent) and Taxonomy.isGenre(name))
            or (name == PERSONAL and parent == nil) or onTaxonomyPath[KT.pathKey(path)]) then
      violation('catalog:createKeyword(%s): not Genre, a genre under it, a keyword taxonomy path or the Personal keyword',
                tostring(name))
    end
    if includeOnExport ~= false then violation('catalog:createKeyword(%s): included on export', tostring(name)) end
  end,
  createCollectionSet = function(name, parent)
    if not ((parent == nil and name == Collections.SET_NAME) or inPluginSet(parent)) then
      violation('catalog:createCollectionSet(%s): outside the %s set', tostring(name), Collections.SET_NAME)
    end
  end,
  createCollection = function(name, parent)
    if not inPluginSet(parent) then
      violation('catalog:createCollection(%s): outside the %s set', tostring(name), Collections.SET_NAME)
    end
  end,
  createSmartCollection = function(name, _, parent)
    if not inPluginSet(parent) then
      violation('catalog:createSmartCollection(%s): outside the %s set', tostring(name), Collections.SET_NAME)
    end
  end,
}

local function guardCatalog(real)
  return setmetatable({}, { __index = function(_, name)
    if name:sub(1, 1) == '_' then return real[name] end
    local method = real[name]
    if CATALOG_READS[name] then return function(_, ...) return method(real, ...) end end
    local check = CATALOG_WRITES[name]
    if check then
      return function(_, ...) check(...); wrote(name); return method(real, ...) end
    end
    violation('catalog:%s()', tostring(name))
    return function() end
  end })
end

-- ------------------------------------------------------------------ the catalog

local TMP = '/tmp/genreator-footprint'
os.execute('mkdir -p ' .. TMP)
local configPath = TMP .. '/config.json'
local fh = assert(io.open(configPath, 'w'))
fh:write(Json.encode { chunkSize = 2, logLevel = 'error' })
fh:close()
local outerGetenv = os.getenv
os.getenv = function(name)
  if name == 'GENREATOR_CONFIG' then return configPath end
  return outerGetenv(name)
end
local Model = require 'GrModel'
local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local cwd = io.popen('pwd'):read('*l')
Model.binary = (here:sub(1, 1) == '/' and here or (cwd .. '/' .. here)) .. '/fixtures/fake-localgenres'
local realCheck = Model.check
Model.check = function() return true end

LrDialogs._reset()
LrFileUtils._reset()
local photos = {
  Photo.new { keywords = { 'Anna', 'PERSONAL' }, personKeywords = { 'Anna' },
              keywordPaths = { '#PERSONAL > Family' }, formatted = { dateCreated = '2019-07-14T10:00:00' } },
  Photo.new { keywords = { 'Street', 'Iceland' }, raw = { uuid = 'UUID-2' },
              formatted = { dateCreated = '2020-02-01T10:00:00', fileName = 'DSC_0002.NEF' } },
  Photo.new { keywords = {}, formatted = { dateCreated = '2021-05-05T10:00:00' } },
}
local real = LrApplication._fakeCatalog(photos)

-- A user's own child of Genre, set up before the plugin runs: never the plugin's to touch.
real:withWriteAccessDo('set-up', function()
  local root = real:createKeyword('Genre', {}, false, nil, true)
  local wedding = real:createKeyword('Wedding', {}, true, root, true)
  photos[3]._keywords[#photos[3]._keywords + 1] = wedding
end)
-- The keywords a photograph has outside the plugin's keyword taxonomy, which the keyword
-- commands add to and remove from (ADR-030).
local function ownKeywords(p)
  local out = {}
  for _, kw in ipairs(p._keywords) do
    if not isTaxonomyKeyword(kw) then out[#out + 1] = table.concat(pathOf(kw), ' > ') end
  end
  table.sort(out)
  return out
end
local before = {}
for i, p in ipairs(photos) do before[i] = ownKeywords(p); guardPhoto(p) end

local catalog = guardCatalog(real)
LrApplication._setCatalog(catalog)

local function scriptRenditions()
  local scripted = {}
  for i, p in ipairs(photos) do
    local path = string.format('%s/%d.jpg', TMP, i)
    local out = assert(io.open(path, 'wb'))
    out:write('\255\216\255\224' .. string.rep(string.char(64 + i), 128))
    out:close()
    LrFileUtils._files[path] = 'on disk'
    scripted[#scripted + 1] = { photo = p, success = true, path = path }
  end
  LrExportSession._reset()
  LrExportSession._scriptedRenditions = scripted
end

local function menu(file) dofile(PLUGIN_DIR .. file) end

local Review  = require 'GrReview'
local Command = require 'GrReviewCommand'
local function decideDirectly(decide)
  Review.run(catalog, photos, decide, 'Genreator: test', LrProgressScope {})
end

-- ------------------------------------------------------------------ every command

t.suite('Footprint — every command writes only its own fields, its keywords and collections')

local g1, g2 = Taxonomy.genres[1], Taxonomy.genres[2]

menu 'GrMenuSetUpCollections.lua'
menu 'GrMenuCheckModel.lua'
scriptRenditions(); menu 'GrMenuClassify.lua'
local gridOf = {}
for _, sp in ipairs(Collections.specs('com.genreator.lightroom')) do
  local g = Collections.genreOfGrid(sp.name, sp.set)
  if g then gridOf[g] = sp.name end
end
real._sources = { { getName = function() return gridOf[g1] end,
                    getParent = function() return { getName = function() return Collections.GENRE_SET end } end } }
menu 'GrMenuRemoveGenre.lua'
real._sources = nil
local trailed = 0
for _, p in ipairs(photos) do
  if (p._plugin.reviewTrail or ''):find(' rm:' .. g1 .. ' n=' .. #photos .. ' @' .. Collections.GENRE_SET .. '/' .. gridOf[g1], 1, true) then
    trailed = trailed + 1
  end
end
t.ok(trailed > 0, 'Remove Genre in a genre grid records the command, the selection size and the grid')
local askGenre = Command.askGenre
Command.askGenre = function() return g2 end
menu 'GrMenuAddGenre.lua'
menu 'GrMenuAccept.lua'
menu 'GrMenuSetPrimary.lua'
Command.askGenre = askGenre
decideDirectly(function(fields) return Review.correctDecision(fields, g1, { g1, g2 }) end)
scriptRenditions(); menu 'GrMenuReclassify.lua'
scriptRenditions(); menu 'GrMenuRate.lua'
menu 'GrMenuRederive.lua'
-- Pick Photos to Review… asks for N in an LrView dialog (no stub); its work is the classifier's
-- pick mode, driven here directly after clearing the data so there are candidates.
menu 'GrMenuClearData.lua'
scriptRenditions(); require('GrClassifier').classifySelection { pick = { n = 1 } }
menu 'GrMenuUpdateKeywords.lua'
local approvedFile = TMP .. '/approved.json'
local af = assert(io.open(approvedFile, 'w'))
af:write(Json.encode { schema_version = 1, taxonomy_version = Taxonomy.version, count = 1,
  items = Json.array { { photo_uuid = 'UUID-2', file_base = 'DSC_0002', primary = g2, genres = Json.array { g2, g1 } } } })
af:close()
LrDialogs._openPanel = { approvedFile }
menu 'GrMenuApplyApproved.lua'
LrDialogs._openPanel = nil
-- The keyword commands (ADR-030): suggest, verify, re-suggest, and a judgements file.
scriptRenditions(); menu 'GrMenuSuggestKeywords.lua'
menu 'GrMenuMarkVerified.lua'
scriptRenditions(); menu 'GrMenuResuggestKeywords.lua'
local judgementsFile = TMP .. '/judgements.json'
local jf = assert(io.open(judgementsFile, 'w'))
jf:write(Json.encode { schema_version = 1, taxonomy_version = KT.version, count = 1,
  items = Json.array { { photo_uuid = 'UUID-2', file_base = 'DSC_0002', keywords = Json.array { KT.keywords[1].name } } } })
jf:close()
LrDialogs._openPanel = { judgementsFile }
menu 'GrMenuApplyJudgements.lua'
LrDialogs._openPanel = nil
local judged = 0
for _, p in ipairs(photos) do if p._plugin.keywordState == 'golden' then judged = judged + 1 end end
t.eq(judged, 1, 'the judgements file was applied')
menu 'GrMenuExportReport.lua'
menu 'GrMenuQualitySummary.lua'
menu 'GrMenuRemoveKeywords.lua'
menu 'GrMenuClearData.lua'

t.eq(violations, {}, 'no command wrote anything outside the plugin\'s own fields, Genre keywords and collections')
for _, m in ipairs(LrDialogs._messages) do
  t.ok(m.style ~= 'critical', 'no command failed: ' .. tostring(m.title) .. ' — ' .. tostring(m.body))
end
t.ok((writes.field or 0) > 0 and (writes.addKeyword or 0) > 0 and (writes.removeKeyword or 0) > 0
     and (writes.createSmartCollection or 0) > 0,
     'the commands did write: fields, Genre keywords added and removed, collections')
local taxonomyAssigned = 0
for _, p in ipairs(photos) do for _, kw in ipairs(p._keywords) do
  if isTaxonomyKeyword(kw) then taxonomyAssigned = taxonomyAssigned + 1 end end end
t.ok(taxonomyAssigned > 0, '... and keywords of the keyword taxonomy')
for i, p in ipairs(photos) do
  t.eq(ownKeywords(p), before[i], string.format('photo %d keeps exactly its own keywords', i))
end

-- ------------------------------------------------------------------ the guard itself

t.suite('Footprint — the guard catches a write it does not know')

violations, seen = {}, {}
photos[1]:setRawMetadata('rating', 5)
real:withWriteAccessDo('test', function() photos[1]:removeKeyword(photos[1]._keywords[1]) end)
catalog:setPropertyForPlugin()
t.eq(#violations, 3, 'a rating, a foreign keyword and an unknown catalog method are each a violation')

violations, seen = {}, {}
real:withWriteAccessDo('test', function()
  catalog:createKeyword('Holiday', {}, false, nil, true)
  catalog:createKeyword(g1, {}, true, catalog:createKeyword('Genre', {}, false, nil, true), true)
  catalog:createCollectionSet('Mine', nil, true)
  catalog:createSmartCollection('Mine', {}, nil, true)
end)
t.eq(#violations, 4, 'a foreign keyword, a genre keyword included on export, and a collection '
     .. 'set or smart collection outside the Genreator set are each a violation')

os.getenv = outerGetenv
Model.binary = nil
Model.check = realCheck
LrApplication._setCatalog(nil)
