-- Stub of LrTasks. Its pcall is the one SDK calls may yield inside, so it bypasses the
-- plain-pcall depth counter that tests/run.lua installs. sleep records instead of waiting.
local M = {}

M._sleeps = {}

function M.pcall(fn, ...)
  return __rawPcall(fn, ...)
end

function M.sleep(seconds)
  if __plainPcallDepth > 0 then
    error('LrTasks.sleep: must be called from within an LrTask', 2)
  end
  M._sleeps[#M._sleeps + 1] = seconds
end

-- Tests may script execute() with a handler (adapter tests); otherwise the command really
-- runs through /bin/sh, so GrCli's quoting, timeout and redirection are tested for real.
M._executeHandler = nil

-- No real concurrency offline. The plugin's only background task watches for Cancel while
-- the model runs; run here, its loop would never end (sleep does not wait), so tasks are
-- recorded, not run. Tests call one with M._runTask(i) when they need it.
M._tasks = {}
function M.startAsyncTask(fn)
  M._tasks[#M._tasks + 1] = fn
end
function M._runTask(i)
  return __rawPcall(M._tasks[i])
end
M._executed = {}

function M.execute(cmd)
  if __plainPcallDepth > 0 then
    error('LrTasks.execute: must be called from within an LrTask', 2)
  end
  M._executed[#M._executed + 1] = cmd
  if M._executeHandler then return M._executeHandler(cmd) end
  local status = os.execute(cmd)
  if status == true then return 0 end
  return tonumber(status) or -1
end

return M
