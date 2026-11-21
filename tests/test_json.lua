local t = require 'harness'
local Json = require 'GrJson'

t.suite('GrJson')

-- decode: scalars
t.eq(Json.decode('42'), 42, 'decodes an integer')
t.eq(Json.decode('-3.5'), -3.5, 'decodes a negative float')
t.eq(Json.decode('1e3'), 1000, 'decodes exponent notation')
t.eq(Json.decode('true'), true, 'decodes true')
t.eq(Json.decode('false'), false, 'decodes false')
t.eq(Json.decode('"hi"'), 'hi', 'decodes a string')
t.eq(Json.decode('null'), Json.null, 'decodes null to the sentinel')

-- decode: whitespace tolerance
t.eq(Json.decode('  \n\t 7 \n '), 7, 'tolerates surrounding whitespace')

-- decode: objects and arrays
t.eq(Json.decode('{"a":1,"b":[2,3]}'), { a = 1, b = { 2, 3 } }, 'decodes nested structures')
t.eq(Json.decode('{}'), {}, 'decodes an empty object')
t.eq(Json.decode('[]'), {}, 'decodes an empty array')
t.eq(Json.decode('[1,[2,[3]]]'), { 1, { 2, { 3 } } }, 'decodes deep nesting')
t.eq(Json.decode('{"a":{"b":{"c":"d"}}}'), { a = { b = { c = 'd' } } },
     'decodes deep objects')

-- decode: escapes
t.eq(Json.decode('"a\\nb"'), 'a\nb', 'decodes \\n')
t.eq(Json.decode('"a\\tb"'), 'a\tb', 'decodes \\t')
t.eq(Json.decode('"q\\"q"'), 'q"q', 'decodes an escaped quote')
t.eq(Json.decode('"back\\\\slash"'), 'back\\slash', 'decodes an escaped backslash')
t.eq(Json.decode('"\\u0041"'), 'A', 'decodes a BMP \\u escape')
t.eq(Json.decode('"\\u00e9"'), '\195\169', 'decodes \\u00e9 as two-byte UTF-8')
t.eq(Json.decode('"\\u20ac"'), '\226\130\172', 'decodes \\u20ac as three-byte UTF-8')
t.eq(Json.decode('"\\ud83d\\ude00"'), '\240\159\152\128',
     'combines a surrogate pair into four-byte UTF-8')

-- decode: failures return nil + message rather than raising
local v, err = Json.decode('{')
t.isNil(v, 'rejects a truncated object')
t.ok(type(err) == 'string', 'returns an error message for a truncated object')

t.isNil(Json.decode('{"a":1,}'), 'rejects a trailing comma in an object')
t.isNil(Json.decode('[1,]'), 'rejects a trailing comma in an array')
t.isNil(Json.decode('{a:1}'), 'rejects an unquoted key')
t.isNil(Json.decode("'single'"), 'rejects single-quoted strings')
t.isNil(Json.decode('tru'), 'rejects a malformed literal')
t.isNil(Json.decode('"unterminated'), 'rejects an unterminated string')
t.isNil(Json.decode('{"a":1} trailing'), 'rejects trailing content')
t.isNil(Json.decode(''), 'rejects empty input')
t.isNil(Json.decode(nil), 'rejects a nil input')
t.isNil(Json.decode('"\\x41"'), 'rejects an invalid escape')
t.isNil(Json.decode('"\\u00zz"'), 'rejects a malformed \\u escape')

-- encode: scalars
t.eq(Json.encode(42), '42', 'encodes an integer without a decimal point')
t.eq(Json.encode(true), 'true', 'encodes true')
t.eq(Json.encode(false), 'false', 'encodes false')
t.eq(Json.encode(Json.null), 'null', 'encodes the null sentinel')
t.eq(Json.encode('hi'), '"hi"', 'encodes a string')

-- encode: escaping
t.eq(Json.encode('a\nb'), '"a\\nb"', 'escapes a newline')
t.eq(Json.encode('q"q'), '"q\\"q"', 'escapes a quote')
t.eq(Json.encode('back\\slash'), '"back\\\\slash"', 'escapes a backslash')
t.eq(Json.encode('\1'), '"\\u0001"', 'escapes a control byte as \\u')

-- encode: object keys are sorted, so output is deterministic
t.eq(Json.encode({ b = 1, a = 2, c = 3 }), '{"a":2,"b":1,"c":3}',
     'sorts object keys for deterministic output')

-- encode: arrays
t.eq(Json.encode({ 1, 2, 3 }), '[1,2,3]', 'encodes an array')
t.eq(Json.encode(Json.array{}), '[]', 'encodes a marked empty array as []')
t.eq(Json.encode({}), '{}', 'encodes an unmarked empty table as {}')

-- encode: rejects values with no JSON representation
t.raises(function() Json.encode(0 / 0) end, 'refuses to encode NaN')
t.raises(function() Json.encode(math.huge) end, 'refuses to encode infinity')
t.raises(function() Json.encode(print) end, 'refuses to encode a function')

-- round trips
local cases = {
  { a = 1, b = 'two', c = { 3, 4 }, d = true },
  { nested = { deep = { deeper = 'value' } } },
  { 'x', 'y', 'z' },
  { unicode = 'caf\195\169 \226\130\172' },
  { empty = {} },
}
for i, case in ipairs(cases) do
  local encoded = Json.encode(case)
  local decoded = Json.decode(encoded)
  t.eq(decoded, case, 'round-trips case ' .. i)
end

-- round trip preserves a reason string shaped like real model output
local reason = 'Centres on an unscripted interaction rather than the event as a whole; ' ..
               'timing and gesture carry it. "Street", not Documentary.'
t.eq(Json.decode(Json.encode({ reason = reason })).reason, reason,
     'round-trips a realistic reason string with quotes')

return t
