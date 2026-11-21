--[[
Menu entry: File > Plug-in Extras > Set Up Review Collections

Creates the "Genreator" collection set with the review smart collections and the grids by
Primary Genre and by Genre (GrCollections), and the Personal keyword (config
`personalKeyword`, ADR-024) when it does not exist yet. Safe to run again: adds what is
missing, repairs collection rules, and removes the plugin's own collections an earlier
version made under other names.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks           = import 'LrTasks'

LrFunctionContext.postAsyncTaskWithContext('GenreatorSetUpCollections', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: review collections failed', tostring(message), 'critical')
  end)

  local cfg, cfgErr = require('GrConfig').load()
  if not cfg then
    LrDialogs.message('Genreator: configuration problem', tostring(cfgErr), 'critical')
    return
  end
  local Collections = require 'GrCollections'
  local Keywords    = require 'GrKeywords'
  local personal = table.concat(cfg.personalPath, ' > ')
  local catalog = LrApplication.activeCatalog()
  -- Smart-collection criteria name the plugin by its id string, not the _PLUGIN object.
  local names = Collections.setUp(catalog, _PLUGIN.id)
  local ok, err = LrTasks.pcall(function()
    catalog:withWriteAccessDo('Genreator: Personal keyword', function() Keywords.ensurePath(catalog, cfg.personalPath) end,
                              { timeout = 30 })
  end)
  if not ok then error('could not create the Personal keyword: ' .. tostring(err), 0) end

  LrDialogs.message('Genreator: review collections ready', string.format(
    '%d collections in "%s"; the Personal keyword is %s.\n\n'
    .. 'Before classifying, tag your personal photographs with %s or a keyword under it: the '
    .. 'model treats a photograph without it as not personal.\n\n'
    .. 'Step 1 — %s: in each grid, in order, select the photographs that do not belong and '
    .. 'choose Remove Genre (where most are wrong, select all and deselect the right ones); '
    .. 'use Add Genre… for a missing one. Removing a wrong primary promotes the next genre. '
    .. 'They stay awaiting review.\n\n'
    .. 'Step 2 — %s: in each grid, select the odd ones out and choose Set Primary Genre… '
    .. '(each keeps its own other genres; No genre clears them).\n\n'
    .. 'Last — %s: select all and Accept, once. Accept writes the genres as edited in step 1.',
    #names, Collections.SET_NAME, personal, personal, Collections.GENRE_SET, Collections.PRIMARY_SET,
    Collections.AWAITING), 'info')
end)
