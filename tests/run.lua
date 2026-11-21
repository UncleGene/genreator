--[[
Offline test runner. No Lightroom, no network.

  luajit tests/run.lua          (or: make test)

Pure modules are tested directly. Lightroom-bound modules are loaded against the stubs in
tests/stub/ so their pure helpers (e.g. Rendition.exportSettings) can be asserted.
]]

local here = arg[0]:match('^(.*)/[^/]*$') or '.'
local root = here .. '/..'

package.path = table.concat({
  root .. '/Genreator.lrplugin/?.lua',
  here .. '/?.lua',
  here .. '/stub/?.lua',
  package.path,
}, ';')

-- Lightroom loads SDK namespaces with the global `import`; `require` only resolves plugin
-- files, so `require 'LrX'` fails inside Lightroom. Here `import` maps onto the stubs, and
-- refuses anything that is not an SDK namespace so the two cannot be swapped silently.
function import(name)
  assert(type(name) == 'string' and name:match('^Lr'), 'import is for Lr* namespaces: ' .. tostring(name))
  return require(name)
end

-- Lightroom cannot yield across a plain pcall: a yielding SDK call inside one (e.g.
-- withWriteAccessDo) fails with "must be called from within an LrTask". LuaJIT can yield
-- there, so the stubs need help: count active plain pcalls, and let yielding stubs refuse
-- to run inside one. LrTasks.pcall and the stubs' own task runner use the raw pcall.
-- Lightroom defines _PLUGIN in every plugin script; the photo stub insists on it.
_PLUGIN = setmetatable({ id = 'com.genreator.lightroom' }, { __tostring = function() return '_PLUGIN' end })

__rawPcall = pcall
__plainPcallDepth = 0
function pcall(fn, ...)
  __plainPcallDepth = __plainPcallDepth + 1
  local results = { __rawPcall(fn, ...) }
  __plainPcallDepth = __plainPcallDepth - 1
  return unpack(results, 1, table.maxn(results))
end

-- Point GrConfig (and so GrLog's file) at a throwaway path, so a test run can never write
-- into the user's real ~/.config/genreator/logs. Suites that override os.getenv chain to this.
local TEST_CONFIG = '/tmp/genreator-test-home/config.json'
local systemGetenv = os.getenv
os.getenv = function(name)
  if name == 'GENREATOR_CONFIG' then return TEST_CONFIG end
  return systemGetenv(name)
end

local H = require 'harness'

local suites = {
  'test_json',
  'test_taxonomy',
  'test_config',
  'test_metadata',
  'test_metadata_schema',
  'test_rendition',
  'test_model',
  'test_keywords',
  'test_classifier',
  'test_log',
  'test_cli',
  'test_report',
  'test_review',
  'test_collections',
  'test_approved',
  'test_pick',
  'test_e2e',
  'test_footprint',
  'test_sdk_imports',
  'test_model_bundle',
}

io.write('Genreator offline test suite\n')
io.write('Lua: ', _VERSION, jit and (' (' .. jit.version .. ')') or '', '\n')

for _, name in ipairs(suites) do
  local ok, err = __rawPcall(require, name)
  if not ok then
    H.failed = H.failed + 1
    H.failures[#H.failures + 1] = string.format('%s: suite failed to load\n      %s',
                                                name, tostring(err))
    io.write('\n', name, '\n  FAIL  suite failed to load\n        ', tostring(err), '\n')
  end
end

os.execute("rm -rf /tmp/genreator-test-home")
os.exit(H.report() and 0 or 1)
