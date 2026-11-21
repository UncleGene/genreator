--[[
The bundled model: what ships, and that it is intact. The encoder is a release asset (too
large for git), so its files are checked only when present; the rest is committed and must
always match the manifest. Per-photo label files are private and must never be in the bundle.
]]

local t = require 'harness'
local Json = require 'GrJson'

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local MODEL = here .. '/../Genreator.lrplugin/model'

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function sha256(path)
  local p = io.popen("shasum -a 256 '" .. path .. "' 2>/dev/null")
  local out = p:read('*a')
  p:close()
  return out:match('^(%x+)')
end

t.suite('Model bundle — manifest')

local manifest = Json.decode(readFile(MODEL .. '/manifest.json') or 'null')
t.ok(type(manifest) == 'table' and type(manifest.files) == 'table', 'manifest.json is present and lists files')
manifest = manifest or { files = {} }
t.ok(type(manifest.model_id) == 'string' and manifest.model_id ~= '', 'manifest names the model')
t.ok(type(manifest.encoder) == 'string' and manifest.encoder ~= '', 'manifest names the encoder')

local committed, encoderFiles = 0, 0
for path, sum in pairs(manifest.files) do
  t.ok(path == 'localgenres' or path == 'model.json' or path == 'taxonomy.json'
       or path == 'keyword-taxonomy.json' or path:match('^encoders/'),
       'only runtime files ship: ' .. path)
  if path:match('^encoders/') then
    encoderFiles = encoderFiles + 1
    local actual = sha256(MODEL .. '/' .. path)
    if actual then t.eq(actual, sum, 'downloaded encoder file matches the manifest: ' .. path) end
  else
    committed = committed + 1
    t.eq(sha256(MODEL .. '/' .. path), sum, 'committed file matches the manifest: ' .. path)
  end
end
t.eq(committed, manifest.keywords and 4 or 3, 'runtime, model and taxonomies are committed')
if manifest.keywords then
  local kt = Json.decode(readFile(MODEL .. '/keyword-taxonomy.json') or 'null') or {}
  t.eq(kt.version, manifest.keywords.taxonomy_version, 'the keyword taxonomy is the one the manifest names (ADR-030)')
  local text = readFile(MODEL .. '/keyword-taxonomy.json') or ''
  t.ok(not text:find('%f[%w]C%d+%f[%W]') and not text:find('%.md%f[%W]'),
       'the bundled keyword taxonomy refers to no record of the model\'s making')
end
t.ok(encoderFiles > 0, 'the encoder is listed, so a download can be verified')

t.suite('Model bundle — privacy and licences')

local p = io.popen("find '" .. here .. "/../Genreator.lrplugin' -iname '*label*' 2>/dev/null")
local found = p:read('*a')
p:close()
t.eq(found, '', 'no label file anywhere in the bundle')

local modelText = readFile(here .. '/../Genreator.lrplugin/model/model.json') or ''
t.ok(not modelText:find('"/', 1, true) and not modelText:find('"~/', 1, true),
     'the bundled model file records no local path')

local ignore = readFile(here .. '/../.gitignore') or ''
t.contains(ignore, 'Genreator.lrplugin/model/encoders/', 'the encoder is kept out of git')
t.contains(ignore, '*labels*.json', 'label files are kept out of git')

local apache = readFile(here .. '/../licenses/Apache-2.0.txt') or ''
t.contains(apache, 'Apache License', 'the encoder licence text is in the repository')
t.contains(apache, 'Version 2.0, January 2004', 'and it is the full Apache-2.0 text')

-- tools/model.lua against a scratch model folder and bundle: what import copies, and what it
-- and the encoder download refuse.
t.suite('Model bundle — the import tool')

local TMP = '/tmp/genreator-test-model'
local SRC, DEST = TMP .. '/src', TMP .. '/bundle/model'
local TOOL = "GENREATOR_MODEL_DIR='" .. DEST .. "' luajit '" .. here .. "/../tools/model.lua' "

