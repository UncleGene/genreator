--[[
GrLog — logging with mandatory redaction (R8.4).

Logs counts, timings, genres, and error codes. Never image bytes, base64,
request/response bodies, file paths, filenames, captions, or keyword values.

`logLevel = "debug"` increases verbosity but unlocks none of the above: there is
deliberately no debug mode that logs photographs.

`redact` is pure and unit-tested.
]]

local Log = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }

Log.level = 'info'

--- Belt-and-braces: the caller is not supposed to pass image data at all; this catches mistakes.
function Log.redact(msg)
  if type(msg) ~= 'string' then msg = tostring(msg) end
  -- Anything that looks like a base64 blob: collapse rather than write image bytes.
  msg = msg:gsub('[A-Za-z0-9+/]+=*', function(tok)
    if #tok >= 256 then
      return string.format('<%d bytes elided>', #tok)
    end
    return tok
  end)
  return msg
end

local function shouldLog(level)
  return (LEVELS[level] or 0) <= (LEVELS[Log.level] or 3)
end

local function timestamp()
  return os.date('!%Y-%m-%dT%H:%M:%SZ')
end

--- Where the log file lives: alongside the config file, under logs/.
local function logFilePath()
  local ok, LrPathUtils = pcall(import, 'LrPathUtils')
  if not ok then return nil end
  local Config = require 'GrConfig'
  local cfgPath = Config.path()
  local dir = LrPathUtils.child(LrPathUtils.parent(cfgPath), 'logs')
  return LrPathUtils.child(dir, 'genreator.log'), dir
end

Log.MAX_BYTES = 1024 * 1024

local function write(level, msg)
  if not shouldLog(level) then return end

  local line = string.format('%s [%s] %s', timestamp(), level:upper(), Log.redact(msg))

  -- Always mirror to Lightroom's own trace channel when available; useful during
  -- development even when the file cannot be written.
  local okTrace, LrLogger = pcall(import, 'LrLogger')
  if okTrace then
    Log._logger = Log._logger or (function()
      local l = LrLogger('Genreator')
      l:enable('logfile')
      return l
    end)()
    local fn = Log._logger[level] or Log._logger.info
    pcall(fn, Log._logger, Log.redact(msg))
  end

  local path, dir = logFilePath()
  if not path then
    -- Running outside Lightroom (tests): stderr is the sink.
    if io.stderr then io.stderr:write(line, '\n') end
    return
  end

  local okFs, LrFileUtils = pcall(import, 'LrFileUtils')
  if okFs and dir and not LrFileUtils.exists(dir) then
    pcall(function() LrFileUtils.createAllDirectories(dir) end)
  end

  -- Rotate at MAX_BYTES by keeping one previous generation.
  local fh = io.open(path, 'a')
  if not fh then return end
  local size = fh:seek('end')
  -- os.remove/os.rename are not guaranteed in Lightroom's Lua; without them, keep appending.
  if size and size > Log.MAX_BYTES and os.remove and os.rename then
    fh:close()
    os.remove(path .. '.1')
    os.rename(path, path .. '.1')
    fh = io.open(path, 'a')
    if not fh then return end
  end
  fh:write(line, '\n')
  fh:close()
end

function Log.error(msg) write('error', msg) end
function Log.warn(msg)  write('warn', msg) end
function Log.info(msg)  write('info', msg) end
function Log.debug(msg) write('debug', msg) end

--- Format helper so call sites stay terse.
function Log.infof(fmt, ...) Log.info(string.format(fmt, ...)) end
function Log.warnf(fmt, ...) Log.warn(string.format(fmt, ...)) end
function Log.errorf(fmt, ...) Log.error(string.format(fmt, ...)) end
function Log.debugf(fmt, ...) Log.debug(string.format(fmt, ...)) end

return Log
