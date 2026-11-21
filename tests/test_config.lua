--[[
Tests for GrConfig.parse: defaults, validation, and that keys from earlier versions are
ignored rather than refused.
]]

local t = require 'harness'
local Config = require 'GrConfig'
local Json = require 'GrJson'

t.suite('GrConfig — defaults')

local cfg = Config.parse(nil)
t.eq(cfg.renditionLongEdge, 1024, 'renditions default to 1024 px')
t.eq(cfg.chunkSize, 50, 'chunks of 50 photographs per model call')
t.eq(cfg.modelTimeoutSeconds, 600, 'a model call times out after 10 minutes')
t.eq(cfg.logLevel, 'info', 'info logging')
t.eq(cfg.personalPath, { '#PERSONAL' }, 'the Personal keyword defaults to #PERSONAL')
t.eq(Config.parse({ personalKeyword = ' Me >Personal ' }).personalPath, { 'Me', 'Personal' },
     'a nested Personal keyword is a path')
t.eq(cfg.personalFloor, 'recommended', 'personal photographs get the model\'s recommended floor by default (ADR-028)')
t.eq(Config.parse({ personalFloor = 'off' }).personalFloor, 'off', '... or its cut-offs alone')

cfg = Config.parse { chunkSize = 20, logLevel = 'debug' }
t.eq(cfg.chunkSize, 20, 'a set value overrides the default')
t.eq(cfg.renditionLongEdge, 1024, 'untouched keys keep their defaults')

cfg = Config.parse { chunkSize = Json.null }
t.eq(cfg.chunkSize, 50, 'JSON null keeps the default')

cfg = Config.parse { primaryProvider = 'ollama', anthropicApiKey = 'sk-ant-x', crossCheckProviders = { 'codex-cli' } }
t.ok(cfg ~= nil, 'keys from earlier versions are ignored, not refused')
t.eq(cfg.anthropicApiKey, nil, 'and not carried into the config')

t.suite('GrConfig — validation')

local function refused(raw, fragment, message)
  local c, err = Config.parse(raw)
  t.ok(c == nil and tostring(err):find(fragment, 1, true) ~= nil, message)
end
refused({ renditionLongEdge = 100 }, 'renditionLongEdge', 'a rendition under 256 px is refused')
refused({ jpegQuality = 80 }, 'jpegQuality', 'JPEG quality on a 0..100 scale is refused')
refused({ chunkSize = 0 }, 'chunkSize', 'a zero chunk size is refused')
refused({ modelTimeoutSeconds = -1 }, 'modelTimeoutSeconds', 'a negative timeout is refused')
refused({ logLevel = 'verbose' }, 'logLevel', 'an unknown log level is refused')
refused({ personalKeyword = 'A > > B' }, 'personalKeyword', 'an empty path segment is refused')
refused({ personalKeyword = '' }, 'personalKeyword', 'an empty Personal keyword is refused')
refused({ personalFloor = 0.5 }, 'personalFloor', 'the floor itself is the model\'s, not a setting')
refused({ personalFloor = 'cutoffs' }, 'personalFloor', 'an unknown floor setting is refused')
t.eq(cfg.ratingRatio, 'recommended', 'the suggested rating takes the model\'s default bucket ratio (ADR-029)')
t.eq(Config.parse({ ratingRatio = 2 }).ratingRatio, 2, '... or a ratio the model ships')
t.eq(Config.parse({ ratingRatio = '1.5' }).ratingRatio, '1.5', '... written as text as well')
refused({ ratingRatio = 1 }, 'ratingRatio', 'a ratio of 1 or less makes no buckets')
refused({ ratingRatio = 'default' }, 'ratingRatio', 'an unknown ratio setting is refused')
t.eq(cfg.keywordRule, 'balanced', 'keywords follow the model\'s balanced rule by default (ADR-030)')
t.eq(Config.parse({ keywordRule = 'recall_first' }).keywordRule, 'recall_first', '... or the recall-first one')
refused({ keywordRule = 'all' }, 'keywordRule', 'an unknown keyword rule is refused')
refused('nope', 'object', 'a non-object root is refused')

return t
