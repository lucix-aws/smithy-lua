-- Test: runtime/codec/json.lua — schema-aware JSON codec
-- Run: luajit test/test_codec_json.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local json_codec = require("codec.json")
local schema_mod = require("schema")
local stype = schema_mod.type
local strait = schema_mod.trait

local pass_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
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

local function assert_match(s, pattern, msg)
    if not s:find(pattern) then
        error((msg or "assert_match") .. ": '" .. s .. "' does not match '" .. pattern .. "'", 2)
    end
end

-- Prelude schemas
local string_schema  = { id = "smithy.api#String",  type = stype.STRING }
local integer_schema = { id = "smithy.api#Integer", type = stype.INTEGER }
local long_schema    = { id = "smithy.api#Long",    type = stype.LONG }
local float_schema   = { id = "smithy.api#Float",   type = stype.FLOAT }
local double_schema  = { id = "smithy.api#Double",  type = stype.DOUBLE }
local boolean_schema = { id = "smithy.api#Boolean", type = stype.BOOLEAN }
local blob_schema    = { id = "smithy.api#Blob",    type = stype.BLOB }
local timestamp_schema = { id = "smithy.api#Timestamp", type = stype.TIMESTAMP }

-- === Serialize tests ===

local codec = json_codec.new()

test("serialize simple structure", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "Name", target = string_schema, traits = {} },
            { name = "Age",  target = integer_schema, traits = {} },
        },
    }
    local json, err = codec:serialize({ Name = "Alice", Age = 30 }, schema)
    assert(not err, tostring(err and err.message))
    assert_eq(json, '{"Name":"Alice","Age":30}')
end)

test("serialize skips nil members", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "A", target = string_schema, traits = {} },
            { name = "B", target = string_schema, traits = {} },
        },
    }
    local json, err = codec:serialize({ A = "yes" }, schema)
    assert(not err)
    assert_eq(json, '{"A":"yes"}')
end)

test("serialize with json_name", function()
    local codec_jn = json_codec.new({ use_json_name = true })
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "MyField", target = string_schema, traits = { [strait.JSON_NAME] = "myField" } },
        },
    }
    local json, err = codec_jn:serialize({ MyField = "val" }, schema)
    assert(not err)
    assert_eq(json, '{"myField":"val"}')
end)

test("serialize ignores json_name when use_json_name=false", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "MyField", target = string_schema, traits = { [strait.JSON_NAME] = "myField" } },
        },
    }
    local json, err = codec:serialize({ MyField = "val" }, schema)
    assert(not err)
    assert_eq(json, '{"MyField":"val"}')
end)

test("serialize list", function()
    local schema = {
        id = "test#StringList", type = stype.LIST,
        member = string_schema,
    }
    local json, err = codec:serialize({"a", "b", "c"}, schema)
    assert(not err)
    assert_eq(json, '["a","b","c"]')
end)

test("serialize map", function()
    local schema = {
        id = "test#StringMap", type = stype.MAP,
        key = string_schema,
        value = integer_schema,
    }
    local json, err = codec:serialize({ x = 1, y = 2 }, schema)
    assert(not err)
    assert_eq(json, '{"x":1,"y":2}')
end)

test("serialize nested structure", function()
    local inner_schema = {
        id = "test#Inner", type = stype.STRUCTURE,
        members = {
            { name = "Value", target = string_schema, traits = {} },
        },
    }
    local outer_schema = {
        id = "test#Outer", type = stype.STRUCTURE,
        members = {
            { name = "Inner", target = inner_schema, traits = {} },
        },
    }
    local json, err = codec:serialize({ Inner = { Value = "hi" } }, outer_schema)
    assert(not err)
    assert_eq(json, '{"Inner":{"Value":"hi"}}')
end)

test("serialize float with .0", function()
    local json, err = codec:serialize(5, float_schema)
    assert(not err)
    assert_eq(json, "5.0")
end)

test("serialize float NaN", function()
    local json, err = codec:serialize(0/0, double_schema)
    assert(not err)
    assert_eq(json, '"NaN"')
end)

test("serialize float Infinity", function()
    local json, err = codec:serialize(math.huge, float_schema)
    assert(not err)
    assert_eq(json, '"Infinity"')
end)

test("serialize integer (no decimals)", function()
    local json, err = codec:serialize(42, integer_schema)
    assert(not err)
    assert_eq(json, "42")
end)

test("serialize long", function()
    local json, err = codec:serialize(9007199254740992, long_schema)
    assert(not err)
    assert_eq(json, "9007199254740992")
end)

test("serialize boolean", function()
    local json, err = codec:serialize(true, boolean_schema)
    assert(not err)
    assert_eq(json, "true")
end)

test("serialize blob as base64", function()
    local json, err = codec:serialize("hello", blob_schema)
    assert(not err)
    assert_eq(json, '"aGVsbG8="')
end)

test("serialize timestamp epoch-seconds", function()
    local json, err = codec:serialize(1609459200, timestamp_schema)
    assert(not err)
    assert_eq(json, "1609459200.000")
end)

test("serialize union", function()
    local schema = {
        id = "test#MyUnion", type = stype.UNION,
        members = {
            { name = "Str", target = string_schema, traits = {} },
            { name = "Num", target = integer_schema, traits = {} },
        },
    }
    local json, err = codec:serialize({ Str = "hello" }, schema)
    assert(not err)
    assert_eq(json, '{"Str":"hello"}')
end)

