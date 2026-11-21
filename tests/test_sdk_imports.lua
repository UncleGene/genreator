--[[
Static guards on the plugin source.

SDK namespaces must be loaded with `import`, never `require`.

Inside Lightroom `require 'LrApplication'` fails with "Could not load toolkit script" —
`require` resolves plugin files only. The stubs make both forms work offline, so nothing
else in this suite would notice the mistake.
]]

local t = require 'harness'

t.suite('Plugin files load SDK namespaces with import')

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local bundle = here .. '/../Genreator.lrplugin'

local listing = io.popen('ls "' .. bundle .. '"')
local files = {}
for name in listing:lines() do
  if name:match('%.lua$') then files[#files + 1] = name end
end
listing:close()

t.ok(#files > 0, 'found plugin Lua files to scan')

for _, name in ipairs(files) do
  local fh = assert(io.open(bundle .. '/' .. name, 'r'))
  local offending = {}
  local n = 0
  for line in fh:lines() do
    n = n + 1
    if line:match("require%s*%(?%s*['\"]Lr") or line:match("pcall%(%s*require%s*,%s*['\"]Lr") then
      offending[#offending + 1] = n
    end
  end
  fh:close()
  t.eq(#offending, 0, name .. ' has no require of an Lr* namespace'
       .. (#offending > 0 and (' (lines ' .. table.concat(offending, ', ') .. ')') or ''))
end

-- Lightroom's embedded os/io lack functions LuaJIT has: os.getenv and os.remove are missing
-- (os.remove broke Check Model, 2026-10-28). The plugin may call them only behind a check that
-- they exist (`if os.remove and …` within three lines above, `os.getenv and os.getenv(…)`) —
-- offline they always do.
t.suite('Plugin files call no os/io function Lightroom may lack, unguarded')

local MISSING = { 'os.remove', 'os.rename', 'os.getenv', 'os.execute', 'os.tmpname', 'os.exit', 'io.popen' }
for _, name in ipairs(files) do
  local fh = assert(io.open(bundle .. '/' .. name, 'r'))
  local offending, n, recent = {}, 0, {}
  for line in fh:lines() do
    n = n + 1
    local code = line:gsub('%-%-.*$', '')
    for _, fn in ipairs(MISSING) do
      local pat = fn:gsub('%.', '%%.')
      local near = code .. ' ' .. table.concat(recent, ' ')
      local guarded = near:match(pat .. '%s+and') or near:match('and%s+' .. pat .. '[^%w_.(]')
      if code:match(pat .. '%s*%(') and not guarded then
        offending[#offending + 1] = string.format('%d (%s)', n, fn)
      end
    end
    -- A guard within the three lines above counts (`if os.remove and os.rename then`).
    table.insert(recent, code)
    if #recent > 3 then table.remove(recent, 1) end
  end
  fh:close()
  t.eq(#offending, 0, name .. ' calls no os/io function Lightroom may lack, unguarded'
       .. (#offending > 0 and (': line ' .. table.concat(offending, ', ')) or ''))
end

