--[[
GrCli — the only module that launches a process: the bundled model's runtime (ADR-021,
amending ADR-006).

Rules this module enforces, so callers cannot get them wrong:
- Every argument is single-quoted. Photograph data never appears on the command line: the
  request (rendition paths, the Personal flag) travels in a file in the run's temp
  directory. `{ fromFile = path }` expands a file inside double quotes — "$(cat 'file')" —
  which the shell does not re-parse.
- Every call has a hard timeout. macOS has no `timeout`, so perl's alarm is used: the
  signal survives exec and kills a hung process (exit status 142).
- The process starts in its own directory, with a fixed PATH.

Pure: shellQuote, buildCommand, normalizeStatus. Lightroom-bound: newWorkDir, writeFile,
readFile, run, removeWorkDir.
]]

local Log = require 'GrLog'

local Cli = {}

-- Lightroom starts processes with a minimal PATH; set one explicitly.
Cli.PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'

Cli.TIMEOUT_STATUS   = 142   -- 128 + SIGALRM
Cli.NOT_FOUND_STATUS = 127

--- Single-quote a string for /bin/sh.
function Cli.shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Pure: assemble the command line.
-- @param spec {
--   bin       = absolute path to the executable,
--   args      = array; each entry a string (quoted literally) or { fromFile = path }
--               (expanded to "$(cat 'path')"),
--   stdin     = path (optional), stdout = path, stderr = path,
--   timeout   = seconds,
--   cwd       = working directory (optional; default: the directory of `stdout`),
-- }
-- Every command starts in its own work directory, never in Lightroom's working directory
-- (often the home folder): a process listing the home folder reaches ~/Library/Containers,
-- which made macOS ask again and again whether Lightroom may "access data from other apps"
-- (2026-10-05).
function Cli.buildCommand(spec)
  local parts = {}
  for _, a in ipairs(spec.args or {}) do
    if type(a) == 'table' and a.fromFile then
      parts[#parts + 1] = '"$(cat ' .. Cli.shellQuote(a.fromFile) .. ')"'
    else
      parts[#parts + 1] = Cli.shellQuote(a)
    end
  end

  local env = 'PATH=' .. Cli.shellQuote(Cli.PATH)

  local core = string.format(
    "%s /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' %d %s %s",
    env, math.floor(spec.timeout or 120), Cli.shellQuote(spec.bin), table.concat(parts, ' '))

  local cmd = core .. ' < ' .. (spec.stdin and Cli.shellQuote(spec.stdin) or '/dev/null')
  local cwd = spec.cwd or (spec.stdout and spec.stdout:match('^(.*)/[^/]*$'))
  local prefix = (cwd and cwd ~= '') and ('cd ' .. Cli.shellQuote(cwd) .. ' && ') or ''
  return prefix .. cmd .. ' > ' .. Cli.shellQuote(spec.stdout) .. ' 2> ' .. Cli.shellQuote(spec.stderr)
end

--- LrTasks.execute may return a raw wait status (exit code * 256) rather than the exit code.
function Cli.normalizeStatus(status)
  status = tonumber(status) or -1
  if status >= 256 and status % 256 == 0 then return status / 256 end
  return status
end

-- ------------------------------------------------------------ Lightroom-bound

--- A fresh per-call directory under the OS temp path. The `genreator-` prefix means a crash
-- leftover is swept by Rendition.cleanStaleTempDirs at the next run.
function Cli.newWorkDir(tag)
  local LrFileUtils = import 'LrFileUtils'
  local LrPathUtils = import 'LrPathUtils'
  local dir = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'),
    string.format('genreator-cli-%s-%d%04d', tostring(tag), os.time(), math.random(0, 9999)))
  LrFileUtils.createAllDirectories(dir)
  return dir
end

function Cli.writeFile(path, contents)
  local fh, err = io.open(path, 'wb')
  if not fh then return nil, err end
  fh:write(contents)
  fh:close()
  return true
end

function Cli.readFile(path)
  local fh = io.open(path, 'rb')
  if not fh then return nil end
  local data = fh:read('*a')
  fh:close()
  return data
end

function Cli.removeWorkDir(dir)
  local LrFileUtils = import 'LrFileUtils'
  pcall(function() if LrFileUtils.exists(dir) then LrFileUtils.delete(dir) end end)
end

--- Run one command. Must be inside a task, not inside a plain pcall (LrTasks.execute yields).
-- @return exitCode, stdoutText, stderrText, elapsedMs
function Cli.run(spec)
  local LrTasks = import 'LrTasks'
  local LrDate  = import 'LrDate'
  local started = LrDate.currentTime()
  local status = Cli.normalizeStatus(LrTasks.execute(Cli.buildCommand(spec)))
  local elapsedMs = math.floor((LrDate.currentTime() - started) * 1000 + 0.5)
  local out = Cli.readFile(spec.stdout) or ''
  local err = Cli.readFile(spec.stderr) or ''
  -- The exit status only: the command line holds file paths, and stderr may echo the request.
  Log.debugf('cli %s exited %d', tostring(spec.bin):match('[^/]+$') or '?', status)
  return status, out, err, elapsedMs
end

return Cli
