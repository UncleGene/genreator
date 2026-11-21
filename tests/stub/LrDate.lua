-- Stub of LrDate. A clock that advances 0.25 s per read, so latency is non-zero and stable.
local M = {}

local now = 1000

function M.currentTime()
  now = now + 0.25
  return now
end

return M
