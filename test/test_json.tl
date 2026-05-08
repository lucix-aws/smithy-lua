local assert = require("luassert") as any
-- Test: runtime/json/encoder.lua and runtime/json/decoder.lua

local encoder = require("smithy.json.encoder")
local decoder = require("smithy.json.decoder")

local function roundtrip(v: any): any, string
    local json = encoder.encode(v)
    local decoded, err = decoder.decode(json)
    assert(not err, "decode error: " .. tostring(err))
    return decoded, json
end

describe("json", function()
    -- === Encoder tests ===

    it("encode string", function()
        assert.are.equal('"hello"', encoder.encode("hello"))
    end)

    it("encode string with escapes", function()
        assert.are.equal('"a\\"b\\\\c"', encoder.encode('a"b\\c'))
    end)

    it("encode string with control chars", function()
        assert.are.equal('"a\\nb\\tc"', encoder.encode("a\nb\tc"))
    end)

    it("encode string with null byte", function()
        assert.are.equal('"a\\u0000b"', encoder.encode("a\0b"))
    end)

    it("encode integer", function()
        assert.are.equal("42", encoder.encode(42))
    end)

    it("encode negative integer", function()
        assert.are.equal("-7", encoder.encode(-7))
    end)

    it("encode float", function()
        local json = encoder.encode(3.14)
        assert(json == "3.14" or (json as string):find("3.14") == 1, "expected 3.14, got " .. json)
    end)

    it("encode zero", function()
        assert.are.equal("0", encoder.encode(0))
    end)

    it("encode NaN", function()
        assert.are.equal('"NaN"', encoder.encode(0/0))
    end)

    it("encode Infinity", function()
        assert.are.equal('"Infinity"', encoder.encode(math.huge))
    end)

    it("encode -Infinity", function()
        assert.are.equal('"-Infinity"', encoder.encode(-math.huge))
    end)

    it("encode true", function()
        assert.are.equal("true", encoder.encode(true))
    end)

    it("encode false", function()
        assert.are.equal("false", encoder.encode(false))
    end)

    it("encode nil", function()
        assert.are.equal("null", encoder.encode(nil))
    end)

    it("encode empty array", function()
        assert.are.equal("[]", encoder.encode({}))
    end)

    it("encode array", function()
        assert.are.equal("[1,2,3]", encoder.encode({1, 2, 3}))
    end)

    it("encode nested array", function()
        assert.are.equal("[[1,2],[3]]", encoder.encode({{1, 2}, {3}}))
    end)

    it("encode object (sorted keys)", function()
        assert.are.equal('{"a":1,"b":2}', encoder.encode({b = 2, a = 1}))
    end)

    it("encode nested object", function()
        assert.are.equal('{"a":{"x":1}}', encoder.encode({a = {x = 1}}))
    end)

    -- === Decoder tests ===

    it("decode string", function()
        local v, err = decoder.decode('"hello"')
        assert(not err, err)
        assert.are.equal("hello", v)
    end)

    it("decode string with escapes", function()
        local v, err = decoder.decode('"a\\"b\\\\c"')
        assert(not err, err)
        assert.are.equal('a"b\\c', v)
    end)

    it("decode string with unicode escape", function()
        local v, err = decoder.decode('"\\u0041"')
        assert(not err, err)
        assert.are.equal("A", v)
    end)

    it("decode string with surrogate pair", function()
        -- U+1F600 = D83D DE00
        local v, err = decoder.decode('"\\uD83D\\uDE00"')
        assert(not err, err)
        assert.are.equal("\xF0\x9F\x98\x80", v)
    end)

    it("decode integer", function()
        local v, err = decoder.decode("42")
        assert(not err, err)
        assert.are.equal(42, v)
    end)

    it("decode negative number", function()
        local v, err = decoder.decode("-3.14")
        assert(not err, err)
        assert(math.abs((v as number) - (-3.14)) < 1e-10, "expected -3.14")
    end)

    it("decode true", function()
        local v, err = decoder.decode("true")
        assert(not err, err)
        assert.are.equal(true, v)
    end)

    it("decode false", function()
        local v, err = decoder.decode("false")
        assert(not err, err)
        assert.are.equal(false, v)
    end)

    it("decode null", function()
        local v, err = decoder.decode("null")
        assert(not err, err)
        assert.are.equal(nil, v)
    end)

    it("decode empty array", function()
        local v, err = decoder.decode("[]")
        assert(not err, err)
        assert.are.equal(0, #(v as {any}))
    end)

    it("decode array", function()
        local v, err = decoder.decode("[1,2,3]")
        assert(not err, err)
        local arr = v as {any}
        assert.are.equal(3, #arr)
        assert.are.equal(1, arr[1])
        assert.are.equal(3, arr[3])
    end)

    it("decode empty object", function()
        local v, err = decoder.decode("{}")
        assert(not err, err)
        assert.are.equal(nil, next(v as {string:any}))
    end)

    it("decode object", function()
        local v, err = decoder.decode('{"a":1,"b":"two"}')
        assert(not err, err)
        local obj = v as {string:any}
        assert.are.equal(1, obj.a)
        assert.are.equal("two", obj.b)
    end)

    it("decode nested", function()
        local v, err = decoder.decode('{"a":{"b":[1,true,null]}}')
        assert(not err, err)
        local obj = v as {string:any}
        local a = obj.a as {string:any}
        local b = a.b as {any}
        assert.are.equal(1, b[1])
        assert.are.equal(true, b[2])
        assert.are.equal(nil, b[3])
    end)

    it("decode with whitespace", function()
        local v, err = decoder.decode('  { "a" : 1 , "b" : [ 2 ] }  ')
        assert(not err, err)
        local obj = v as {string:any}
        assert.are.equal(1, obj.a)
        assert.are.equal(2, (obj.b as {any})[1])
    end)

    it("decode error: unterminated string", function()
        local _, err = decoder.decode('"hello')
        assert(err, "expected error")
        assert((err as string):find("unterminated"), "expected unterminated error, got: " .. (err as string))
    end)

    it("decode error: invalid literal", function()
        local _, err = decoder.decode("tru")
        assert(err, "expected error")
    end)

    -- === Roundtrip tests ===

    it("roundtrip string", function()
        local v = roundtrip("hello world")
        assert.are.equal("hello world", v)
    end)

    it("roundtrip number", function()
        local v = roundtrip(42)
        assert.are.equal(42, v)
    end)

    it("roundtrip boolean", function()
        local v = roundtrip(true)
        assert.are.equal(true, v)
    end)

    it("roundtrip complex", function()
        local input = {a = "hello", b = {1, 2, 3}, c = true}
        local json = encoder.encode(input)
        local v, err = decoder.decode(json)
        assert(not err, err)
        local obj = v as {string:any}
        assert.are.equal("hello", obj.a)
        assert.are.equal(2, (obj.b as {any})[2])
        assert.are.equal(true, obj.c)
    end)
end)
