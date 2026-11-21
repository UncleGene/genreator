-- Stub of LrApplication. The catalog is settable so tests can script a selection, and it
-- models the keyword tree closely enough to test GrKeywords against Lightroom's rules.
local M = {}

M._catalog = nil

function M._setCatalog(catalog)
  M._catalog = catalog
end

-- A keyword object as Lightroom exposes it. getName/getParent are catalog reads.
local function newKeyword(name, parent, includeOnExport, catalog)
  local kw = { _name = name, _parent = parent, _includeOnExport = includeOnExport,
               _children = {}, _pendingIn = nil }
  function kw:getName()
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    return self._name
  end
  function kw:getParent()
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    return self._parent
  end
  return kw
end
M._newKeyword = newKeyword

--- A minimal fake catalog: a selection, a write-access gate, and a keyword tree.
function M._fakeCatalog(photos)
  local catalog = {
    _photos = photos or {},
    _writeTitles = {},
    _roots = {},
    _gateDepth = 0,
    _gateSerial = 0,
  }
  function catalog:getTargetPhotos() return self._photos end
  --- The sources shown in the grid; tests set `_sources` (collections are { getName }).
  function catalog:getActiveSources() return self._sources or {} end
  --- All catalog photos (`_all`, else the selection) with the plugin field set. Lightroom
  -- takes the plugin id STRING here, not the _PLUGIN object.
  function catalog:findPhotosWithProperty(pluginId, field)
    assert(type(pluginId) == 'string', 'findPhotosWithProperty takes the plugin id string')
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    local out = {}
    for _, p in ipairs(self._all or self._photos) do
      local v = p._plugin[field]
      if v ~= nil and v ~= '' then out[#out + 1] = p end
    end
    return out
  end
  --- Batched reads: a table keyed by photo. The plugin id as a string, as findPhotosWithProperty
  -- takes it; not yet verified in Lightroom (docs/architecture.md).
  function catalog:batchGetRawMetadata(list, keys)
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    local out = {}
    for _, p in ipairs(list) do
      out[p] = {}
      for _, k in ipairs(keys) do out[p][k] = p._raw[k] end
    end
    return out
  end
  function catalog:batchGetPropertyForPlugin(list, pluginId, fields)
    assert(type(pluginId) == 'string', 'batchGetPropertyForPlugin takes the plugin id string')
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    local out = {}
    for _, p in ipairs(list) do
      out[p] = {}
      for _, f in ipairs(fields) do out[p][f] = p._plugin[f] end
    end
    return out
  end
  --- The photo with this UUID (raw metadata `uuid`) among `_all`, else the selection.
  function catalog:findPhotoByUuid(uuid)
    if __plainPcallDepth > 0 then error('Yielding is not allowed within a C or metamethod call', 2) end
    for _, p in ipairs(self._all or self._photos) do
      if p._raw.uuid == uuid then return p end
    end
    return nil
  end
  function catalog:withWriteAccessDo(title, fn)
    -- It yields, so Lightroom rejects it inside a plain pcall (see tests/run.lua).
    if __plainPcallDepth > 0 then
      error('LrCatalog:withWriteAccessDo: must be called from within an LrTask', 2)
    end
    self._writeTitles[#self._writeTitles + 1] = title
    self._gateSerial = self._gateSerial + 1
    self._gateDepth = self._gateDepth + 1
    self._currentGate = self._gateSerial
    fn()
    self._gateDepth = self._gateDepth - 1
    self._currentGate = nil
  end
  --- Collection sets and smart collections: write-gated; canReturnPrior returns the
  -- existing one of that name under that parent, unchanged.
  catalog._collections = {}
  local function findOrMake(kind, name, parent, canReturnPrior, extra)
    assert(catalog._gateDepth > 0, kind .. ' outside withWriteAccessDo')
    for _, c in ipairs(catalog._collections) do
      if c.kind == kind and c.name == name and c.parent == parent then
        if canReturnPrior then return c end
        return nil
      end
    end
    local c = { kind = kind, name = name, parent = parent }
    for k, v in pairs(extra or {}) do c[k] = v end
    catalog._collections[#catalog._collections + 1] = c
    catalog._addCollectionMethods(c)
    return c
  end
  --- The read and delete methods of LrCollection / LrCollectionSet. Lightroom: a child list
  -- and a name are catalog reads; delete is write-gated.
  function catalog._addCollectionMethods(c)
    function c:getName() return self.name end
    function c:getParent() return self.parent end
    function c:isSmartCollection() return self.kind == 'smart' end
    function c:getSearchDescription() return self.searchDesc end
    local function childrenOf(kindWanted)
      local out = {}
      for _, x in ipairs(catalog._collections) do
        if x.parent == c and ((kindWanted == 'set') == (x.kind == 'set')) then out[#out + 1] = x end
      end
      return out
    end
    function c:getChildCollectionSets() return childrenOf('set') end
    function c:getChildCollections() return childrenOf('collection') end
    function c:delete()
      assert(catalog._gateDepth > 0, 'delete outside withWriteAccessDo')
      assert(#childrenOf('set') == 0 and #childrenOf('collection') == 0 or self.kind ~= 'set',
             'deleting a set that is not empty')
      for i, x in ipairs(catalog._collections) do
        if x == self then table.remove(catalog._collections, i); break end
      end
      self._deleted = true
    end
  end
  function catalog:createCollectionSet(name, parent, canReturnPrior)
    return findOrMake('set', name, parent, canReturnPrior)
  end
  --- An ordinary collection: write-gated photo membership.
  function catalog:createCollection(name, parent, canReturnPrior)
    local c = findOrMake('collection', name, parent, canReturnPrior, { photos = {} })
    if c and not c.addPhotos then
      function c:addPhotos(list)
        assert(catalog._gateDepth > 0, 'addPhotos outside withWriteAccessDo')
        for _, p in ipairs(list) do self.photos[#self.photos + 1] = p end
      end
      function c:getPhotos()
        local out = {}
        for i, p in ipairs(self.photos) do out[i] = p end
        return out
      end
      function c:removePhotos(list)
        assert(catalog._gateDepth > 0, 'removePhotos outside withWriteAccessDo')
        local drop = {}
        for _, p in ipairs(list) do drop[p] = true end
        local keep = {}
        for _, p in ipairs(self.photos) do if not drop[p] then keep[#keep + 1] = p end end
        self.photos = keep
      end
    end
    return c
  end
  function catalog:createSmartCollection(name, searchDesc, parent, canReturnPrior)
    local c = findOrMake('smart', name, parent, canReturnPrior, { searchDesc = searchDesc })
    if c and not c.setSearchDescription then
      function c:setSearchDescription(desc)
        assert(catalog._gateDepth > 0, 'setSearchDescription outside withWriteAccessDo')
        self.searchDesc = desc
      end
    end
    return c
  end

  --- createKeyword(name, synonyms, includeOnExport, parent, returnExisting).
  -- Lightroom: write-gated, and a NEW keyword cannot be assigned until the gate that
  -- created it has returned. Modelled by tagging it with that gate's serial.
  function catalog:createKeyword(name, _, includeOnExport, parent, returnExisting)
    assert(self._gateDepth > 0, 'createKeyword outside withWriteAccessDo')
    local siblings = parent and parent._children or self._roots
    for _, k in ipairs(siblings) do
      if k._name == name then
        if returnExisting then return k end
        return nil
      end
    end
    local kw = newKeyword(name, parent, includeOnExport, self)
    kw._pendingIn = self._currentGate
    siblings[#siblings + 1] = kw
    return kw
  end
  return catalog
end

function M.activeCatalog()
  return M._catalog or M._fakeCatalog {}
end

return M