local function sh(cmd)
  local ok = os.execute(cmd .. ' >/dev/null 2>&1')
  return ok == 0 or ok == true
end
local function exists(path) return readFile(path) ~= nil end
local function put(path, s)
  os.execute("mkdir -p '" .. path:match('^(.*)/') .. "'")
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

-- A taxonomy file as a model folder has it: the current text plus the record of its making.
local TAXONOMY = Json.encode {
  version = '2026.01.01-c7', genres = { 'Alpha', 'Beta' }, status = 'adopted (C30)',
  source = 'taxonomy/proposal.md (C18 user text); the grouping is the agent\'s',
  no_genre = 'A photograph may have no genre (C30).',
  replaced_shared_rules_v3 = { 'old rule' },
  definitions = {
    Alpha = { definition = 'Alpha text.', notes = { 'Alpha note.' }, kept_from_v3 = { 'Kept rule.' },
              replaced_definition_v3 = { definition = 'old Alpha' } },
    Beta = { definition = 'Beta text.', notes = {}, c38 = { definition = 'Fuller Beta.' },
             replaced_definition_c18 = { definition = 'old Beta' } },
  },
}

-- `keepBundle`: rebuild the source folder only, leaving the imported bundle in place.
-- `extra`: more manifest fields (personal_floor).
local function makeSource(keepBundle, extra)
  os.execute("rm -rf '" .. (keepBundle and SRC or TMP) .. "'")
  local contents = {
    localgenres = '#!/bin/sh\n', ['model.json'] = '{"genres":[]}', ['taxonomy.json'] = TAXONOMY,
    ['encoders/enc-v1.mlmodelc/weights/weight.bin'] = 'weights',
    ['golden-labels.json'] = '{"items":[]}', ['NOTES.md'] = 'notes',
  }
  local files = {}
  for path, s in pairs(contents) do
    put(SRC .. '/' .. path, s)
    files[path] = sha256(SRC .. '/' .. path)
  end
  local m = { schema_version = 1, version = 'v1', model_id = 'm1',
    taxonomy_version = 't1', encoder = 'enc-v1', runtime_contract = 'test', files = files }
  for k, v in pairs(extra or {}) do m[k] = v end
  put(SRC .. '/manifest.json', Json.encode(m))
end

makeSource()
t.ok(sh(TOOL .. "import '" .. SRC .. "'"), 'import accepts an intact model folder')
t.ok(exists(DEST .. '/model.json') and exists(DEST .. '/encoders/enc-v1.mlmodelc/weights/weight.bin'),
     'runtime files and the encoder are copied')
t.ok(not exists(DEST .. '/golden-labels.json'), 'the label file is left out')
t.ok(not exists(DEST .. '/NOTES.md'), 'files that are not runtime files are left out')
local imported = Json.decode(readFile(DEST .. '/manifest.json') or 'null') or { files = {} }
t.eq(imported.files['golden-labels.json'], nil, 'the bundle manifest does not list the label file')
t.eq(imported.encoder, 'enc-v1', 'the bundle manifest keeps the encoder id')
local tax = Json.decode(readFile(DEST .. '/taxonomy.json') or 'null') or {}
t.eq({ tax.version, tax.genres }, { '2026.01.01-c7', { 'Alpha', 'Beta' } }, 'the taxonomy keeps its version and genres')
t.eq(tax.definitions and tax.definitions.Alpha, { definition = 'Alpha text.', notes = { 'Alpha note.', 'Kept rule.' } },
     '... and the current text, rules kept from an earlier wording among the notes')
t.eq(tax.definitions and tax.definitions.Beta, { definition = 'Beta text.', fuller = { definition = 'Fuller Beta.' } },
     '... a fuller definition under a plain name')
t.eq(tax.no_genre, 'A photograph may have no genre.', 'a record reference in the text is dropped')
t.ok(tax.source == nil and tax.status == nil and tax.replaced_shared_rules_v3 == nil,
     'the record of its making stays out of the bundle')
