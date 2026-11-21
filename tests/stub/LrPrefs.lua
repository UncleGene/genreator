-- Stub of LrPrefs: one plain table per plugin, resettable between tests.
local M = {}

M._prefs = {}

function M._reset() M._prefs = {} end

function M.prefsForPlugin()
  return M._prefs
end

return M
