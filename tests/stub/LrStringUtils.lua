-- Stub of LrStringUtils. Only the base64 functions are exercised offline; the real
-- implementation is supplied by Lightroom (ADR-006 — no hand-rolled base64 ships).
local M = {}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function M.encodeBase64(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64
    local chunk = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
    if b then
      chunk = chunk .. B64:sub(c3 + 1, c3 + 1)
    else
      chunk = chunk .. '='
    end
    if c then
      chunk = chunk .. B64:sub(c4 + 1, c4 + 1)
    else
      chunk = chunk .. '='
    end
    out[#out + 1] = chunk
  end
  return table.concat(out)
end

function M.decodeBase64(s)
  local index = {}
  for i = 1, #B64 do index[B64:sub(i, i)] = i - 1 end
  local out = {}
  for i = 1, #s, 4 do
    local c1, c2, c3, c4 = s:sub(i, i), s:sub(i + 1, i + 1), s:sub(i + 2, i + 2), s:sub(i + 3, i + 3)
    local n = index[c1] * 262144 + index[c2] * 4096 + (index[c3] or 0) * 64 + (index[c4] or 0)
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if c3 ~= '=' then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
    if c4 ~= '=' then out[#out + 1] = string.char(n % 256) end
  end
  return table.concat(out)
end

function M.trimWhitespace(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.lower(s) return s:lower() end
function M.upper(s) return s:upper() end

return M
