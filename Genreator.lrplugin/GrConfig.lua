--[[
GrConfig — configuration loading (ADR-008).

An optional JSON file, `~/.config/genreator/config.json`, overrides the defaults below. The
plugin needs no keys or accounts: every value has a default, so a missing file is fine.
Keys the plugin no longer uses (from earlier versions) are ignored.

`parse` is pure and unit-tested. `load` touches the filesystem.
]]

local Config = {}

Config.DEFAULT_RELATIVE_PATH = '.config/genreator/config.json'

Config.defaults = {
  -- The model was trained on Lightroom previews of about 1,000 px or more; it works at
  -- 256 px, so a larger rendition only costs time.
  renditionLongEdge     = 1024,
  jpegQuality           = 0.8,

  -- Photographs per model call. The model loads its encoder once per call (about 2 s), so
  -- larger chunks are faster; smaller ones write results to the catalog sooner.
  chunkSize             = 50,
  modelTimeoutSeconds   = 600,

  -- The keyword that marks a photograph personal (ADR-024): that keyword or any keyword
  -- nested under it. A nested one is written as a path, `Parent > Child`.
  personalKeyword       = '#PERSONAL',

  -- Genres on personal photographs (ADR-028): 'recommended' holds them to the model's
  -- recommended floor as well as its cut-offs; 'off' uses the cut-offs alone. A model without
  -- a floor uses its cut-offs either way.
  personalFloor         = 'recommended',

  -- The suggested rating's bucket ratio (ADR-029): 'recommended' takes the model's default;
  -- a number names a ratio the model ships (1.5, 2 or 3 today). Each star bucket is 1/ratio the
  -- size of the one below, so a smaller ratio means more candidates for 3 stars.
  ratingRatio           = 'recommended',

  -- The keyword suggestion's rule (ADR-030): 'balanced' (the model's best F1, the default) or
  -- 'recall_first' (more keywords suggested, more of them wrong).
  keywordRule           = 'balanced',

  logLevel              = 'info',
}

local VALID_LOG_LEVELS = { error = true, warn = true, info = true, debug = true }

local function isPositiveNumber(v)
  return type(v) == 'number' and v == v and v > 0
end

--- Pure: "Parent > Child" -> { 'Parent', 'Child' }; nil when a segment is empty.
function Config.keywordPath(text)
  if type(text) ~= 'string' then return nil end
  local path = {}
  for seg in (text .. '>'):gmatch('([^>]*)>') do
    seg = seg:gsub('^%s+', ''):gsub('%s+$', '')
    if seg == '' then return nil end
    path[#path + 1] = seg
  end
  return #path > 0 and path or nil
end

--- Parse and validate a decoded config table, applying defaults.
-- @param raw table decoded config (may be nil/empty)
-- @return cfg table on success; or nil, errorMessage
function Config.parse(raw)
  if raw ~= nil and type(raw) ~= 'table' then
    return nil, 'config root must be a JSON object'
  end
  raw = raw or {}

  local cfg = {}
  for k, v in pairs(Config.defaults) do cfg[k] = v end
  -- JSON null means "not set": keep the default rather than storing the sentinel.
  local null = require('GrJson').null
  for k, v in pairs(raw) do
    if v ~= null and Config.defaults[k] ~= nil then cfg[k] = v end
  end

  if not isPositiveNumber(cfg.renditionLongEdge) or cfg.renditionLongEdge < 256 then
    return nil, 'renditionLongEdge must be a number >= 256'
  end
  if type(cfg.jpegQuality) ~= 'number' or cfg.jpegQuality <= 0 or cfg.jpegQuality > 1 then
    return nil, 'jpegQuality must be a number in (0, 1] — the SDK uses 0..1, not 0..100'
  end
  if not isPositiveNumber(cfg.chunkSize) then
    return nil, 'chunkSize must be a positive number'
  end
  if not isPositiveNumber(cfg.modelTimeoutSeconds) then
    return nil, 'modelTimeoutSeconds must be a positive number'
  end
  cfg.personalPath = Config.keywordPath(cfg.personalKeyword)
  if not cfg.personalPath then
    return nil, 'personalKeyword must be a keyword name, or a path such as "Parent > Child"'
  end
  if cfg.personalFloor ~= 'recommended' and cfg.personalFloor ~= 'off' then
    return nil, string.format('personalFloor %q is not one of: recommended, off', tostring(cfg.personalFloor))
  end
  if cfg.ratingRatio ~= 'recommended' and not (tonumber(cfg.ratingRatio) and tonumber(cfg.ratingRatio) > 1) then
    return nil, string.format('ratingRatio %q is not "recommended" or a bucket ratio above 1 (such as 1.5, 2 or 3)',
                              tostring(cfg.ratingRatio))
  end
  if cfg.keywordRule ~= 'balanced' and cfg.keywordRule ~= 'recall_first' then
    return nil, string.format('keywordRule %q is not one of: balanced, recall_first', tostring(cfg.keywordRule))
  end
  if not VALID_LOG_LEVELS[cfg.logLevel] then
    return nil, string.format('logLevel %q is not one of: error, warn, info, debug',
                              tostring(cfg.logLevel))
  end
  return cfg
end

-- ---------------------------------------------------------------- filesystem

--- Resolve the config file path. Honours GENREATOR_CONFIG for testing.
function Config.path()
  local LrPathUtils = import 'LrPathUtils'
  -- Lightroom's embedded Lua has no os.getenv; the override exists for tests only.
  local override = os.getenv and os.getenv('GENREATOR_CONFIG')
  if override and override ~= '' then return override end
  local home = LrPathUtils.getStandardFilePath('home')
  return LrPathUtils.child(home, Config.DEFAULT_RELATIVE_PATH)
end

--- Load and validate the config file; the defaults when there is none.
-- @return cfg, path on success; or nil, errorMessage, path
function Config.load()
  local LrFileUtils = import 'LrFileUtils'
  local Json = require 'GrJson'

  local path = Config.path()
  local raw = {}
  if LrFileUtils.exists(path) then
    local contents = LrFileUtils.readFile(path)
    if contents and contents ~= '' then
      local decoded, decodeErr = Json.decode(contents)
      if not decoded then
        return nil, string.format('Config file is not valid JSON (%s): %s', decodeErr, path), path
      end
      raw = decoded
    end
  end

  local cfg, parseErr = Config.parse(raw)
  if not cfg then
    return nil, string.format('Config error: %s\nFile: %s', parseErr, path), path
  end
  cfg._path = path
  return cfg, path
end

return Config
