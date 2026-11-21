--[[
Tests for GrLog.redact — the last line of defence against an image payload reaching a log
file (R8.4).
]]

local t = require 'harness'
local Log = require 'GrLog'

t.suite('GrLog — ordinary text is left alone')

t.eq(Log.redact('run r-20261002T120000Z-abcd ok=147 errors=3'),
     'run r-20261002T120000Z-abcd ok=147 errors=3',
     'run summaries pass through unchanged')
t.eq(Log.redact('genre=Street confidence=high'),
     'genre=Street confidence=high',
     'classification outcomes pass through unchanged')
t.eq(Log.redact('chunk 3 write failed: timeout'),
     'chunk 3 write failed: timeout',
     'error text passes through unchanged')

t.suite('GrLog — image payloads are elided, never written')

-- A base64 JPEG is the single largest privacy risk in a log file.
local fakeB64 = string.rep('QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVph', 20)  -- ~720 chars
local elided = Log.redact('payload ' .. fakeB64 .. ' end')
t.notContains(elided, fakeB64, 'a long base64 blob never reaches the log')
t.contains(elided, 'bytes elided', 'elision leaves a marker with the size')
t.contains(elided, 'payload', 'text before the blob is preserved')
t.contains(elided, 'end', 'text after the blob is preserved')

-- Short tokens must survive, or ordinary log lines become unreadable
t.eq(Log.redact('base64Length=1024'), 'base64Length=1024',
     'short alphanumeric tokens are not elided')

t.suite('GrLog — non-string input')

t.eq(Log.redact(42), '42', 'coerces a number')
t.eq(Log.redact(nil), 'nil', 'coerces nil rather than raising')
t.eq(Log.redact(true), 'true', 'coerces a boolean')

t.suite('GrLog — level gating')

t.ok(type(Log.info) == 'function', 'exposes info')
t.ok(type(Log.warn) == 'function', 'exposes warn')
t.ok(type(Log.error) == 'function', 'exposes error')
t.ok(type(Log.debug) == 'function', 'exposes debug')
t.ok(type(Log.infof) == 'function', 'exposes the infof formatter')

t.suite("GrLog — writing under Lightroom's restricted io/os")

local LrPathUtils = import 'LrPathUtils'
local realStderr, realGetenv = io.stderr, os.getenv
-- Without os.getenv the config path falls back to the home folder; keep that throwaway too,
-- or this line lands in the user's real log.
local realStandard = LrPathUtils.getStandardFilePath
LrPathUtils.getStandardFilePath = function(which)
  if which == 'home' then return '/tmp/genreator-test-home' end
  return realStandard(which)
end
io.stderr, os.getenv = nil, nil
local okWrite, writeErr = pcall(Log.error, 'restricted environment')
io.stderr, os.getenv = realStderr, realGetenv
LrPathUtils.getStandardFilePath = realStandard
t.ok(okWrite, 'logging does not fail without io.stderr or os.getenv: ' .. tostring(writeErr))

return t
