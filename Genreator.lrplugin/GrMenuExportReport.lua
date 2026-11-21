--[[
Menu entry: File > Plug-in Extras > Export Report (CSV)

Writes every plugin field of the selected photographs (genres, suggested rating, keyword review) to
~/.config/genreator/reports/ (GrReport). Reads the catalog only.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'

LrFunctionContext.postAsyncTaskWithContext('GenreatorExportReport', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: report failed', tostring(message), 'critical')
  end)

  local photos = LrApplication.activeCatalog():getTargetPhotos() or {}
  if #photos == 0 then
    LrDialogs.message('Genreator', 'Select the photographs to include in the report.', 'info')
    return
  end

  local path, err = require('GrReport').exportSelection(photos)
  if not path then
    LrDialogs.message('Genreator: report failed', tostring(err), 'critical')
    return
  end
  LrDialogs.message('Genreator: report written',
    string.format('%d photographs\n\n%s', #photos, path), 'info')
end)
