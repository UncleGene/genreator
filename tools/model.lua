--[[
Model bundle tool, run by make (never by Lightroom). LuaJIT, with GrJson from the bundle.

  luajit tools/model.lua import <folder> [<keyword folder>]
                                                copy a model folder into the bundle; with a
                                                keyword folder, its model file (genres, rating
                                                and keywords in one call, ADR-030)
  luajit tools/model.lua verify                 check every bundled file against the manifest
  luajit tools/model.lua encoder-id             print the encoder id
  luajit tools/model.lua encoder-zip <out.zip>  package the encoder with its licence
  luajit tools/model.lua encoder-ok             exit 0 when the encoder is present and verified
  luajit tools/model.lua fetch-encoder <url>    download and unpack the encoder, then verify
  luajit tools/model.lua plugin-zip <folder>    package the whole plugin for a release

The encoder is too large for git (GitHub refuses files over 100 MB), so it is published as a
release asset and fetched by `make install`; everything else in model/ is committed.
]]

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'
package.path = root .. '/Genreator.lrplugin/?.lua;' .. package.path

local Json = require 'GrJson'

-- GENREATOR_MODEL_DIR lets the tests run the tool against a scratch folder.
local MODEL_DIR = os.getenv('GENREATOR_MODEL_DIR') or (root .. '/Genreator.lrplugin/model')
local MANIFEST = MODEL_DIR .. '/manifest.json'
local APACHE = root .. '/licenses/Apache-2.0.txt'

-- Files of a model folder that ship in the bundle. Anything else in the folder (notes,
-- per-photo labels, parity reports) stays out: the labels are private and must never be
-- committed.
local SHIPPED = { localgenres = true, ['model.json'] = true, ['taxonomy.json'] = true }
local function shipped(path)
  return SHIPPED[path] or path:match('^encoders/') ~= nil
end

local function die(msg)
  io.stderr:write('model: ', msg, '\n')
  os.exit(1)
end

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function try(cmd)
  local ok = os.execute(cmd)
  return ok == 0 or ok == true
end

local function run(cmd)
  if not try(cmd) then die('command failed: ' .. cmd) end
end

