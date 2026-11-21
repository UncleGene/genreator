--[[
Tests for GrCli. The LrTasks.execute stub runs commands through the real /bin/sh, so
quoting, the timeout wrapper, stdin holding and injection resistance are exercised for
real — this is the security boundary of ADR-021.
]]

local t = require 'harness'
local Cli = require 'GrCli'

t.suite('GrCli — quoting')

t.eq(Cli.shellQuote('plain'), "'plain'", 'plain string')
t.eq(Cli.shellQuote("it's"), "'it'\\''s'", 'embedded single quote is closed, escaped, reopened')

t.eq(Cli.normalizeStatus(0), 0, 'exit 0')
t.eq(Cli.normalizeStatus(256), 1, 'raw wait status 256 is exit 1')
t.eq(Cli.normalizeStatus(142 * 256), 142, 'raw wait status of a timeout')
t.eq(Cli.normalizeStatus(127), 127, 'plain exit code passes through')

local dir = Cli.newWorkDir('test')
local function f(name) return dir .. '/' .. name end

t.suite('GrCli — command shape')

local cmd = Cli.buildCommand {
  bin = '/bin/echo', args = { 'a b', { fromFile = f('sys.txt') } },
  stdin = f('in.txt'), stdout = f('out.txt'), stderr = f('err.txt'), timeout = 30,
}
t.contains(cmd, "alarm shift", 'wrapped in the perl timeout')
t.contains(cmd, " 30 '/bin/echo'", 'timeout and binary')
t.contains(cmd, "'a b'", 'argument quoted')
t.contains(cmd, '"$(cat \'' .. f('sys.txt') .. '\')"', 'file content expanded inside double quotes')
t.contains(cmd, "PATH='/opt/homebrew/bin:", 'PATH set explicitly for a GUI-launched process')
t.eq(cmd:sub(1, #("cd '" .. dir .. "' && ")), "cd '" .. dir .. "' && ",
     'starts in its own work directory, never Lightroom\'s (the home folder)')

t.suite('GrCli — runs for real: arguments, stdin, files')

Cli.writeFile(f('in.txt'), 'from stdin\n')
local status, out = Cli.run {
  bin = '/bin/cat', args = {}, stdin = f('in.txt'),
  stdout = f('out.txt'), stderr = f('err.txt'), timeout = 10,
}
t.eq(status, 0, 'exit 0')
t.eq(out, 'from stdin\n', 'stdin reaches the process and stdout is captured')

-- Content with every shell metacharacter survives a fromFile expansion untouched.
local nasty = [[it's "quoted" $HOME `date` $(touch /tmp/genreator-pwned) ; | & \ end]]
Cli.writeFile(f('nasty.txt'), nasty)
status, out = Cli.run {
  bin = '/usr/bin/printf', args = { '%s', { fromFile = f('nasty.txt') } },
  stdout = f('out.txt'), stderr = f('err.txt'), timeout = 10,
}
t.eq(out, nasty, 'file content reaches the CLI byte for byte, nothing expanded')

status, out = Cli.run {
  bin = '/usr/bin/printf', args = { '%s', "x'; touch /tmp/genreator-pwned; echo '" },
  stdout = f('out.txt'), stderr = f('err.txt'), timeout = 10,
}
local pwned = io.open('/tmp/genreator-pwned', 'r')
if pwned then pwned:close(); os.remove('/tmp/genreator-pwned') end
t.ok(pwned == nil, 'no injected command ran (neither via argument nor via file)')

status, out = Cli.run {
  bin = '/bin/pwd', args = {}, stdout = f('out.txt'), stderr = f('err.txt'), timeout = 10,
}
local realDir = io.popen('cd ' .. Cli.shellQuote(dir) .. ' && /bin/pwd -P'):read('*l')
local gotDir = io.popen('cd ' .. Cli.shellQuote((out:gsub('%s+$', ''))) .. ' && /bin/pwd -P'):read('*l')
t.eq(gotDir, realDir, 'the process really runs in the work directory')

t.suite('GrCli — failure modes')

status = Cli.run {
  bin = '/bin/sleep', args = { '5' }, stdout = f('out.txt'), stderr = f('err.txt'), timeout = 1,
}
t.eq(status, Cli.TIMEOUT_STATUS, 'a hung process is killed by the timeout')

status = Cli.run {
  bin = '/nonexistent/localgenres', args = {}, stdout = f('out.txt'), stderr = f('err.txt'), timeout = 5,
}
t.eq(status, Cli.NOT_FOUND_STATUS, 'a missing binary is exit 127')

Cli.removeWorkDir(dir)
local gone = io.open(f('in.txt'), 'r')
if gone then gone:close() end
t.ok(gone == nil, 'the work directory and its files are removed')

return t
