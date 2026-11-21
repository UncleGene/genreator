--[[
GrJson — minimal JSON encode/decode, pure Lua 5.1.

Written rather than vendored: the plugin needs JSON for config, request bodies and
responses, and a ~200-line self-contained implementation avoids adding a third-party
dependency with its own licence and update story (ADR-006, R9.1).

Pure module: no Lr* dependency, fully unit-tested offline.

Notes:
  * Json.null is the sentinel for JSON null, since Lua cannot store nil in a table.
  * Json.array(t) marks a table as an array so that an EMPTY array encodes as [] not {}.
  * Numbers encode via %.14g, which round-trips doubles without exponent surprises.
]]

local Json = {}

Json.null = setmetatable({}, { __tostring = function() return 'null' end })

local ARRAY_MT = { __jsonarray = true }

--- Mark a table as a JSON array (matters only when empty).
function Json.array(t)
  return setmetatable(t or {}, ARRAY_MT)
end

--- Mark a table as a JSON object whose keys are emitted in `order` (keys not listed follow,
-- sorted). Needed where order carries meaning: a structured-output schema's properties
-- are generated in that order, so a field listed first is written first by the model.
function Json.ordered(order, t)
  return setmetatable(t or {}, { __jsonorder = order })
end

-- ---------------------------------------------------------------- encoding

local ESCAPES = {
  ['"']    = '\\"',
  ['\\']   = '\\\\',
  ['\b']   = '\\b',
  ['\f']   = '\\f',
  ['\n']   = '\\n',
  ['\r']   = '\\r',
  ['\t']   = '\\t',
}

