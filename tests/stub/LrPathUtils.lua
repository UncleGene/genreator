-- Stub of the Lightroom LrPathUtils namespace, enough for offline tests.
local M = {}

local STANDARD = {
  temp = '/tmp',
  home = os.getenv('HOME') or '/tmp',
}

function M.getStandardFilePath(which)
  return STANDARD[which] or '/tmp'
end

function M.child(dir, name)
  if dir:sub(-1) == '/' then return dir .. name end
  return dir .. '/' .. name
end

function M.parent(path)
  return (path:match('^(.*)/[^/]*$')) or '/'
end

function M.leafName(path)
  return (path:match('([^/]*)$')) or path
end

function M.removeExtension(path)
  return (path:gsub('%.[^%./]*$', ''))
end

function M.extension(path)
  return (path:match('%.([^%./]*)$')) or ''
end

return M
