-- Stub of the Lightroom LrFileUtils namespace, enough for offline tests.
-- Backed by a settable in-memory table so tests can control what "exists".
local M = {}

M._files = {}        -- path -> contents
M._dirs = {}         -- path -> true
M._deleted = {}      -- paths that delete() was called on

function M._reset()
  M._files = {}
  M._dirs = {}
  M._deleted = {}
end

--- True if the path exists on the real filesystem.
local function existsOnDisk(path)
  local fh = io.open(path, 'rb')
  if fh then fh:close() return true end
  return false
end

-- Checks the in-memory table first, then falls back to the real filesystem, so tests can
-- mix scripted entries with genuine temp files (the e2e suite needs both).
function M.exists(path)
  if M._files[path] then return 'file' end
  if M._dirs[path] then return 'directory' end
  if path and existsOnDisk(path) then return 'file' end
  return false
end

function M.readFile(path)
  if M._files[path] then return M._files[path] end
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  return data
end

-- Real directories and deletions under /tmp, because GrCli writes files with io.open.
-- Restricted to /tmp so a test bug can never touch anything else.
local function underTmp(path) return type(path) == 'string' and path:match('^/tmp/genreator') end

function M.createAllDirectories(path)
  M._dirs[path] = true
  if underTmp(path) then os.execute("mkdir -p '" .. path .. "'") end
  return true
end

function M.delete(path)
  M._deleted[#M._deleted + 1] = path
  M._files[path] = nil
  M._dirs[path] = nil
  if underTmp(path) then os.execute("rm -rf '" .. path .. "'") end
  return true
end

function M.directoryEntries(dir)
  local entries = {}
  for path in pairs(M._dirs) do
    if path ~= dir and path:sub(1, #dir) == dir then entries[#entries + 1] = path end
  end
  for path in pairs(M._files) do
    if path:sub(1, #dir) == dir then entries[#entries + 1] = path end
  end
  table.sort(entries)
  local i = 0
  return function()
    i = i + 1
    return entries[i]
  end
end

return M
