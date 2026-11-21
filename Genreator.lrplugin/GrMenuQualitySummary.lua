--[[
Menu entry: File > Plug-in Extras > Genre Quality Summary

Counts the user's review decisions across the whole catalog, per model version: how often
the suggested primary and genre list were kept (R7.8, GrReport). Reads the catalog only;
ignores the selection.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'

LrFunctionContext.postAsyncTaskWithContext('GenreatorQualitySummary', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: quality summary failed', tostring(message), 'critical')
  end)

  local progress = LrProgressScope {
    title           = 'Genreator: reading review decisions',
    functionContext = context,
  }
  progress:setCancelable(true)
  local Report = require 'GrReport'
  local rows = Report.catalogDecisions(LrApplication.activeCatalog(), progress)
  progress:done()
  if not rows then return end

  local summary = Report.summarize(rows, (require('GrModel').manifest() or {}).version)
  local path = Report.writeSummary(Report.summaryText(summary))
  LrDialogs.message('Genreator: Genre Quality Summary', Report.summaryShort(summary, path), 'info')
end)
