--[[
A fake LrPhoto for offline tests.

Supports the subset GrMetadata and GrClassifier touch: getRawMetadata,
getFormattedMetadata, get/setPropertyForPlugin, and keyword objects with getName().
]]

local Photo = {}
Photo.__index = Photo

-- Catalog reads yield inside Lightroom, so a plain pcall around one fails there with this
-- message (seen 2026-10-03 on getRawMetadata('smartPreviewInfo')). LuaJIT can yield across
-- pcall, so the stub raises it explicitly; see tests/run.lua for the depth counter.
local function catalogRead()
  if __plainPcallDepth > 0 then
    error('Yielding is not allowed within a C or metamethod call', 3)
  end
end

local nextId = 0

-- Keywords shared by every photo, as one catalog has one `Genre` keyword: one object per path.
local byPath = {}
--- The keyword at a path ('Genre > Street', '#PERSONAL > Family > Anna'), its parents created
-- on the way: the same object on every photo.
function Photo.keywordAt(path)
  local parent, key
  for name in (path .. ' > '):gmatch('(.-) > ') do
    key = key and (key .. ' > ' .. name) or name
    if not byPath[key] then
      local p = parent
      byPath[key] = {
        _name = name, _parent = p,
        getName = function() catalogRead(); return name end,
        getParent = function() catalogRead(); return p end,
        getAttributes = function() catalogRead(); return { keywordName = name } end,
      }
    end
    parent = byPath[key]
  end
  return parent
end

--- @param spec table {
--   keywords = {'Anna','PERSONAL'}, keywordPaths = {'Genre > Street', '#PERSONAL > Family'},
--   raw = {fileFormat=...}, missing = true,
--   formatted = {dateCreated=..., focalLength=...}, plugin = {reviewState=...} }
function Photo.new(spec)
  spec = spec or {}
  nextId = nextId + 1

  local isPerson = {}
  for _, name in ipairs(spec.personKeywords or {}) do isPerson[name] = true end
  local keywordObjects = {}
  for _, name in ipairs(spec.keywords or {}) do
    keywordObjects[#keywordObjects + 1] = {
      _name = name,
      getName = function() catalogRead(); return name end,
      getParent = function() catalogRead(); return nil end,
      -- Since Lightroom 6, getAttributes() carries keywordType for person keywords (SDK
      -- release notes); the exact value 'person' is what the catalog stores.
      getAttributes = function()
        catalogRead()
        return { keywordName = name, keywordType = isPerson[name] and 'person' or nil,
                 includeOnExport = true, includeParents = true, includeSynonyms = true, synonyms = {} }
      end,
    }
  end

  for _, path in ipairs(spec.keywordPaths or {}) do
    keywordObjects[#keywordObjects + 1] = Photo.keywordAt(path)
  end

  return setmetatable({
    localIdentifier = nextId,
    _keywords = keywordObjects,
    _raw = spec.raw or {},
    _missing = spec.missing == true,
    _smartPreview = spec.smartPreview == true,
    _formatted = spec.formatted or {},
    _plugin = spec.plugin or {},
    _addedKeywords = {},
    _removedKeywords = {},
  }, Photo)
end

-- Lightroom raises "Unknown key" for a key it does not define. Only keys checked against
-- the SDK reference AND seen working in Lightroom belong here; an invented key must fail
-- offline the way it fails in the app (M1 verification hit 'isMissing').
-- smartPreviewInfo: documented in the SDK, not yet seen in Lightroom; GrClassifier guards it.
local RAW_KEYS = { keywords = true, fileFormat = true, smartPreviewInfo = true, uuid = true }

function Photo:getRawMetadata(key)
  catalogRead()
  if not RAW_KEYS[key] then error(string.format('Unknown key: %q', tostring(key)), 2) end
  if key == 'keywords' then return self._keywords end
  if key == 'uuid' then return self._raw.uuid end
  if key == 'smartPreviewInfo' then
    return self._smartPreview and { smartPreviewPath = '/sp.dng', smartPreviewSize = 2560 } or nil
  end
  return self._raw[key]
end

function Photo:checkPhotoAvailability()
  return not self._missing
end

function Photo:getFormattedMetadata(key)
  catalogRead()
  return self._formatted[key]
end

function Photo:getPropertyForPlugin(plugin, key)
  catalogRead()
  if plugin ~= _PLUGIN then
    error('LrPhoto:getPropertyForPlugin: first parameter must be the _PLUGIN object', 2)
  end
  return self._plugin[key]
end

-- Allowed values of each enum field, from the plugin's own declarations: Lightroom refuses
-- any other value, '' included unless declared (seen 2026-10-28 on Clear Plugin Data).
local enumValues
local function allowed(key, value)
  if not enumValues then
    enumValues = {}
    local here = debug.getinfo(1, 'S').source:match('^@(.*)/[^/]*$') or '.'
    for _, f in ipairs(dofile(here .. '/../../Genreator.lrplugin/GenreatorMetadata.lua').metadataFieldsForPhotos) do
      if f.dataType == 'enum' then
        enumValues[f.id] = {}
        for _, v in ipairs(f.values) do enumValues[f.id][v.value] = true end
      end
    end
  end
  return not enumValues[key] or enumValues[key][value] == true
end

function Photo:setPropertyForPlugin(plugin, key, value)
  if plugin ~= _PLUGIN then
    error('LrPhoto:setPropertyForPlugin: first parameter must be the _PLUGIN object', 2)
  end
  if not allowed(key, value) then
    error(string.format('<AgErrorText>The value is not one of the specified values for this field.</AgErrorText> (%s = %q)',
                        tostring(key), tostring(value)), 2)
  end
  self._plugin[key] = value
end

-- Keyword assignment is write-gated, and a keyword created in a gate cannot be assigned
-- inside that same gate (Lightroom: "not usable until withWriteAccessDo returns").
local function assertAssignable(kw)
  local cat = require('LrApplication')._catalog
  if cat then
    assert(cat._gateDepth > 0, 'addKeyword/removeKeyword outside withWriteAccessDo')
    if kw._pendingIn and kw._pendingIn == cat._currentGate then
      error('keyword created in this write-access call is not usable until it returns', 3)
    end
  end
end

function Photo:addKeyword(kw)
  assertAssignable(kw)
  self._addedKeywords[#self._addedKeywords + 1] = kw
  for _, k in ipairs(self._keywords) do if k == kw then return end end
  self._keywords[#self._keywords + 1] = kw
end

function Photo:removeKeyword(kw)
  assertAssignable(kw)
  self._removedKeywords[#self._removedKeywords + 1] = kw
  for i, k in ipairs(self._keywords) do
    if k == kw then table.remove(self._keywords, i); return end
  end
end

--- Test helper: the photo's keywords as "Parent > Name" / "Name" strings, sorted.
function Photo:_keywordPaths()
  local out = {}
  for _, k in ipairs(self._keywords) do
    local p = k._parent
    out[#out + 1] = p and (p._name .. ' > ' .. k._name) or (k._name or k.getName())
  end
  table.sort(out)
  return out
end

return Photo
