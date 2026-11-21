--[[
GrKeywordTaxonomy — the keywords the bundled model suggests (ADR-030, R10).

The keyword model's taxonomy, published into the bundle as `model/keyword-taxonomy.json` by
`make model … KEYWORDS=…`: a version and a list of leaf keywords, each with a stable `id`, a
`name`, a `category` and a `subcategory`, and optionally a `fallback` — the id of the general
keyword it is a strict specific form of (Sailboat → Boat).

A keyword's place in Lightroom is its **path** from the root of the keyword list:
`Category > Subcategory > [general keyword(s) >] Keyword`, the general keywords outermost
first. Categories and subcategories are parents only, never assigned. A bundle without the
file has no keyword head: `load` says so and the keyword commands stop.

Validation refuses, naming the first problem: no version; no keywords; a keyword without an
id, name, category or subcategory; a duplicate id or name (case-insensitive); a fallback that
is not another keyword's id, or a cycle; a name, category or subcategory with `>` or a control
character; more than MAX_KEYWORDS keywords.

Keyword names are never hard-coded anywhere in the plugin: they come from here.

Pure module: reads files with io only, no Lr* dependency.
]]

local Json = require 'GrJson'

local KT = {}

KT.MAX_KEYWORDS = 500
KT.FILE = 'keyword-taxonomy.json'

KT.version = nil
KT.keywords = {}      -- in the file's order: { id, name, category, subcategory, fallback }

local byId, idOfName, idOfPathKey = {}, {}, {}

local function bad(name)
  return type(name) ~= 'string' or name == '' or name:find('>', 1, true) ~= nil or name:find('%c') ~= nil
end

--- Pure: the lookup key of a path (names from the root down), case-insensitive.
local function pathKey(path)
  local parts = {}
  for i, name in ipairs(path) do parts[i] = tostring(name):lower() end
  return table.concat(parts, '\t')
end
KT.pathKey = pathKey

--- Pure: parse and validate the file's text.
-- @return spec { version, keywords }; or nil, message
function KT.parse(text)
  if type(text) ~= 'string' or text == '' then return nil, 'the keyword taxonomy file is empty' end
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= 'table' then return nil, 'the keyword taxonomy file is not JSON' end
  if type(data.version) ~= 'string' or data.version == '' then return nil, 'the keyword taxonomy has no version' end
  if type(data.keywords) ~= 'table' or #data.keywords == 0 then return nil, 'the keyword taxonomy has no keywords' end
  if #data.keywords > KT.MAX_KEYWORDS then
    return nil, string.format('the keyword taxonomy has more than %d keywords', KT.MAX_KEYWORDS)
  end
  local keywords, ids, names = {}, {}, {}
  for i, k in ipairs(data.keywords) do
    if type(k) ~= 'table' or type(k.id) ~= 'string' or k.id == '' then
      return nil, string.format('keyword %d has no id', i)
    end
    for _, f in ipairs { 'name', 'category', 'subcategory' } do
      if bad(k[f]) then
        return nil, string.format('keyword %q: missing %s, or it holds ">" or a control character', k.id, f)
      end
    end
    if ids[k.id] then return nil, string.format('keyword id %q is listed twice', k.id) end
    if names[k.name:lower()] then return nil, string.format('keyword %q is listed twice', k.name) end
    ids[k.id], names[k.name:lower()] = true, true
    local fallback = k.fallback
    if fallback == Json.null then fallback = nil end
    keywords[i] = { id = k.id, name = k.name, category = k.category, subcategory = k.subcategory,
                    fallback = fallback }
  end
  local spec = { version = data.version, keywords = keywords }
  local index = {}
  for _, k in ipairs(keywords) do index[k.id] = k end
  for _, k in ipairs(keywords) do
    if k.fallback ~= nil and (type(k.fallback) ~= 'string' or not index[k.fallback] or k.fallback == k.id) then
      return nil, string.format('keyword %q: its general keyword %q is not in the taxonomy', k.name, tostring(k.fallback))
    end
    local seen, at = { [k.id] = true }, k.fallback
    while at do
      if seen[at] then return nil, string.format('keyword %q: its general keywords form a cycle', k.name) end
      seen[at] = true
      at = index[at].fallback
    end
  end
  return spec
end

--- Pure: make a parsed taxonomy current (nil: no keyword head).
function KT.apply(spec)
  KT.version = spec and spec.version or nil
  KT.keywords = spec and spec.keywords or {}
  byId, idOfName, idOfPathKey = {}, {}, {}
  for _, k in ipairs(KT.keywords) do
    byId[k.id] = k
    idOfName[k.name] = k.id
  end
  for _, k in ipairs(KT.keywords) do idOfPathKey[pathKey(KT.path(k.id))] = k.id end
end

--- Load the bundled file. A missing file is a model without a keyword head.
-- @param dir the model folder
-- @return true; or nil, message (and the taxonomy is emptied)
function KT.load(dir)
  local fh = io.open(dir .. '/' .. KT.FILE, 'rb')
  if not fh then
    KT.apply(nil)
    return nil, 'this model has no keyword head'
  end
  local text = fh:read('*a')
  fh:close()
  local spec, err = KT.parse(text)
  KT.apply(spec)
  if not spec then return nil, err end
  return true
end

-- ---------------------------------------------------------------- lookups

function KT.available() return KT.version ~= nil end
function KT.byId(id) return byId[id] end
function KT.nameOf(id) return byId[id] and byId[id].name end
function KT.idOfName(name) return idOfName[name] end

--- Pure: the keyword's path from the root: category, subcategory, its general keywords
-- outermost first, its name.
function KT.path(id)
  local k = byId[id]
  if not k then return nil end
  local chain, at = {}, k
  while at do
    table.insert(chain, 1, at.name)
    at = at.fallback and byId[at.fallback] or nil
  end
  local path = { k.category, k.subcategory }
  for _, name in ipairs(chain) do path[#path + 1] = name end
  return path
end

--- Pure: the taxonomy keyword at this path (names from the root), compared case-insensitively;
-- nil for any other keyword, a category or subcategory included.
function KT.idOfPath(path)
  return idOfPathKey[pathKey(path or {})]
end

--- Pure: ids in taxonomy order, so stored lists and plans are deterministic.
function KT.sorted(ids)
  local want, out = {}, {}
  for _, id in ipairs(ids or {}) do want[id] = true end
  for _, k in ipairs(KT.keywords) do if want[k.id] then out[#out + 1] = k.id end end
  return out
end

return KT
