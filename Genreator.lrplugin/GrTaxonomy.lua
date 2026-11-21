--[[
GrTaxonomy — the genres the bundled model knows (ADR-021).

The genre names and their order come from the model's own taxonomy file,
`model/taxonomy.json`; the model was trained on exactly these, so they are not editable. The
definitions in that file are documentation (docs/taxonomy.md): the model never reads them.

Besides the genres there is one outcome, NO_GENRE: no genre applies. It is a value of the
Primary Genre field, never a keyword. Each genre has a short form, its first three letters,
used in the stored ranking (`aiRanking`); a taxonomy whose short forms collide is refused.

Nothing else in the plugin hard-codes a genre name.

Pure module: reads files with io only, no Lr* dependency.
]]

local Json = require 'GrJson'

local Taxonomy = {}

--- The outcome "no genre applies" (ADR-022). Contains a space, so no genre can share it:
-- genre names are letters only.
Taxonomy.NO_GENRE = 'No genre'

Taxonomy.MIN_GENRES = 2
Taxonomy.MAX_GENRES = 12
Taxonomy.SHORT_LENGTH = 3

-- Current taxonomy, set by Taxonomy.apply().
Taxonomy.genres = {}
Taxonomy.version = ''
Taxonomy.source = nil

local genreSet, shortOf, genreOfShort, rankOf = {}, {}, {}, {}

--- Pure: parse the model's taxonomy file (JSON with `version` and `genres`).
-- @return spec { version, genres }; or nil, errorMessage
function Taxonomy.parse(text)
  if type(text) ~= 'string' or text == '' then return nil, 'taxonomy file is empty' end
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= 'table' then return nil, 'taxonomy file is not JSON' end
  if type(data.version) ~= 'string' or data.version == '' then
    return nil, 'taxonomy file has no version'
  end
  if type(data.genres) ~= 'table' then return nil, 'taxonomy file has no genres list' end

  local genres, seen, shorts = {}, {}, {}
  for _, name in ipairs(data.genres) do
    if type(name) ~= 'string' or not name:match('^%a+$') then
      return nil, string.format('genre %q: a genre name is letters only', tostring(name))
    end
    if seen[name:lower()] then return nil, string.format('genre %q is listed twice', name) end
    seen[name:lower()] = true
    if #name < Taxonomy.SHORT_LENGTH then
      return nil, string.format('genre %q is shorter than %d letters', name, Taxonomy.SHORT_LENGTH)
    end
    local short = name:sub(1, Taxonomy.SHORT_LENGTH)
    if shorts[short:lower()] then
      return nil, string.format('genres %q and %q share the short form %q', shorts[short:lower()], name, short)
    end
    shorts[short:lower()] = name
    genres[#genres + 1] = name
  end
  if #genres < Taxonomy.MIN_GENRES or #genres > Taxonomy.MAX_GENRES then
    return nil, string.format('taxonomy needs %d to %d genres, found %d',
                              Taxonomy.MIN_GENRES, Taxonomy.MAX_GENRES, #genres)
  end
  return { version = data.version, genres = genres }
end

--- Make a parsed taxonomy current.
function Taxonomy.apply(spec, source)
  Taxonomy.genres = spec.genres
  Taxonomy.version = spec.version
  Taxonomy.source = source
  genreSet, shortOf, genreOfShort, rankOf = {}, {}, {}, {}
  for i, g in ipairs(spec.genres) do
    genreSet[g] = true
    rankOf[g] = i
    shortOf[g] = g:sub(1, Taxonomy.SHORT_LENGTH)
    genreOfShort[shortOf[g]] = g
  end
end

function Taxonomy.readFile(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local text = fh:read('*a')
  fh:close()
  return text
end

--- Load and apply the taxonomy at `path`.
-- @return true; or nil, errorMessage (the current taxonomy is left unchanged)
function Taxonomy.loadFile(path)
  local text = Taxonomy.readFile(path)
  if not text then return nil, 'cannot read taxonomy file: ' .. tostring(path) end
  local spec, err = Taxonomy.parse(text)
  if not spec then return nil, string.format('%s (%s)', err, path) end
  Taxonomy.apply(spec, path)
  return true
end

--- The plugin folder: Lightroom provides _PLUGIN.path; offline, this module's own location.
function Taxonomy.pluginDir()
  if _PLUGIN and type(_PLUGIN.path) == 'string' then return _PLUGIN.path end
  local src = debug and debug.getinfo and debug.getinfo(1, 'S').source or ''
  return src:match('^@(.*)/[^/]*$') or '.'
end

function Taxonomy.defaultPath()
  return Taxonomy.pluginDir() .. '/model/taxonomy.json'
end

-- The bundled taxonomy must always load; a broken bundle is a packaging bug.
assert(Taxonomy.loadFile(Taxonomy.defaultPath()))

-- ---------------------------------------------------------------- lookups

function Taxonomy.isGenre(name)
  return type(name) == 'string' and genreSet[name] == true
end

--- A genre or NO_GENRE: what the Primary Genre field may hold on a categorized photograph.
function Taxonomy.isPrimary(name)
  return Taxonomy.isGenre(name) or name == Taxonomy.NO_GENRE
end

--- Genres that may become keywords. Excludes NO_GENRE by construction.
function Taxonomy.keywordNames()
  local out = {}
  for _, g in ipairs(Taxonomy.genres) do out[#out + 1] = g end
  return out
end

--- The genre's short form in the stored ranking, and back.
function Taxonomy.short(genre) return shortOf[genre] end
function Taxonomy.fromShort(short) return genreOfShort[short] end

--- Position of a genre in the taxonomy (1-based), for a stable order when no ranking exists.
function Taxonomy.rank(genre) return rankOf[genre] end

return Taxonomy