local bundled = readFile(MODEL .. '/taxonomy.json') or ''
t.ok(not bundled:find('%f[%w]C%d+%f[%W]') and not bundled:find('%.md%f[%W]') and not bundled:find("agent's"),
     'the bundled taxonomy refers to no record of the model\'s making')
t.ok(sh(TOOL .. 'verify'), 'verify passes on the imported bundle')

put(DEST .. '/model.json', '{"tampered":true}')
t.ok(not sh(TOOL .. 'verify'), 'verify fails when a bundled file differs from the manifest')

makeSource()
t.ok(sh(TOOL .. "import '" .. SRC .. "'"), 'import again into a fresh bundle')
put(SRC .. '/model.json', '{"changed":true}')
t.ok(not sh(TOOL .. "import '" .. SRC .. "'"), 'import refuses a folder whose checksum differs')
t.ok(sh(TOOL .. 'verify'), 'and the bundle already there is left intact')

-- A reference inside the current text cannot be cleaned without rewording: refused.
makeSource()
sh(TOOL .. "import '" .. SRC .. "'")
local clean = TAXONOMY
TAXONOMY = TAXONOMY:gsub('Alpha text%.', 'Alpha text, as agreed in C42.')
makeSource(true)
t.ok(not sh(TOOL .. "import '" .. SRC .. "'"), 'import refuses a taxonomy whose text still names a record')
t.ok(sh(TOOL .. 'verify'), '... and leaves the bundle intact')
TAXONOMY = clean

-- The recommended floor for personal photographs travels with the model (ADR-028).
t.eq(imported.personal_floor, nil, 'a model without a personal floor imports without one')
makeSource(false, { personal_floor = 0.5 })
t.ok(sh(TOOL .. "import '" .. SRC .. "'"), 'import accepts a model with a personal floor')
imported = Json.decode(readFile(DEST .. '/manifest.json') or 'null') or {}
t.eq(imported.personal_floor, 0.5, 'the bundle manifest keeps the personal floor')
t.eq(imported.rating, nil, 'a model without a rating head imports without one')
makeSource(false, { rating = { version = 1, default_ratio = '1.5',
                               thresholds = { ['1.5'] = { 0.3, 0.8, 1.4 }, ['2.0'] = { 0.5, 1.1, 1.8 } } } })
t.ok(sh(TOOL .. "import '" .. SRC .. "'"), 'a model with a rating head imports')
imported = Json.decode(readFile(DEST .. '/manifest.json') or 'null') or {}
t.eq(imported.rating and imported.rating.default_ratio, '1.5', 'the bundle manifest keeps the rating head\'s identity (ADR-029)')
t.eq(imported.rating and imported.rating.thresholds['2.0'][3], 1.8, '... with every shipped ratio\'s thresholds')
makeSource(true, { rating = { version = 1, default_ratio = '3', thresholds = { ['1.5'] = { 0.3, 0.8, 1.4 } } } })
t.ok(not sh(TOOL .. "import '" .. SRC .. "'"), 'a rating head whose default ratio is not shipped is refused')
t.ok(sh(TOOL .. 'verify'), '... and leaves the bundle intact')
makeSource(true, { personal_floor = 'high' })
t.ok(not sh(TOOL .. "import '" .. SRC .. "'"), 'import refuses a personal floor that is not a number')
makeSource(true, { personal_floor = 1.5 })
t.ok(not sh(TOOL .. "import '" .. SRC .. "'"), '... or one outside 0 to 1')
t.ok(sh(TOOL .. 'verify'), '... and leaves the bundle intact')

