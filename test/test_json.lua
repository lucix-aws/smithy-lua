-- Test: runtime/json/encoder.lua and runtime/json/decoder.lua
-- Run: luajit test/test_json.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local encoder = require("json.encoder")
local decoder = require("json.decoder")

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. "\n  " .. tostring(err))
        os.exit(1)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function roundtrip(v)
    local json = encoder.encode(v)
    local decoded, err = decoder.decode(json)
    assert(not err, "decode error: " .. tostring(err))
    return decoded, json
end

-- === Encoder tests ===

test("encode string", function()
    assert_eq(encoder.encode("hello"), '"hello"')
end)

test("encode string with escapes", function()
    assert_eq(encoder.encode('a"b\\c'), '"a\\"b\\\\c"')
end)

test("encode string with control chars", function()
    assert_eq(encoder.encode("a\nb\tc"), '"a\\nb\\tc"')
end)

test("encode string with null byte", function()
    assert_eq(encoder.encode("a\0b"), '"a\\u0000b"')
end)

test("encode integer", function()
    assert_eq(encoder.encode(42), "42")
end)

test("encode negative integer", function()
    assert_eq(encoder.encode(-7), "-7")
end)

test("encode float", function()
    local json = encoder.encode(3.14)
    assert(json == "3.14" or json:find("3.14") == 1, "expected 3.14, got " .. json)
end)

test("encode zero", function()
    assert_eq(encoder.encode(0), "0")
end)

test("encode NaN", function()
    assert_eq(encoder.encode(0/0), '"NaN"')
end)

test("encode Infinity", function()
    assert_eq(encoder.encode(math.huge), '"Infinity"')
end)

test("encode -Infinity", function()
    assert_eq(encoder.encode(-math.huge), '"-Infinity"')
end)

test("encode true", function()
    assert_eq(encoder.encode(true), "true")
end)

test("encode false", function()
    assert_eq(encoder.encode(false), "false")
end)

test("encode nil", function()
    assert_eq(encoder.encode(nil), "null")
end)

test("encode empty array", function()
    assert_eq(encoder.encode({}), "[]")
end)

test("encode array", function()
    assert_eq(encoder.encode({1, 2, 3}), "[1,2,3]")
end)

test("encode nested array", function()
    assert_eq(encoder.encode({{1, 2}, {3}}), "[[1,2],[3]]")
end)

test("encode object (sorted keys)", function()
    local json = encoder.encode({b = 2, a = 1})
    assert_eq(json, '{"a":1,"b":2}')
end)

test("encode nested object", function()
    local json = encoder.encode({a = {x = 1}})
    assert_eq(json, '{"a":{"x":1}}')
end)

-- === Decoder tests ===

test("decode string", function()
    local v, err = decoder.decode('"hello"')
    assert(not err, err)
    assert_eq(v, "hello")
end)

test("decode string with escapes", function()
    local v, err = decoder.decode('"a\\"b\\\\c"')
    assert(not err, err)
    assert_eq(v, 'a"b\\c')
end)

test("decode string with unicode escape", function()
    local v, err = decoder.decode('"\\u0041"')
    assert(not err, err)
    assert_eq(v, "A")
end)

test("decode string with surrogate pair", function()
    -- U+1F600 = D83D DE00
    local v, err = decoder.decode('"\\uD83D\\uDE00"')
    assert(not err, err)
    assert_eq(v, "\xF0\x9F\x98\x80")
end)

test("decode integer", function()
    local v, err = decoder.decode("42")
    assert(not err, err)
    assert_eq(v, 42)
end)

test("decode negative number", function()
    local v, err = decoder.decode("-3.14")
    assert(not err, err)
    assert(math.abs(v - (-3.14)) < 1e-10, "expected -3.14")
end)

test("decode true", function()
    local v, err = decoder.decode("true")
    assert(not err, err)
    assert_eq(v, true)
end)

test("decode false", function()
    local v, err = decoder.decode("false")
    assert(not err, err)
    assert_eq(v, false)
end)

test("decode null", function()
    local v, err = decoder.decode("null")
    assert(not err, err)
    assert_eq(v, nil)
end)

test("decode empty array", function()
    local v, err = decoder.decode("[]")
    assert(not err, err)
    assert_eq(#v, 0)
end)

test("decode array", function()
    local v, err = decoder.decode("[1,2,3]")
    assert(not err, err)
    assert_eq(#v, 3)
    assert_eq(v[1], 1)
    assert_eq(v[3], 3)
end)

test("decode empty object", function()
    local v, err = decoder.decode("{}")
    assert(not err, err)
    assert_eq(next(v), nil)
end)

test("decode object", function()
    local v, err = decoder.decode('{"a":1,"b":"two"}')
    assert(not err, err)
    assert_eq(v.a, 1)
    assert_eq(v.b, "two")
end)

test("decode nested", function()
    local v, err = decoder.decode('{"a":{"b":[1,true,null]}}')
    assert(not err, err)
    assert_eq(v.a.b[1], 1)
    assert_eq(v.a.b[2], true)
    assert_eq(v.a.b[3], nil)
end)

test("decode with whitespace", function()
    local v, err = decoder.decode('  { "a" : 1 , "b" : [ 2 ] }  ')
    assert(not err, err)
    assert_eq(v.a, 1)
    assert_eq(v.b[1], 2)
end)

test("decode error: unterminated string", function()
    local v, err = decoder.decode('"hello')
    assert(err, "expected error")
    assert(err:find("unterminated"), "expected unterminated error, got: " .. err)
end)

test("decode error: invalid literal", function()
    local v, err = decoder.decode("tru")
    assert(err, "expected error")
end)

-- === Roundtrip tests ===

test("roundtrip string", function()
    local v = roundtrip("hello world")
    assert_eq(v, "hello world")
end)

test("roundtrip number", function()
    local v = roundtrip(42)
    assert_eq(v, 42)
end)

test("roundtrip boolean", function()
    local v = roundtrip(true)
    assert_eq(v, true)
end)

test("roundtrip complex", function()
    local input = {a = "hello", b = {1, 2, 3}, c = true}
    local json = encoder.encode(input)
    local v, err = decoder.decode(json)
    assert(not err, err)
    assert_eq(v.a, "hello")
    assert_eq(v.b[2], 2)
    assert_eq(v.c, true)
end)

print("\nAll JSON encoder/decoder tests passed.")
