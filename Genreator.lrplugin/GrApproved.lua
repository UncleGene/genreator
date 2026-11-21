--[[
GrApproved — apply a file of approved genres to the catalog (ADR-025).

An approved genres file holds a person's own genre decisions for specific photographs:

  {"schema_version": 1, "taxonomy_version": "...", "count": n,
   "items": [{"photo_uuid": "...", "file_base": "DSC_0042", "primary": "Street",
              "genres": ["Street", "Object"]},
             {"photo_uuid": "...", "file_base": "DSC_0043", "primary": null, "genres": []}]}

Each item is applied as a decided photograph — keywords, genre fields and an `accepted`
review state — overriding whatever genres the photograph had. `primary: null` with no genres
is No genre. A photograph is matched by its Lightroom UUID, and its file name (without
extension) must equal `file_base`; anything else is skipped and reported, never guessed.

The decision records its source, `approved:<fingerprint of the file>`, so applying the same
file again changes nothing, and a newer file (more photographs, or a changed judgement)
updates exactly what differs.

Pure: parse, fingerprint, decision, fileBase. Lightroom-bound: the menu command.
]]

local Json     = require 'GrJson'
local Metadata = require 'GrMetadata'
local Taxonomy = require 'GrTaxonomy'

local Approved = {}

--- Pure: cheap deterministic fingerprint (djb2), hex: it only has to change with the file.
function Approved.fingerprint(text)
  local h = 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format('%08x', h)
end

--- Pure: read and validate a file. Invalid items are listed, not applied.
-- @return { source, items = { {uuid, fileBase, primary, genres} }, invalid = { reason... } };
--         or nil, message when the file as a whole cannot be used
function Approved.parse(text)
  local ok, data = pcall(Json.decode, text or '')
  if not ok or type(data) ~= 'table' or type(data.items) ~= 'table' then
    return nil, 'the file is not an approved genres file (JSON with an "items" list)'
  end
  if data.schema_version ~= 1 then
    return nil, string.format('unsupported schema_version %s', tostring(data.schema_version))
  end
  if data.taxonomy_version ~= Taxonomy.version then
    return nil, string.format('the file is for taxonomy %s; the plugin has %s',
                              tostring(data.taxonomy_version), Taxonomy.version)
  end
  local out = { source = Metadata.SOURCE.approved .. ':' .. Approved.fingerprint(text), items = {}, invalid = {} }
  for i, it in ipairs(data.items) do
    local why
    if type(it) ~= 'table' or type(it.photo_uuid) ~= 'string' or it.photo_uuid == ''
       or type(it.file_base) ~= 'string' or type(it.genres) ~= 'table' then
      why = 'missing photo_uuid, file_base or genres'
    else
      local primary = it.primary
      if primary == Json.null then primary = nil end
      local seen = {}
      for _, g in ipairs(it.genres) do
        if not Taxonomy.isGenre(g) then why = string.format('%q is not a genre', tostring(g)) end
        seen[g] = true
      end
      if not why then
        if primary == nil and #it.genres > 0 then
          why = 'genres without a primary'
        elseif primary ~= nil and not seen[primary] then
          why = string.format('primary %q is not among its genres', tostring(primary))
        end
      end
      if not why then
        out.items[#out.items + 1] = { uuid = it.photo_uuid, fileBase = it.file_base,
                                      primary = primary or Taxonomy.NO_GENRE, genres = it.genres }
      end
    end
    if why then out.invalid[#out.invalid + 1] = string.format('item %d: %s', i, why) end
  end
  return out
end

--- Pure: a file name without its extension.
function Approved.fileBase(name)
  return ((name or ''):gsub('%.[^%.]*$', ''))
end

--- Pure: the decision for one item, or nil + 'already applied' when the photograph already
-- holds exactly it.
function Approved.decision(fields, item, source)
  local genres = {}
  if item.primary ~= Taxonomy.NO_GENRE then
    genres[1] = item.primary
    for _, g in ipairs(item.genres) do if g ~= item.primary then genres[#genres + 1] = g end end
  end
  local list = table.concat(genres, ', ')
  if fields.reviewState == Metadata.STATE.accepted and fields.humanGenre == item.primary
     and (fields.humanGenres or '') == list and fields.decisionSource == source
     and fields.primaryGenre == item.primary then
    return nil, 'already applied'
  end
  return { state = Metadata.STATE.accepted, primary = item.primary, genres = genres, source = source }
end

-- ------------------------------------------------------------ Lightroom-bound

--- Match items to photographs. Catalog reads only.
-- @return matched array of { photo, item }; skipped table of counts by reason
function Approved.match(catalog, items)
  local LrTasks = import 'LrTasks'
  local matched, skipped, seen = {}, {}, {}
  local function skip(reason) skipped[reason] = (skipped[reason] or 0) + 1 end
  for _, item in ipairs(items) do
    local ok, photo = LrTasks.pcall(function() return catalog:findPhotoByUuid(item.uuid) end)
    if seen[item.uuid] then
      skip('listed twice (the first is applied)')
    elseif not ok or not photo then
      skip('not in this catalog')
    else
      local okName, name = LrTasks.pcall(function() return photo:getFormattedMetadata('fileName') end)
      if not okName or Approved.fileBase(name) ~= item.fileBase then
        skip('file name does not match')
      else
        seen[item.uuid] = true
        matched[#matched + 1] = { photo = photo, item = item }
      end
    end
  end
  return matched, skipped
end

return Approved