test("serialize empty structure", function()
    local schema = {
        id = "test#Empty", type = stype.STRUCTURE,
        members = {},
    }
    local json, err = codec:serialize({}, schema)
    assert(not err)
    assert_eq(json, '{}')
end)

-- === Deserialize tests ===

test("deserialize simple structure", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "Name", target = string_schema, traits = {} },
            { name = "Age",  target = integer_schema, traits = {} },
        },
    }
    local val, err = codec:deserialize('{"Name":"Bob","Age":25}', schema)
    assert(not err, tostring(err and err.message))
    assert_eq(val.Name, "Bob")
    assert_eq(val.Age, 25)
end)

test("deserialize drops unknown members", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "A", target = string_schema, traits = {} },
        },
    }
    local val, err = codec:deserialize('{"A":"yes","B":"no"}', schema)
    assert(not err)
    assert_eq(val.A, "yes")
    assert_eq(val.B, nil)
end)

test("deserialize with json_name", function()
    local codec_jn = json_codec.new({ use_json_name = true })
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "MyField", target = string_schema, traits = { [strait.JSON_NAME] = "myField" } },
        },
    }
    local val, err = codec_jn:deserialize('{"myField":"val"}', schema)
    assert(not err)
    assert_eq(val.MyField, "val")
end)

test("deserialize list", function()
    local schema = {
        id = "test#IntList", type = stype.LIST,
        member = integer_schema,
    }
    local val, err = codec:deserialize('[1,2,3]', schema)
    assert(not err)
    assert_eq(#val, 3)
    assert_eq(val[2], 2)
end)

test("deserialize map", function()
    local schema = {
        id = "test#StringMap", type = stype.MAP,
        key = string_schema,
        value = string_schema,
    }
    local val, err = codec:deserialize('{"a":"x","b":"y"}', schema)
    assert(not err)
    assert_eq(val.a, "x")
    assert_eq(val.b, "y")
end)

test("deserialize float NaN from string", function()
    local val, err = codec:deserialize('"NaN"', double_schema)
    assert(not err)
    assert(val ~= val, "expected NaN")
end)

test("deserialize float Infinity from string", function()
    local val, err = codec:deserialize('"Infinity"', float_schema)
    assert(not err)
    assert_eq(val, math.huge)
end)

test("deserialize blob from base64", function()
    local val, err = codec:deserialize('"aGVsbG8="', blob_schema)
    assert(not err)
    assert_eq(val, "hello")
end)

test("deserialize union", function()
    local schema = {
        id = "test#MyUnion", type = stype.UNION,
        members = {
            { name = "Str", target = string_schema, traits = {} },
            { name = "Num", target = integer_schema, traits = {} },
        },
    }
    local val, err = codec:deserialize('{"Num":42}', schema)
    assert(not err)
    assert_eq(val.Num, 42)
    assert_eq(val.Str, nil)
end)

test("deserialize error on bad json", function()
    local val, err = codec:deserialize('{bad}', string_schema)
    assert(err, "expected error")
    assert_eq(err.type, "sdk")
end)

-- === Roundtrip tests ===

test("roundtrip structure", function()
    local schema = {
        id = "test#Foo", type = stype.STRUCTURE,
        members = {
            { name = "Name", target = string_schema, traits = {} },
            { name = "Count", target = integer_schema, traits = {} },
            { name = "Active", target = boolean_schema, traits = {} },
        },
    }
    local input = { Name = "test", Count = 99, Active = true }
    local json, err = codec:serialize(input, schema)
    assert(not err)
    local output
    output, err = codec:deserialize(json, schema)
    assert(not err)
    assert_eq(output.Name, "test")
    assert_eq(output.Count, 99)
    assert_eq(output.Active, true)
end)

test("roundtrip nested with list and map", function()
    local list_schema = {
        id = "test#StringList", type = stype.LIST,
        member = string_schema,
    }
    local map_schema = {
        id = "test#IntMap", type = stype.MAP,
        key = string_schema,
        value = integer_schema,
    }
    local schema = {
        id = "test#Complex", type = stype.STRUCTURE,
        members = {
            { name = "Tags",   target = list_schema, traits = {} },
            { name = "Counts", target = map_schema,  traits = {} },
        },
    }
    local input = { Tags = {"a", "b"}, Counts = { x = 1, y = 2 } }
    local json, err = codec:serialize(input, schema)
    assert(not err)
    local output
    output, err = codec:deserialize(json, schema)
    assert(not err)
    assert_eq(output.Tags[1], "a")
    assert_eq(output.Tags[2], "b")
    assert_eq(output.Counts.x, 1)
    assert_eq(output.Counts.y, 2)
end)

-- === Base64 tests ===

test("base64 roundtrip", function()
    local cases = { "", "f", "fo", "foo", "foob", "fooba", "foobar" }
    for _, s in ipairs(cases) do
        local encoded = json_codec._base64_encode(s)
        local decoded = json_codec._base64_decode(encoded)
        assert_eq(decoded, s, "base64 roundtrip for '" .. s .. "'")
    end
end)

test("base64 known values", function()
    assert_eq(json_codec._base64_encode(""), "")
    assert_eq(json_codec._base64_encode("f"), "Zg==")
    assert_eq(json_codec._base64_encode("fo"), "Zm8=")
    assert_eq(json_codec._base64_encode("foo"), "Zm9v")
    assert_eq(json_codec._base64_encode("hello"), "aGVsbG8=")
end)

print(string.format("\nAll %d JSON codec tests passed.", pass_count))
