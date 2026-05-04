-- Tests for codec/cbor.lua

package.path = "runtime/?.lua;" .. package.path

local cbor = require("codec.cbor")
local schema_mod = require("schema")
local stype = schema_mod.type

local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " — " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. " expected: " .. tostring(b) .. ", got: " .. tostring(a), 2)
    end
end

local function hex(s)
    local out = {}
    for i = 1, #s do
        out[i] = string.format("%02x", s:byte(i))
    end
    return table.concat(out)
end

local codec = cbor.new()

-- Roundtrip tests

test("roundtrip: simple structure", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Name = { type = stype.STRING },
            Age = { type = stype.INTEGER },
        },
    }
    local input = { Name = "Alice", Age = 30 }
    local bytes, err = codec:serialize(input, schema)
    assert(not err, tostring(err and err.message))
    assert(#bytes > 0, "should produce bytes")
    local result, derr = codec:deserialize(bytes, schema)
    assert(not derr, tostring(derr and derr.message))
    assert_eq(result.Name, "Alice")
    assert_eq(result.Age, 30)
end)

test("roundtrip: boolean", function()
    local schema = { type = stype.STRUCTURE, members = {
        T = { type = stype.BOOLEAN },
        F = { type = stype.BOOLEAN },
    }}
    local bytes = codec:serialize({ T = true, F = false }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.T, true)
    assert_eq(result.F, false)
end)

test("roundtrip: integers", function()
    local schema = { type = stype.STRUCTURE, members = {
        Small = { type = stype.INTEGER },
        Neg = { type = stype.INTEGER },
        Big = { type = stype.LONG },
    }}
    local bytes = codec:serialize({ Small = 42, Neg = -100, Big = 1000000 }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.Small, 42)
    assert_eq(result.Neg, -100)
    assert_eq(result.Big, 1000000)
end)

test("roundtrip: float/double", function()
    local schema = { type = stype.STRUCTURE, members = {
        F = { type = stype.FLOAT },
        D = { type = stype.DOUBLE },
    }}
    local bytes = codec:serialize({ F = 3.14, D = 2.718281828 }, schema)
    local result = codec:deserialize(bytes, schema)
    assert(math.abs(result.F - 3.14) < 0.001, "float mismatch: " .. result.F)
    assert(math.abs(result.D - 2.718281828) < 0.0001, "double mismatch: " .. result.D)
end)

test("roundtrip: string", function()
    local schema = { type = stype.STRUCTURE, members = {
        S = { type = stype.STRING },
    }}
    local bytes = codec:serialize({ S = "hello world" }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.S, "hello world")
end)

test("roundtrip: blob", function()
    local schema = { type = stype.STRUCTURE, members = {
        B = { type = stype.BLOB },
    }}
    local bytes = codec:serialize({ B = "\x00\x01\x02\xFF" }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.B, "\x00\x01\x02\xFF")
end)

test("roundtrip: list", function()
    local schema = { type = stype.STRUCTURE, members = {
        Items = { type = stype.LIST, member = { type = stype.STRING } },
    }}
    local bytes = codec:serialize({ Items = { "a", "b", "c" } }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(#result.Items, 3)
    assert_eq(result.Items[1], "a")
    assert_eq(result.Items[2], "b")
    assert_eq(result.Items[3], "c")
end)

test("roundtrip: map", function()
    local schema = { type = stype.STRUCTURE, members = {
        Tags = { type = stype.MAP, key = { type = stype.STRING }, value = { type = stype.STRING } },
    }}
    local bytes = codec:serialize({ Tags = { foo = "bar", baz = "qux" } }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.Tags.foo, "bar")
    assert_eq(result.Tags.baz, "qux")
end)

test("roundtrip: nested structure", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Inner = {
                type = stype.STRUCTURE,
                members = {
                    Value = { type = stype.STRING },
                    Count = { type = stype.INTEGER },
                },
            },
        },
    }
    local bytes = codec:serialize({ Inner = { Value = "test", Count = 5 } }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.Inner.Value, "test")
    assert_eq(result.Inner.Count, 5)
end)