-- The keyword model (ADR-030): its model file in place of the genre one, its taxonomy beside.
local KW = TMP .. '/kw'
local KW_TAXONOMY = Json.encode {
  version = '0.9', source = 'judged in C77', changes = { 'added Boat (C80)' },
  keywords = {
    { id = 'boat', name = 'Boat', category = 'Objects', subcategory = 'Transport', definition = 'A boat.', since = '0.1' },
    { id = 'sailboat', name = 'Sailboat', category = 'Objects', subcategory = 'Transport', fallback = 'boat',
      definition = 'A sailing boat (C94).', definition_by = 'agent' },
  },
}
local function makeKeywords(extra, contents)
  os.execute("rm -rf '" .. KW .. "'")
  local c = { localgenres = '#!/bin/sh\n', ['model.json'] = '{"genres":[],"keywords":{},"training":{"snapshot":"/home/b/build/snap-1/","home":"~/runs/r2","tilde":"~foo","scale":"1/2"}}', ['taxonomy.json'] = KW_TAXONOMY,
              ['encoders/enc-v1.mlmodelc/weights/weight.bin'] = 'weights', ['keyword-labels.json'] = '{"items":[]}' }
  for k, v in pairs(contents or {}) do c[k] = v end
  local files = {}
  for path, s in pairs(c) do
    put(KW .. '/' .. path, s)
    files[path] = sha256(KW .. '/' .. path)
  end
  local m = { schema_version = 1, task = 'keywords', version = 'kv1', model_id = 'm1+kw', genres_model_id = 'm1',
              taxonomy_version = '0.9', runtime_contract = 'keywords', files = files }
  for k, v in pairs(extra or {}) do m[k] = v end
  put(KW .. '/manifest.json', Json.encode(m))
end
local function importBoth() return sh(TOOL .. "import '" .. SRC .. "' '" .. KW .. "'") end

makeSource()
makeKeywords()
t.ok(importBoth(), 'import accepts a genre folder with its keyword folder')
imported = Json.decode(readFile(DEST .. '/manifest.json') or 'null') or { files = {} }
t.eq(readFile(DEST .. '/model.json'), '{"genres":[],"keywords":{},"training":{"snapshot":"snap-1","home":"r2","tilde":"~foo","scale":"1/2"}}',
     'the keyword folder\'s model file is bundled; a local path in it keeps only its last part')
t.eq(imported.version, 'v1', 'the version stays the genre model\'s')
t.eq(imported.model_id, 'm1+kw', 'the model id is the bundled file\'s')
t.eq(imported.keywords, { version = 'kv1', model_id = 'm1+kw', taxonomy_version = '0.9' },
     'the manifest names the keyword model and its taxonomy')
t.eq(Json.decode(readFile(DEST .. '/taxonomy.json') or 'null').version, '2026.01.01-c7', 'the genre taxonomy stays')
local kt = Json.decode(readFile(DEST .. '/keyword-taxonomy.json') or 'null') or {}
t.eq(kt, { version = '0.9', keywords = {
  { id = 'boat', name = 'Boat', category = 'Objects', subcategory = 'Transport', definition = 'A boat.' },
  { id = 'sailboat', name = 'Sailboat', category = 'Objects', subcategory = 'Transport', fallback = 'boat',
    definition = 'A sailing boat.' } } },
  'the keyword taxonomy is published without the record of its making')
t.ok(not exists(DEST .. '/keyword-labels.json'), 'the keyword judgements are left out')
t.ok(sh(TOOL .. 'verify'), 'verify passes on the combined bundle')

makeKeywords { genres_model_id = 'm0' }
t.ok(not importBoth(), 'a keyword model built on another genre model is refused')
makeKeywords({}, { localgenres = '#!/bin/sh\necho other\n' })
t.ok(not importBoth(), '... and one with another runtime')
makeKeywords({}, { ['encoders/enc-v1.mlmodelc/weights/weight.bin'] = 'other weights' })
t.ok(not importBoth(), '... and one with another encoder')
makeKeywords { task = 'genres' }
t.ok(not importBoth(), '... and a folder that is not a keyword model')
t.ok(sh(TOOL .. 'verify'), '... each leaving the bundle intact')
makeSource()
t.ok(sh(TOOL .. "import '" .. SRC .. "'"), 'without a keyword folder')
t.ok(not exists(DEST .. '/keyword-taxonomy.json'), 'the bundle has no keyword head')

t.suite('Model bundle — the encoder download')