local function escapeString(s)
  -- Escape the mandatory characters, then any remaining C0 control bytes.
  s = s:gsub('[%z\1-\31\\"]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end)
  return '"' .. s .. '"'
end

local function isArray(t)
  if getmetatable(t) == ARRAY_MT then return true end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  -- A table with only numeric keys counts as an array when those keys are 1..n.
  for i = 1, n do
    if t[i] == nil then return false end
    end
  return n > 0
end

local encodeValue

local function encodeTable(t, out)
  if isArray(t) then
    out[#out + 1] = '['
    for i = 1, #t do
      if i > 1 then out[#out + 1] = ',' end
      encodeValue(t[i], out)
    end
    out[#out + 1] = ']'
  else
    -- Sort keys so output is deterministic: byte-comparable files and test assertions.
    local keys = {}
    for k in pairs(t) do
      if type(k) == 'string' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    local mt = getmetatable(t)
    if mt and type(mt.__jsonorder) == 'table' then
      local listed, ordered = {}, {}
      for _, k in ipairs(mt.__jsonorder) do
        if t[k] ~= nil then ordered[#ordered + 1] = k; listed[k] = true end
      end
      for _, k in ipairs(keys) do
        if not listed[k] then ordered[#ordered + 1] = k end
      end
      keys = ordered
    end
    out[#out + 1] = '{'
    for i = 1, #keys do
      if i > 1 then out[#out + 1] = ',' end
      out[#out + 1] = escapeString(keys[i])
      out[#out + 1] = ':'
      encodeValue(t[keys[i]], out)
    end
    out[#out + 1] = '}'
  end
end

encodeValue = function(v, out)
  if v == nil or v == Json.null then
    out[#out + 1] = 'null'
  elseif v == true then
    out[#out + 1] = 'true'
  elseif v == false then
    out[#out + 1] = 'false'
  else
    local tv = type(v)
    if tv == 'number' then
      if v ~= v or v == math.huge or v == -math.huge then
        error('GrJson: cannot encode non-finite number', 0)
      end
      out[#out + 1] = string.format('%.14g', v)
    elseif tv == 'string' then
      out[#out + 1] = escapeString(v)
    elseif tv == 'table' then
      encodeTable(v, out)
    else
      error('GrJson: cannot encode value of type ' .. tv, 0)
    end
  end
end

--- Encode a Lua value as a JSON string. Object keys are emitted sorted.
function Json.encode(v)
  local out = {}
  encodeValue(v, out)
  return table.concat(out)
end

-- ---------------------------------------------------------------- decoding

local function skipWhitespace(s, i)
  local _, j = s:find('^[ \t\r\n]*', i)
  return (j or i - 1) + 1
end

local parseValue

local function fail(i, msg)
  error(string.format('GrJson: %s at position %d', msg, i), 0)
end

local function parseString(s, i)
  -- s:sub(i,i) is the opening quote.
  i = i + 1
  local buf = {}
  while true do
    local c = s:sub(i, i)
    if c == '' then fail(i, 'unterminated string') end
    if c == '"' then
      return table.concat(buf), i + 1
    elseif c == '\\' then
      local esc = s:sub(i + 1, i + 1)
      if esc == 'u' then
        local hex = s:sub(i + 2, i + 5)
        if not hex:match('^%x%x%x%x$') then fail(i, 'bad \\u escape') end
        local cp = tonumber(hex, 16)
        -- Encode the code point as UTF-8. Surrogate pairs are combined when a
        -- matching low surrogate follows; a lone surrogate becomes U+FFFD.
        if cp >= 0xD800 and cp <= 0xDBFF then
          local nextEsc = s:sub(i + 6, i + 7)
          local lowHex = s:sub(i + 8, i + 11)
          if nextEsc == '\\u' and lowHex:match('^%x%x%x%x$') then
            local low = tonumber(lowHex, 16)
            if low >= 0xDC00 and low <= 0xDFFF then
              cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
              i = i + 6
            else
              cp = 0xFFFD
            end
          else
            cp = 0xFFFD
          end
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          cp = 0xFFFD
        end
        if cp < 0x80 then
          buf[#buf + 1] = string.char(cp)
        elseif cp < 0x800 then
          buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40),
                                      0x80 + (cp % 0x40))
        elseif cp < 0x10000 then
          buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                                      0x80 + (math.floor(cp / 0x40) % 0x40),
                                      0x80 + (cp % 0x40))
        else
          buf[#buf + 1] = string.char(0xF0 + math.floor(cp / 0x40000),
                                      0x80 + (math.floor(cp / 0x1000) % 0x40),
                                      0x80 + (math.floor(cp / 0x40) % 0x40),
                                      0x80 + (cp % 0x40))
        end
        i = i + 6
      else
        local simple = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
                          f = '\f', n = '\n', r = '\r', t = '\t' })[esc]
        if not simple then fail(i, 'bad escape \\' .. esc) end
        buf[#buf + 1] = simple
        i = i + 2
      end
    else
      buf[#buf + 1] = c
      i = i + 1
    end
  end
end

local function parseNumber(s, i)
  local numStr = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
  if not numStr or numStr == '' then fail(i, 'bad number') end
  local n = tonumber(numStr)
  if n == nil then fail(i, 'bad number') end
  return n, i + #numStr
end

local function parseArray(s, i)
  local arr = Json.array{}
  i = skipWhitespace(s, i + 1)
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local v
    v, i = parseValue(s, i)
    arr[#arr + 1] = v
    i = skipWhitespace(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skipWhitespace(s, i + 1)
    elseif c == ']' then
      return arr, i + 1
    else
      fail(i, "expected ',' or ']'")
    end
  end
end

local function parseObject(s, i)
  local obj = {}
  i = skipWhitespace(s, i + 1)
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then fail(i, 'expected object key') end
    local k
    k, i = parseString(s, i)
    i = skipWhitespace(s, i)
    if s:sub(i, i) ~= ':' then fail(i, "expected ':'") end
    i = skipWhitespace(s, i + 1)
    local v
    v, i = parseValue(s, i)
    obj[k] = v
    i = skipWhitespace(s, i)
    local c = s:sub(i, i)
    if c == ',' then
      i = skipWhitespace(s, i + 1)
    elseif c == '}' then
      return obj, i + 1
    else
      fail(i, "expected ',' or '}'")
    end
  end
end

parseValue = function(s, i)
  i = skipWhitespace(s, i)
  local c = s:sub(i, i)
  if c == '' then fail(i, 'unexpected end of input') end
  if c == '{' then return parseObject(s, i) end
  if c == '[' then return parseArray(s, i) end
  if c == '"' then return parseString(s, i) end
  if c == 't' then
    if s:sub(i, i + 3) == 'true' then return true, i + 4 end
    fail(i, 'invalid literal')
  end
  if c == 'f' then
    if s:sub(i, i + 4) == 'false' then return false, i + 5 end
    fail(i, 'invalid literal')
  end
  if c == 'n' then
    if s:sub(i, i + 3) == 'null' then return Json.null, i + 4 end
    fail(i, 'invalid literal')
  end
  if c:match('[%d%-]') then return parseNumber(s, i) end
  fail(i, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string.
-- @return value on success; nil plus an error message on failure.
function Json.decode(s)
  if type(s) ~= 'string' then return nil, 'GrJson: input is not a string' end
  local ok, result, pos = pcall(function()
    local v, i = parseValue(s, 1)
    return v, i
  end)
  if not ok then return nil, tostring(result) end
  local tail = skipWhitespace(s, pos)
  if tail <= #s then
    return nil, string.format('GrJson: trailing content at position %d', tail)
  end
  return result
end

return Json
