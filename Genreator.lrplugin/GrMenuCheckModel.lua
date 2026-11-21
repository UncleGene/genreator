--[[
Menu entry: File > Plug-in Extras > Check Model

Checks the bundled model is complete (GrModel.check) and that its runtime starts: one call
with no photographs, which reads the model file and answers with its identity.
]]

local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'

LrFunctionContext.postAsyncTaskWithContext('GenreatorCheckModel', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: Check Model failed', tostring(message), 'critical')
  end)

  local Config    = require 'GrConfig'
  local Model     = require 'GrModel'
  local Rendition = require 'GrRendition'
  local Taxonomy  = require 'GrTaxonomy'

  local cfg, cfgErr = Config.load()
  if not cfg then
    LrDialogs.message('Genreator: configuration problem', tostring(cfgErr), 'critical')
    return
  end
  local ok, err = Model.check()
  if not ok then
    LrDialogs.message('Genreator: the model is not installed', err, 'critical')
    return
  end

  local dir = Rendition.createTempDir('check-' .. os.time())
  context:addCleanupHandler(function() Rendition.removeTempDir(dir) end)
  local results, code, msg = Model.run({}, dir, cfg)
  if not results then
    LrDialogs.message('Genreator: the model does not run',
                      string.format('%s: %s\n\n%s', tostring(code), tostring(msg), Model.quarantineHint()), 'critical')
    return
  end
  local m = Model.manifest() or {}
  local ratio = Model.ratingRatio(m, cfg.ratingRatio)
  local KT = require 'GrKeywordTaxonomy'
  local kwOk = KT.load(Model.dir()) and type(m.keywords) == 'table'
  LrDialogs.message('Genreator: the model is ready', string.format(
    'Model %s\nTaxonomy %s: %s\nSuggested rating: %s\nSuggested keywords: %s\n\nEverything runs on this computer.',
    tostring(m.version), Taxonomy.version, table.concat(Taxonomy.genres, ', '),
    ratio and string.format('yes, bucket ratio %s (setting: %s)', ratio, tostring(cfg.ratingRatio))
          or 'no (this model has no rating head)',
    kwOk and string.format('yes, %d keywords, keyword taxonomy %s (rule: %s)', #KT.keywords, tostring(KT.version),
                           tostring(cfg.keywordRule))
         or 'no (this model has no keyword head)'), 'info')
end)