local function readFile(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return s
end

local function writeFile(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

local function sha256(path)
  local p = io.popen('shasum -a 256 ' .. q(path) .. ' 2>/dev/null')
  local out = p:read('*a')
  p:close()
  return out:match('^(%x+)')
end

-- zip resolves its output relative to the folder it runs in, so callers pass an absolute path.
local function absolute(path)
  if path:sub(1, 1) == '/' then return path end
  local p = io.popen('pwd')
  local cwd = p:read('*l')
  p:close()
  return cwd .. '/' .. path
end

local function readManifest(path)
  local s = readFile(path)
  if not s then die('no manifest at ' .. path) end
  local ok, m = pcall(Json.decode, s)
  if not ok or type(m) ~= 'table' or type(m.files) ~= 'table' then die('unreadable manifest ' .. path) end
  return m
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- Returns the list of mismatches; `skip(path)` leaves a file out of the check.
local function check(dir, files, skip)
  local bad = {}
  for _, path in ipairs(sortedKeys(files)) do
    if not (skip and skip(path)) then
      local actual = sha256(dir .. '/' .. path)
      if actual ~= files[path] then
        bad[#bad + 1] = path .. (actual and ' (checksum differs)' or ' (missing)')
      end
    end
  end
  return bad
end

-- ---------------------------------------------------------- the published taxonomy

-- The model folder's taxonomy.json also records how its text was arrived at: the decision
-- records it came from, earlier wordings, file names. That history belongs to the model's
-- making, not to the plugin (CLAUDE.md), so the bundle carries the taxonomy in its published
-- form: the genres and their current text only. The runtime does not read this file; the
-- plugin reads `version` and `genres`, docs/taxonomy.md the text.
local TOP = { 'version', 'genres', 'central_principle', 'shared_rules', 'no_genre', 'definitions' }
-- A reference to a record of the model's making: "(C30)", "C39", "proposal-….md".
-- The version keeps its own suffix ("2026.10.27-c39"): model.json names the taxonomy by it.
local RECORD = { '%f[%w]C%d+%f[%W]', '[%w%-_/]+%.md%f[%W]', 'counterfactual', "agent's" }

local function scrub(v)
  if type(v) == 'string' then
    -- "… allowed on any (C30)." -> "… allowed on any."
    return (v:gsub('%s*%(C%d+[^)]*%)', ''))
  elseif type(v) == 'table' then
    local out = {}
    for k, x in pairs(v) do out[k] = scrub(x) end
    return setmetatable(out, getmetatable(v))
  end
  return v
end

local function definition(d)
  if type(d) ~= 'table' then return d end
  local out = { definition = d.definition, notes = {} }
  for _, n in ipairs(d.notes or {}) do out.notes[#out.notes + 1] = n end
  for k, v in pairs(d) do
    -- Rules kept from an earlier wording are rules of the current one.
    if type(k) == 'string' and k:match('^kept_from_') and type(v) == 'table' then
      for _, n in ipairs(v) do out.notes[#out.notes + 1] = n end
    -- A fuller definition stored under its record's id ("c38").
    elseif type(k) == 'string' and k:match('^c%d+$') and type(v) == 'table' then
      out.fuller = v
    end
  end
  if #out.notes == 0 then out.notes = nil end
  return Json.ordered({ 'definition', 'notes', 'fuller' }, out)
end

-- The model file may record where it was built: a local path (a training snapshot's folder)
-- names the builder's machine and folders. Each string that is an absolute or home path
-- keeps only its last part; every other byte stays, so the weights are untouched. A string
-- with an escaped quote is not recognised (the model files carry none); the bundle test
-- refuses any path left.
local function publicModelFile(path)
  local text = readFile(path) or ''
  local cleaned = text:gsub('"([/~][^"]*)"', function(p)
    if p:sub(1, 1) == '~' and p:sub(2, 2) ~= '/' then return nil end
    return '"' .. (p:match('([^/]+)/*$') or '') .. '"'
  end)
  if cleaned ~= text then writeFile(path, cleaned) end
end

--- The published form of a taxonomy file's text, or nil and the references left in it.
local function publicTaxonomy(text)
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= 'table' then return nil, 'taxonomy.json is not JSON' end
  local out = {}
  for _, k in ipairs(TOP) do out[k] = data[k] end
  if type(data.definitions) == 'table' then
    out.definitions = {}
    for g, d in pairs(data.definitions) do out.definitions[g] = definition(d) end
  end
  local encoded = Json.encode(Json.ordered(TOP, scrub(out))) .. '\n'
  local left = {}
  for _, pattern in ipairs(RECORD) do
    for m in encoded:gmatch(pattern) do left[#left + 1] = m end
  end
  if #left > 0 then return nil, 'references to its making remain: ' .. table.concat(left, ', ') end
  return encoded
end

-- ---------------------------------------------------------- the keyword taxonomy (ADR-030)

local KEYWORD_FIELDS = { 'id', 'name', 'category', 'subcategory', 'fallback', 'definition' }

--- The published keyword taxonomy: its version and keywords, each with the fields above only.
-- The folder's file also records its making (sources, changes, rules with record ids).
local function publicKeywordTaxonomy(text)
  local ok, data = pcall(Json.decode, text)
  if not ok or type(data) ~= 'table' then return nil, 'taxonomy.json is not JSON' end
  if type(data.version) ~= 'string' or type(data.keywords) ~= 'table' then
    return nil, 'taxonomy.json has no version or keywords'
  end
  local keywords = {}
  for _, k in ipairs(data.keywords) do
    if type(k) ~= 'table' then return nil, 'a keyword is not an object' end
    local out = {}
    for _, f in ipairs(KEYWORD_FIELDS) do
      if k[f] ~= nil and k[f] ~= Json.null then out[f] = k[f] end
    end
    keywords[#keywords + 1] = Json.ordered(KEYWORD_FIELDS, scrub(out))
  end
  local encoded = Json.encode(Json.ordered({ 'version', 'keywords' },
    { version = data.version, keywords = Json.array(keywords) })) .. '\n'
  local left = {}
  for _, pattern in ipairs(RECORD) do
    for m in encoded:gmatch(pattern) do left[#left + 1] = m end
  end
  if #left > 0 then return nil, 'references to its making remain: ' .. table.concat(left, ', ') end
  return encoded
end

--- Check a keyword folder against the genre folder it is paired with: its own checksums, its
-- genre model, and the same runtime and encoder. Returns its manifest.
local function keywordSource(kwFrom, src)
  local kw = readManifest(kwFrom .. '/manifest.json')
  local bad = check(kwFrom, kw.files)
  if #bad > 0 then die('refusing ' .. kwFrom .. ': ' .. table.concat(bad, ', ')) end
  if kw.task ~= 'keywords' then die('refusing ' .. kwFrom .. ': not a keyword model (task ' .. tostring(kw.task) .. ')') end
  if kw.genres_model_id ~= src.model_id then
    die(string.format('refusing %s: its genre model is %s, the genre folder holds %s',
                      kwFrom, tostring(kw.genres_model_id), tostring(src.model_id)))
  end
  if not kw.files['model.json'] or not kw.files['taxonomy.json'] then
    die('refusing ' .. kwFrom .. ': no model.json or taxonomy.json')
  end
  for path, sum in pairs(src.files) do
    if (path == 'localgenres' or path:match('^encoders/')) and kw.files[path] ~= sum then
      die('refusing ' .. kwFrom .. ': ' .. path .. ' differs from the genre folder\'s')
    end
  end
  for path in pairs(kw.files) do
    if path:match('^encoders/') and not src.files[path] then
      die('refusing ' .. kwFrom .. ': ' .. path .. ' is not in the genre folder')
    end
  end
  return kw
end

local commands = {}

function commands.import(from, kwFrom)
  if not from or from == '' then die('usage: make model FROM=<model folder> [KEYWORDS=<keyword folder>]') end
  local src = readManifest(from .. '/manifest.json')
  local bad = check(from, src.files)
  if #bad > 0 then die('refusing ' .. from .. ': ' .. table.concat(bad, ', ')) end
  if kwFrom == '' then kwFrom = nil end
  local kw = kwFrom and keywordSource(kwFrom, src)

  local files = {}
  for path, sum in pairs(src.files) do
    if shipped(path) then files[path] = sum end
  end
  if not files.localgenres or not files['model.json'] or not files['taxonomy.json'] then
    die('model folder lacks localgenres, model.json or taxonomy.json')
  end

  -- Build beside the bundle and swap at the end, so a failed copy leaves the old model intact.
  local stage = MODEL_DIR .. '.new'
  run('rm -rf ' .. q(stage) .. ' && mkdir -p ' .. q(stage .. '/encoders'))
  for _, path in ipairs(sortedKeys(files)) do
    local target = stage .. '/' .. path
    run('mkdir -p ' .. q(target:match('^(.*)/')) .. ' && cp ' .. q(from .. '/' .. path) .. ' ' .. q(target))
  end
  run('chmod 755 ' .. q(stage .. '/localgenres'))

  local taxonomy, why = publicTaxonomy(readFile(stage .. '/taxonomy.json') or '')
  if not taxonomy then
    run('rm -rf ' .. q(stage))
    die('refusing ' .. from .. ': taxonomy.json: ' .. why .. ' (clean it where the model is built)')
  end
  writeFile(stage .. '/taxonomy.json', taxonomy)
  files['taxonomy.json'] = sha256(stage .. '/taxonomy.json')

  -- The keyword model (ADR-030): its model file serves the genres, the rating and the keywords
  -- in one call; its keyword taxonomy goes beside the genre one, in published form.
  local keywords, modelId = nil, src.model_id
  if kw then
    run('cp ' .. q(kwFrom .. '/model.json') .. ' ' .. q(stage .. '/model.json'))
    local kwTaxonomy, kwWhy = publicKeywordTaxonomy(readFile(kwFrom .. '/taxonomy.json') or '')
    if not kwTaxonomy then
      run('rm -rf ' .. q(stage))
      die('refusing ' .. kwFrom .. ': taxonomy.json: ' .. kwWhy)
    end
    writeFile(stage .. '/keyword-taxonomy.json', kwTaxonomy)
    files['keyword-taxonomy.json'] = sha256(stage .. '/keyword-taxonomy.json')
    keywords = Json.ordered({ 'version', 'model_id', 'taxonomy_version' },
      { version = kw.version, model_id = kw.model_id, taxonomy_version = kw.taxonomy_version })
    modelId = kw.model_id
    src.runtime_contract = kw.runtime_contract or src.runtime_contract
  end

  publicModelFile(stage .. '/model.json')
  files['model.json'] = sha256(stage .. '/model.json')

  -- The recommended floor for personal photographs (ADR-028) comes with the model: a version
  -- without one has none, and one that is not an applicability is refused, not dropped.
  local floor = src.personal_floor
  if floor == Json.null then floor = nil end
  if floor ~= nil and (type(floor) ~= 'number' or floor < 0 or floor > 1) then
    run('rm -rf ' .. q(stage))
    die('refusing ' .. from .. ': personal_floor must be a number from 0 to 1')
  end

  -- The rating head's identity (ADR-029): the shipped bucket ratios with their thresholds and
  -- the default ratio. The plugin reads them here, not from the large model file; a model
  -- without a rating head has none, and a malformed block is refused, not dropped.
  local rating = src.rating
  if rating == Json.null then rating = nil end
  if rating ~= nil and (type(rating) ~= 'table' or type(rating.default_ratio) ~= 'string'
                        or type(rating.thresholds) ~= 'table' or rating.thresholds[rating.default_ratio] == nil) then
    run('rm -rf ' .. q(stage))
    die('refusing ' .. from .. ': rating must name its default ratio among its thresholds')
  end

  writeFile(stage .. '/manifest.json', Json.encode(Json.ordered(
    { 'schema_version', 'version', 'model_id', 'taxonomy_version', 'encoder', 'runtime_contract',
      'personal_floor', 'rating', 'keywords', 'files' },
    {
      schema_version = src.schema_version, version = src.version, model_id = modelId,
      taxonomy_version = src.taxonomy_version, encoder = src.encoder,
      runtime_contract = src.runtime_contract, personal_floor = floor, rating = rating, keywords = keywords,
      files = files,
    })) .. '\n')
  run('rm -rf ' .. q(MODEL_DIR) .. ' && mv ' .. q(stage) .. ' ' .. q(MODEL_DIR))
  io.write('Imported model ', tostring(src.version), kw and (' with keywords ' .. tostring(kw.version)) or '',
           ' into ', MODEL_DIR, '\n')
end

function commands.verify()
  local m = readManifest(MANIFEST)
  local bad = check(MODEL_DIR, m.files)
  if #bad > 0 then die('bundled model does not match its manifest: ' .. table.concat(bad, ', ')) end
  io.write('Model ', tostring(m.version), ': every file matches the manifest\n')
end

commands['encoder-id'] = function()
  io.write(readManifest(MANIFEST).encoder, '\n')
end

local NOTICE = [[
%s.mlmodelc

The image tower of SigLIP2 base patch16/256 by Google, published under the Apache License,
Version 2.0 (LICENSE in this folder). Modified: converted to Core ML and compiled; only the
image tower is included. The weights were not retrained.

Source: https://huggingface.co/google/siglip2-base-patch16-256
]]

-- The encoder's licence and statement of changes, beside it in every package that carries it.
local function writeEncoderNotices(m)
  if not readFile(APACHE) then die('missing ' .. APACHE) end
  writeFile(MODEL_DIR .. '/encoders/NOTICE', NOTICE:format(m.encoder))
  run('cp ' .. q(APACHE) .. ' ' .. q(MODEL_DIR .. '/encoders/LICENSE'))
end

commands['encoder-zip'] = function(out)
  if not out or out == '' then die('usage: encoder-zip <out.zip>') end
  local m = readManifest(MANIFEST)
  local bad = check(MODEL_DIR, m.files, function(path) return not path:match('^encoders/') end)
  if #bad > 0 then die('encoder does not match the manifest: ' .. table.concat(bad, ', ')) end
  writeEncoderNotices(m)
  local enc = MODEL_DIR .. '/encoders'
  run('mkdir -p ' .. q(out:match('^(.*)/') or '.') .. ' && rm -f ' .. q(out))
  -- zip resolves the output relative to the encoders folder, so pass an absolute path.
  local abs = absolute(out)
  run('cd ' .. q(enc) .. ' && zip -qrX ' .. q(abs) .. ' LICENSE NOTICE ' .. q(m.encoder .. '.mlmodelc'))
  io.write('Wrote ', out, '\n')
end

commands['encoder-ok'] = function()
  local m = readManifest(MANIFEST)
  local bad = check(MODEL_DIR, m.files, function(path) return not path:match('^encoders/') end)
  os.exit(#bad == 0 and 0 or 1)
end

commands['fetch-encoder'] = function(url)
  if not url or url == '' then die('usage: fetch-encoder <url>') end
  local m = readManifest(MANIFEST)
  local enc = MODEL_DIR .. '/encoders'
  local bad = check(MODEL_DIR, m.files, function(path) return not path:match('^encoders/') end)
  if #bad == 0 then
    io.write('Encoder ', m.encoder, ' already present\n')
    return
  end
  local zip = os.tmpname()
  io.write('Downloading encoder ', m.encoder, ' (about 170 MB)\n')
  local fetched = try('curl -fL --progress-bar -o ' .. q(zip) .. ' ' .. q(url))
    and try('rm -rf ' .. q(enc) .. ' && mkdir -p ' .. q(enc) .. ' && unzip -q ' .. q(zip) .. ' -d ' .. q(enc))
  os.remove(zip)
  if not fetched then
    run('rm -rf ' .. q(enc))
    die('could not download or unpack ' .. url)
  end
  bad = check(MODEL_DIR, m.files, function(path) return not path:match('^encoders/') end)
  -- Core ML would load any file in the folder, so a file the manifest does not list is refused.
  local p = io.popen('cd ' .. q(MODEL_DIR) .. ' && find encoders -type f')
  for path in p:lines() do
    if not m.files[path] and path ~= 'encoders/LICENSE' and path ~= 'encoders/NOTICE' then
      bad[#bad + 1] = path .. ' (not in the manifest)'
    end
  end
  p:close()
  if #bad > 0 then
    run('rm -rf ' .. q(enc))
    die('downloaded encoder does not match the manifest, removed: ' .. table.concat(bad, ', '))
  end
  io.write('Encoder ', m.encoder, ' installed and verified\n')
end

-- The release users install (ADR-026): the whole plugin folder, encoder included, with the
-- licence and notice files beside it, named by the plugin's version in Info.lua.
commands['plugin-zip'] = function(outDir)
  if not outDir or outDir == '' then die('usage: plugin-zip <out folder>') end
  local m = readManifest(MANIFEST)
  local bad = check(MODEL_DIR, m.files)
  if #bad > 0 then die('the model does not match the manifest: ' .. table.concat(bad, ', ')) end
  local plugin = MODEL_DIR .. '/..'
  local ok, info = pcall(dofile, plugin .. '/Info.lua')
  local v = ok and type(info) == 'table' and info.VERSION
  if type(v) ~= 'table' then die('no VERSION in ' .. plugin .. '/Info.lua') end
  local name = string.format('Genreator-%d.%d.%d', v.major, v.minor, v.revision)

  writeEncoderNotices(m)
  local stage = os.tmpname()
  -- A failed step removes the stage folder: it holds a copy of the encoder.
  local function step(cmd)
    if not try(cmd) then
      try('rm -rf ' .. q(stage))
      die('command failed: ' .. cmd)
    end
  end
  step('rm -f ' .. q(stage) .. ' && mkdir -p ' .. q(stage .. '/Genreator.lrplugin'))
  -- Only what the plugin is made of: its Lua files, the config example, and the model files
  -- the manifest lists with the encoder's licence and notice. Nothing else in the folder —
  -- notes, labels, staging copies — can reach a public zip.
  local dest = stage .. '/Genreator.lrplugin'
  step('cd ' .. q(plugin) .. ' && cp -p *.lua config.example.json ' .. q(dest))
  local paths = sortedKeys(m.files)
  paths[#paths + 1] = 'manifest.json'
  paths[#paths + 1] = 'encoders/LICENSE'
  paths[#paths + 1] = 'encoders/NOTICE'
  for _, path in ipairs(paths) do
    local to = dest .. '/model/' .. path
    step('mkdir -p ' .. q(to:match('^(.*)/')) .. ' && cp -p ' .. q(MODEL_DIR .. '/' .. path) .. ' ' .. q(to))
  end
  step('cp -R ' .. q(root .. '/LICENSE') .. ' ' .. q(root .. '/THIRD_PARTY_NOTICES.md') .. ' '
      .. q(root .. '/licenses') .. ' ' .. q(stage))
  step('mkdir -p ' .. q(outDir))
  local out = absolute(outDir .. '/' .. name .. '.zip')
  step('rm -f ' .. q(out) .. ' && cd ' .. q(stage) .. ' && zip -qrX ' .. q(out) .. ' .')
  run('rm -rf ' .. q(stage))
  io.write('Wrote ', out, '\n')
end

local cmd = commands[arg[1] or '']
if not cmd then die('unknown command ' .. tostring(arg[1]) .. ' (see the header of tools/model.lua)') end
cmd(arg[2], arg[3])
