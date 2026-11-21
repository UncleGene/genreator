--[[
Menu entry: Help > Plug-in Extras > Show Genreator Diagnostics

Makes the manual verification checklist (docs/development.md) checkable from inside
Lightroom: it reports what loaded, the model and taxonomy in use, what config resolved to,
and what the current selection looks like.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils       = import 'LrPathUtils'

LrFunctionContext.postAsyncTaskWithContext('GenreatorDiagnostics', function(context)
  local lines = {}

  -- Lightroom drops errors raised inside an async task without a word. Show the error
  -- together with whatever the report had gathered, so the failing step is identifiable.
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator diagnostics — FAILED',
      table.concat(lines, '\n') .. '\n\nERROR: ' .. tostring(message), 'critical')
  end)

  local function add(fmt, ...)
    if select('#', ...) > 0 then
      lines[#lines + 1] = string.format(fmt, ...)
    else
      lines[#lines + 1] = fmt
    end
  end

  -- Module loading: the first thing that can go wrong in a fresh bundle.
  local modules = {
    'GrJson', 'GrTaxonomy', 'GrConfig', 'GrLog', 'GrMetadata', 'GrRendition', 'GrClassifier',
    'GrModel', 'GrCli', 'GrReport', 'GrKeywords', 'GrReview', 'GrCollections', 'GrApproved',
  }
  local failed = {}
  for _, name in ipairs(modules) do
    local ok, err = pcall(require, name)
    if not ok then failed[#failed + 1] = string.format('%s (%s)', name, tostring(err)) end
  end

  if #failed > 0 then
    add('MODULE LOAD FAILURES:')
    for _, f in ipairs(failed) do add('  - %s', f) end
    LrDialogs.message('Genreator diagnostics', table.concat(lines, '\n'), 'critical')
    return
  end

  add('Modules: all %d loaded.', #modules)

  local Taxonomy = require 'GrTaxonomy'
  local Model    = require 'GrModel'
  local Metadata = require 'GrMetadata'

  add('')
  local m = Model.manifest() or {}
  add('Model: %s (%s)', tostring(m.version), tostring(m.model_id))
  local present, missing = Model.check()
  add('Model files: %s', present and 'complete' or ('INCOMPLETE — ' .. tostring(missing)))
  local floor = Model.personalFloor(m)
  add('Personal floor: %s', floor and tostring(floor) or 'none (this model has no recommended floor)')
  add('Rating head: %s', type(m.rating) == 'table' and string.format('yes, default ratio %s', tostring(m.rating.default_ratio))
                        or 'none (this model suggests no rating)')
  local KT = require 'GrKeywordTaxonomy'
  local kwOk, kwWhy = KT.load(Model.dir())
  add('Keyword head: %s', (kwOk and type(m.keywords) == 'table')
      and string.format('yes, model %s, keyword taxonomy %s (%d keywords)', tostring(m.keywords.version),
                        tostring(KT.version), #KT.keywords)
      or ('none (' .. tostring(kwWhy or 'the manifest names none') .. ')'))
  add('Taxonomy %s: %s', Taxonomy.version, table.concat(Taxonomy.genres, ', '))

  -- Config.
  add('')
  local cfg, cfgErr = require('GrConfig').load()
  if not cfg then
    add('CONFIG: not usable')
    add('%s', tostring(cfgErr))
  else
    add('CONFIG: %s', tostring(cfg._path))
    add('  renditionLongEdge   : %d px', cfg.renditionLongEdge)
    add('  jpegQuality         : %s', tostring(cfg.jpegQuality))
    add('  chunkSize           : %d', cfg.chunkSize)
    add('  modelTimeoutSeconds : %d', cfg.modelTimeoutSeconds)
    add('  logLevel            : %s', tostring(cfg.logLevel))
    add('  personalKeyword     : %s', table.concat(cfg.personalPath, ' > '))
    add('  personalFloor       : %s', tostring(cfg.personalFloor))
    local ratio, why = Model.ratingRatio(m, cfg.ratingRatio)
    add('  ratingRatio         : %s (%s)', tostring(cfg.ratingRatio), ratio and ('ratio ' .. ratio) or tostring(why))
    add('  keywordRule         : %s', tostring(cfg.keywordRule))
  end

  -- Temp path, so the manual check for leftover renditions knows where to look.
  add('')
  add('Temp base: %s', tostring(LrPathUtils.getStandardFilePath('temp')))

  -- Selection.
  add('')
  local catalog = LrApplication.activeCatalog()
  local selected = catalog:getTargetPhotos() or {}
  add('Selected photographs: %d', #selected)

  local states = {}
  local shown = 0
  for _, photo in ipairs(selected) do
    local state = Metadata.reviewState(photo)
    states[state] = (states[state] or 0) + 1
    if shown < 5 then
      shown = shown + 1
      local genre = Metadata.get(photo, Metadata.FIELDS.aiGenre)
      local ranking = Metadata.get(photo, Metadata.FIELDS.aiRanking)
      local bucket = Metadata.get(photo, Metadata.FIELDS.ratingBucket)
      add('  %d. state=%s suggested=%s ranking=%s rating=%s',
          shown, state,
          (genre ~= nil and genre ~= '') and genre or '-',
          (ranking ~= nil and ranking ~= '') and ranking or '-',
          (bucket ~= nil and bucket ~= '') and bucket or '-')
    end
  end
  if #selected > shown then
    add('  ... and %d more', #selected - shown)
  end
  if next(states) then
    local parts = {}
    for state, n in pairs(states) do
      parts[#parts + 1] = string.format('%s=%d', state, n)
    end
    table.sort(parts)
    add('State counts: %s', table.concat(parts, ' '))
  end

  -- The model's inputs (ADR-023, ADR-024): counts only, never keyword names.
  if #selected > 0 then
    local personal, preTagged = 0, 0
    for i = 1, math.min(#selected, 200) do
      local inp = Metadata.inputsOf(selected[i], cfg and cfg.personalPath
        or require('GrConfig').keywordPath(require('GrConfig').defaults.personalKeyword))
      if inp.personal then personal = personal + 1 end
      if #inp.preTags > 0 then preTagged = preTagged + 1 end
    end
    add('Of the first %d: tagged Personal %d, with a genre keyword %d',
        math.min(#selected, 200), personal, preTagged)
  end

  LrDialogs.message('Genreator diagnostics', table.concat(lines, '\n'), 'info')
end)
