-- Stub of LrDialogs. Captures messages instead of showing them, and lets tests script
-- the answer to a confirm().
local M = {}

M._messages = {}
M._confirms = {}
M._confirmAnswer = 'ok'
M._openPanel = nil   -- the paths runOpenPanel returns

function M._reset()
  M._messages = {}
  M._confirms = {}
  M._confirmAnswer = 'ok'
  M._openPanel = nil
end

function M.runOpenPanel()
  return M._openPanel
end

function M.message(title, body, style)
  M._messages[#M._messages + 1] = { title = title, body = body, style = style }
end

function M.confirm(title, body, affirmative, cancel)
  M._confirms[#M._confirms + 1] = {
    title = title, body = body, affirmative = affirmative, cancel = cancel,
  }
  return M._confirmAnswer
end

function M.showError(body)
  M._messages[#M._messages + 1] = { title = 'error', body = body, style = 'critical' }
end

--- Concatenated message bodies, for assertions.
function M._allText()
  local parts = {}
  for _, m in ipairs(M._messages) do
    parts[#parts + 1] = tostring(m.title) .. '\n' .. tostring(m.body)
  end
  return table.concat(parts, '\n---\n')
end

return M