makeSource()
sh(TOOL .. "import '" .. SRC .. "'")
local ZIP = TMP .. '/enc.zip'
t.ok(sh(TOOL .. "encoder-zip '" .. ZIP .. "'"), 'the encoder packages')
local listing = io.popen("unzip -l '" .. ZIP .. "'"):read('*a')
t.contains(listing, 'LICENSE', 'the package carries the licence text')
t.contains(listing, 'NOTICE', 'and the statement of changes')

os.execute("rm -rf '" .. DEST .. "/encoders'")
t.ok(sh(TOOL .. "fetch-encoder 'file://" .. ZIP .. "'"), 'the encoder downloads and verifies')
t.ok(sh(TOOL .. 'verify'), 'the bundle is complete after the download')
t.ok(sh(TOOL .. 'encoder-ok'), 'encoder-ok: present and verified')

os.execute("rm -rf '" .. DEST .. "/encoders'")
t.ok(not sh(TOOL .. "fetch-encoder 'file://" .. TMP .. "/missing.zip'"), 'a failed download fails')
t.ok(not exists(DEST .. '/encoders/LICENSE'), 'and leaves no partial encoder')
t.ok(not sh(TOOL .. 'encoder-ok'), 'encoder-ok fails without the encoder, so make install downloads it')

put(TMP .. '/extra/enc-v1.mlmodelc/extra.bin', 'x')
os.execute("cp '" .. ZIP .. "' '" .. TMP .. "/extra.zip' && cd '" .. TMP .. "/extra' && zip -qr ../extra.zip enc-v1.mlmodelc")
t.ok(not sh(TOOL .. "fetch-encoder 'file://" .. TMP .. "/extra.zip'"), 'a file the manifest does not list is refused')
t.ok(not exists(DEST .. '/encoders/enc-v1.mlmodelc/extra.bin'), 'and the refused encoder is removed')

t.suite('Model bundle — the plugin release zip (make release)')

local OUT = TMP .. '/out'
t.ok(not sh(TOOL .. "plugin-zip '" .. OUT .. "'"), 'no release without a verified encoder')
t.ok(sh(TOOL .. "fetch-encoder 'file://" .. ZIP .. "'"), '(the encoder again)')
t.ok(not sh(TOOL .. "plugin-zip '" .. OUT .. "'"), 'no release without a version in Info.lua')
put(TMP .. '/bundle/Info.lua', 'return { VERSION = { major = 1, minor = 2, revision = 3, build = 4 } }')
put(TMP .. '/bundle/GrX.lua', 'return {}')
put(TMP .. '/bundle/.DS_Store', 'x')
put(TMP .. '/bundle/model.new/model.json', '{}')
put(TMP .. '/bundle/notes.txt', 'private')
put(TMP .. '/bundle/model/keyword-labels.json', '{}')
put(TMP .. '/bundle/config.example.json', '{}')
t.ok(sh(TOOL .. "plugin-zip '" .. OUT .. "'"), 'the plugin packages')
listing = io.popen("unzip -l '" .. OUT .. "/Genreator-1.2.3.zip' 2>&1"):read('*a')
t.contains(listing, 'Genreator.lrplugin/GrX.lua', 'named by the version, the plugin folder inside')
t.contains(listing, 'Genreator.lrplugin/model/encoders/enc-v1.mlmodelc/weights/weight.bin', 'the encoder included')
t.contains(listing, 'Genreator.lrplugin/model/manifest.json', 'and the manifest that verifies it')
t.contains(listing, 'Genreator.lrplugin/model/encoders/NOTICE', 'the encoder\'s statement of changes beside it')
t.contains(listing, 'THIRD_PARTY_NOTICES.md', 'the notices beside the plugin')
t.contains(listing, 'licenses/Apache-2.0.txt', 'with the encoder licence')
t.ok(not listing:find('DS_Store', 1, true) and not listing:find('model.new', 1, true)
     and not listing:find('notes.txt', 1, true) and not listing:find('labels', 1, true), 'nothing outside the plugin\'s own files')
t.contains(listing, 'Genreator.lrplugin/config.example.json', 'the config example included')

os.execute("rm -rf '" .. TMP .. "'")

return t