test("roundtrip: union", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Choice = {
                type = stype.UNION,
                members = {
                    Str = { type = stype.STRING },
                    Num = { type = stype.INTEGER },
                },
            },
        },
    }
    local bytes = codec:serialize({ Choice = { Str = "hello" } }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.Choice.Str, "hello")
    assert_eq(result.Choice.Num, nil)
end)

test("roundtrip: timestamp (integer)", function()
    local schema = { type = stype.STRUCTURE, members = {
        T = { type = stype.TIMESTAMP },
    }}
    local bytes = codec:serialize({ T = 1234567890 }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.T, 1234567890)
end)

test("roundtrip: timestamp (fractional)", function()
    local schema = { type = stype.STRUCTURE, members = {
        T = { type = stype.TIMESTAMP },
    }}
    local bytes = codec:serialize({ T = 1234567890.123 }, schema)
    local result = codec:deserialize(bytes, schema)
    assert(math.abs(result.T - 1234567890.123) < 0.001, "timestamp mismatch")
end)

test("roundtrip: empty structure", function()
    local schema = { type = stype.STRUCTURE, members = {} }
    local bytes = codec:serialize({}, schema)
    local result = codec:deserialize(bytes, schema)
    assert(type(result) == "table")
end)

test("roundtrip: nil members omitted", function()
    local schema = { type = stype.STRUCTURE, members = {
        A = { type = stype.STRING },
        B = { type = stype.STRING },
    }}
    local bytes = codec:serialize({ A = "hello" }, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result.A, "hello")
    assert_eq(result.B, nil)
end)

test("deserialize: empty bytes", function()
    local schema = { type = stype.STRUCTURE, members = {} }
    local result, err = codec:deserialize("", schema)
    assert(not err)
    assert(type(result) == "table")
end)

-- Encoding size tests

test("encode: small integer uses minimal bytes", function()
    local schema = { type = stype.INTEGER }
    local bytes = codec:serialize(0, schema)
    assert_eq(#bytes, 1, "0 should be 1 byte")
    assert_eq(bytes:byte(1), 0x00)

    bytes = codec:serialize(23, schema)
    assert_eq(#bytes, 1, "23 should be 1 byte")

    bytes = codec:serialize(24, schema)
    assert_eq(#bytes, 2, "24 should be 2 bytes")
end)

test("encode: negative integer", function()
    local schema = { type = stype.INTEGER }
    local bytes = codec:serialize(-1, schema)
    assert_eq(#bytes, 1)
    assert_eq(bytes:byte(1), 0x20) -- major type 1, value 0 = -1
end)

test("encode: timestamp has tag 1", function()
    local schema = { type = stype.TIMESTAMP }
    local bytes = codec:serialize(0, schema)
    assert_eq(bytes:byte(1), 0xC1) -- tag 1
    assert_eq(bytes:byte(2), 0x00) -- value 0
end)

test("decode: half-precision float (infinity)", function()
    -- 0xF97C00 = +Infinity in half-precision
    local bytes = string.char(0xF9, 0x7C, 0x00)
    local val = cbor.decode_item(bytes, 1)
    assert_eq(val, math.huge)
end)

test("decode: half-precision float (NaN)", function()
    local bytes = string.char(0xF9, 0x7E, 0x00)
    local val = cbor.decode_item(bytes, 1)
    assert(val ~= val, "expected NaN")
end)

test("decode: half-precision float (negative infinity)", function()
    local bytes = string.char(0xF9, 0xFC, 0x00)
    local val = cbor.decode_item(bytes, 1)
    assert_eq(val, -math.huge)
end)

test("roundtrip: integer as float", function()
    -- Float value that is an integer should roundtrip
    local schema = { type = stype.FLOAT }
    local bytes = codec:serialize(256, schema)
    local result = codec:deserialize(bytes, schema)
    assert_eq(result, 256)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
