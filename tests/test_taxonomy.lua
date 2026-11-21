--[[
Tests for GrTaxonomy — the genres the bundled model knows (ADR-021): read from the model's
taxonomy file, validated, never edited; and the No genre outcome (ADR-022).
]]

local t = require 'harness'
local Json = require 'GrJson'
local Taxonomy = require 'GrTaxonomy'

local here = arg[0]:match('^(.*)/[^/]*$') or '.'

t.suite('GrTaxonomy — the bundled model taxonomy')

local file = Json.decode(assert(Taxonomy.readFile(here .. '/../Genreator.lrplugin/model/taxonomy.json')))
t.eq(Taxonomy.genres, file.genres, 'the genres are the model taxonomy\'s, in its order')
t.eq(Taxonomy.version, file.version, 'the version is the model taxonomy\'s')
t.ok(Taxonomy.source:match('model/taxonomy%.json$') ~= nil, 'loaded from the model folder')
t.ok(#Taxonomy.genres >= Taxonomy.MIN_GENRES, 'at least two genres')
for _, g in ipairs(Taxonomy.genres) do
  t.ok(g:match('^%a+$') ~= nil, g .. ' is letters only')
  t.eq(Taxonomy.fromShort(Taxonomy.short(g)), g, g .. ' round-trips through its short form')
end
t.eq(#Taxonomy.keywordNames(), #Taxonomy.genres, 'keyword names are exactly the genres')

t.suite('GrTaxonomy — No genre is an outcome, never a genre')

t.ok(not Taxonomy.isGenre(Taxonomy.NO_GENRE), 'No genre is not a genre')
t.ok(Taxonomy.isPrimary(Taxonomy.NO_GENRE), 'No genre is a valid primary')
t.ok(Taxonomy.NO_GENRE:find(' ') ~= nil, 'it has a space, so no letters-only genre can share it')
for _, g in ipairs(Taxonomy.keywordNames()) do t.ok(g ~= Taxonomy.NO_GENRE, 'No genre never becomes a keyword') end
t.ok(not Taxonomy.isGenre('Unresolved'), 'Unresolved is gone')
t.ok(not Taxonomy.isGenre(Taxonomy.genres[1]:lower()), 'genre check is case-sensitive')

t.suite('GrTaxonomy — a file the plugin cannot trust is refused')

local function parse(genres, version)
  return Taxonomy.parse(Json.encode { version = version or 'v1', genres = Json.array(genres) })
end
t.ok(parse { 'Street', 'Portrait' } ~= nil, 'two letters-only genres parse')
local spec, err = parse { 'Street' }
t.ok(spec == nil and err:find('2 to 12') ~= nil, 'one genre is refused')
spec, err = parse { 'Street', 'Still Life' }
t.ok(spec == nil and err:find('letters only') ~= nil, 'a space in a name is refused')
spec, err = parse { 'Street', 'street' }
t.ok(spec == nil and err:find('twice') ~= nil, 'a duplicate (any case) is refused')
spec, err = parse { 'Portrait', 'Portal' }
t.ok(spec == nil and err:find('short form') ~= nil, 'genres sharing a short form are refused')
spec, err = parse { 'Ab', 'Street' }
t.ok(spec == nil and err:find('shorter') ~= nil, 'a name shorter than its short form is refused')
spec, err = Taxonomy.parse('{"genres":["Street","Portrait"]}')
t.ok(spec == nil and err:find('version') ~= nil, 'a file without a version is refused')
spec, err = Taxonomy.parse('not json')
t.ok(spec == nil and err:find('JSON') ~= nil, 'a file that is not JSON is refused')

local before = Taxonomy.version
t.ok(not Taxonomy.loadFile('/nonexistent/taxonomy.json'), 'a missing file does not load')
t.eq(Taxonomy.version, before, 'and the taxonomy in use is unchanged')

return t
