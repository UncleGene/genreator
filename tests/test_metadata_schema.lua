--[[
Guard for Lightroom's per-field versioning. Lightroom refuses to upgrade a catalog when a
custom metadata field's definition changes but that field's `version` does not ("...setting
for 'dataType' changed, but the version number did not" — seen 2026-10-03). The
plugin-wide schemaVersion is not enough.

The snapshot below records each field's definition and version as last shipped. If you
change a field: bump its `version` in GenreatorMetadata.lua, bump schemaVersion, then update
the snapshot here.
]]

local t = require 'harness'

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local spec = dofile(here .. '/../Genreator.lrplugin/GenreatorMetadata.lua')

local function signature(field)
  local values = {}
  for _, v in ipairs(field.values or {}) do values[#values + 1] = tostring(v.value) end
  return table.concat({ tostring(field.dataType), table.concat(values, ','),
                        tostring(field.searchable), tostring(field.browsable),
                        tostring(field.title), tostring(field.readOnly == true) }, '|')
end

-- id -> { version, signature } as last shipped. Update deliberately, never to silence a failure.
local SHIPPED = {
  reviewState = { 3, 'enum|unclassified,suggested,accepted,corrected,error|true|true|Review state|true' },
  primaryGenre = { 2, 'string||true|true|Primary Genre|true' },
  secondaryGenres = { 3, 'string||true|false|Secondary Genres|false' },
  reviewGenre = { 4, 'string||true|false|Under review: primary genre|true' },
  reviewGenres = { 4, 'string||true|false|Under review: genres|true' },
  errorText = { 3, 'string||false|false|Error|true' },
  aiGenre = { 5, 'string||false|false|nil|false' },
  aiGenres = { 4, 'string||false|false|nil|false' },
  aiRanking = { 1, 'string||false|false|nil|false' },
  userGenres = { 1, 'string||false|false|nil|false' },
  humanGenre = { 5, 'string||false|false|nil|false' },
  humanGenres = { 4, 'string||false|false|nil|false' },
  decisionSource = { 1, 'string||false|false|nil|false' },
  model = { 4, 'string||false|false|nil|false' },
  modelVersion = { 1, 'string||false|false|nil|false' },
  classifiedAt = { 3, 'string||false|false|nil|false' },
  runId = { 3, 'string||false|false|nil|false' },
  pickReason = { 1, 'string||false|false|nil|false' },
  reviewTrail = { 1, 'string||false|false|nil|false' },
  laterUserGenres = { 1, 'string||false|false|nil|false' },
  decisionModelVersion = { 1, 'string||false|false|nil|false' },
  personal = { 1, 'string||true|false|Classified as personal|true' },
  decisionPersonal = { 1, 'string||false|false|nil|false' },
  ratingBucket = { 1, 'string||true|true|Suggested rating|true' },
  ratingRatio = { 1, 'string||false|false|nil|false' },
  ratingScore = { 1, 'string||false|false|nil|false' },
  ratingBuckets = { 1, 'string||false|false|nil|false' },
  ratingModelVersion = { 1, 'string||false|false|nil|false' },
  keywordState = { 1, 'string||true|true|Keyword review|true' },
  keywordSuggestion = { 1, 'string||false|false|nil|false' },
  keywordDecided = { 1, 'string||false|false|nil|false' },
  keywordError = { 1, 'string||false|false|nil|false' },
}

t.suite('GenreatorMetadata — a changed field must bump its own version')

local ids = {}
for _, field in ipairs(spec.metadataFieldsForPhotos) do
  ids[field.id] = true
  local shipped = SHIPPED[field.id]
  local sig = signature(field)
  if not shipped then
    t.ok(false, string.format('field %q is new: add it to SHIPPED with version %s and signature %q',
                              field.id, tostring(field.version), sig))
  elseif sig ~= shipped[2] then
    t.ok(field.version > shipped[1], string.format(
      'field %q changed (%s -> %s): its version must exceed %d, or Lightroom refuses the catalog upgrade',
      field.id, shipped[2], sig, shipped[1]))
  else
    t.ok(field.version >= shipped[1], 'field ' .. field.id .. ' version never decreases')
  end
end
t.ok(type(spec.schemaVersion) == 'number' and spec.schemaVersion >= 20, 'schemaVersion is current')

t.suite('GenreatorMetadata — the Metadata panel (ADR-020)')

-- Shown, in this order: what a person filters on, then what review needs. Everything else is
-- provenance for the report and Diagnostics, hidden by having no title.
-- Classified as personal, the suggested rating and the keyword review come last: Personal
-- Candidates searches the first (ADR-028), the rating collections the second (ADR-029), the
-- keyword collections the third (ADR-030).
local PANEL = { 'reviewState', 'primaryGenre', 'secondaryGenres', 'reviewGenre', 'reviewGenres',
                'errorText', 'personal', 'ratingBucket', 'keywordState' }
-- Lightroom cuts a read-only value off at one line; only an editable field wraps. Secondary
-- Genres can be long, and a hand-edited value is rewritten by Update Genre Keywords, so it
-- stays editable. Everything else shown is read-only.
local WRAPS = { secondaryGenres = true }
local shown = {}
for _, field in ipairs(spec.metadataFieldsForPhotos) do
  if field.title then
    shown[#shown + 1] = field.id
    if WRAPS[field.id] then
      t.ok(field.readOnly ~= true, field.id .. ' is editable, so a long value wraps')
    else
      t.ok(field.readOnly == true, field.id .. ' is read-only: only plugin commands change it')
    end
  end
  if field.searchable or field.browsable then
    t.ok(field.title ~= nil, field.id .. ' is a filter criterion, so it keeps a title')
  end
end
t.eq(shown, PANEL, 'the panel shows exactly these fields, in this order')

local Metadata = require 'GrMetadata'
local declared = {}
for _, field in ipairs(spec.metadataFieldsForPhotos) do declared[field.id] = true end
for name, id in pairs(Metadata.FIELDS) do t.ok(declared[id], 'GrMetadata.FIELDS.' .. name .. ' is declared') end
for id in pairs(declared) do t.ok(Metadata.FIELDS[id] == id, id .. ' is in GrMetadata.FIELDS') end

return t
