-- Tests for codec/xml.lua

package.path = "runtime/?.lua;" .. package.path

local xml = require("smithy.codec.xml")
local schema_mod = require("smithy.schema")
local stype = schema_mod.type
local strait = schema_mod.trait

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

local function assert_contains(s, sub, msg)
    if not s:find(sub, 1, true) then
        error((msg or "") .. " expected to contain: " .. sub .. ", got: " .. s, 2)
    end
end

local codec = xml.new()

-- Serialize tests

test("serialize: simple structure", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Name = { type = stype.STRING },
            Age = { type = stype.INTEGER },
        },
    }
    local result, err = codec:serialize({ Name = "Alice", Age = 30 }, schema, "Person")
    assert(not err, tostring(err and err.message))
    assert_contains(result, "<Person>")
    assert_contains(result, "<Age>30</Age>")
    assert_contains(result, "<Name>Alice</Name>")
    assert_contains(result, "</Person>")
end)

test("serialize: xml_name trait", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Name = { type = stype.STRING, traits = { [strait.XML_NAME] = "FullName" } },
        },
    }
    local result = codec:serialize({ Name = "Bob" }, schema, "Person")
    assert_contains(result, "<FullName>Bob</FullName>")
end)

test("serialize: xml_attribute", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Id = { type = stype.STRING, traits = { [strait.XML_ATTRIBUTE] = true } },
            Name = { type = stype.STRING },
        },
    }
    local result = codec:serialize({ Id = "123", Name = "Alice" }, schema, "Item")
    assert_contains(result, '<Item Id="123">')
    assert_contains(result, "<Name>Alice</Name>")
end)

test("serialize: xml_namespace", function()
    local schema = {
        type = stype.STRUCTURE,
        traits = { [strait.XML_NAMESPACE] = { uri = "https://example.com/" } },
        members = {
            Name = { type = stype.STRING },
        },
    }
    local result = codec:serialize({ Name = "test" }, schema, "Root")
    assert_contains(result, 'xmlns="https://example.com/"')
end)

test("serialize: list (wrapped)", function()
    local schema = {
        type = stype.LIST,
        member = { type = stype.STRING },
    }
    local result = codec:serialize({ "a", "b", "c" }, schema, "Items")
    assert_contains(result, "<Items>")
    assert_contains(result, "<member>a</member>")
    assert_contains(result, "<member>b</member>")
    assert_contains(result, "<member>c</member>")
    assert_contains(result, "</Items>")
end)

test("serialize: list (flattened)", function()
    local schema = {
        type = stype.LIST,
        member = { type = stype.STRING },
        traits = { [strait.XML_FLATTENED] = true },
    }
    local result = codec:serialize({ "a", "b" }, schema, "Item")
    assert_eq(result, "<Item>a</Item><Item>b</Item>")
end)

test("serialize: map (wrapped)", function()
    local schema = {
        type = stype.MAP,
        key = { type = stype.STRING },
        value = { type = stype.STRING },
    }
    local result = codec:serialize({ foo = "bar" }, schema, "Tags")
    assert_contains(result, "<Tags>")
    assert_contains(result, "<entry>")
    assert_contains(result, "<key>foo</key>")
    assert_contains(result, "<value>bar</value>")
    assert_contains(result, "</Tags>")
end)

test("serialize: map (flattened)", function()
    local schema = {
        type = stype.MAP,
        key = { type = stype.STRING },
        value = { type = stype.STRING },
        traits = { [strait.XML_FLATTENED] = true },
    }
    local result = codec:serialize({ foo = "bar" }, schema, "Tag")
    assert_contains(result, "<Tag>")
    assert_contains(result, "<key>foo</key>")
    assert_contains(result, "<value>bar</value>")
    assert_contains(result, "</Tag>")
    -- Should NOT have <entry>
    assert(not result:find("<entry>"), "should not have <entry> wrapper")
end)

test("serialize: boolean", function()
    local schema = { type = stype.STRUCTURE, members = {
        Flag = { type = stype.BOOLEAN },
    }}
    local result = codec:serialize({ Flag = true }, schema, "R")
    assert_contains(result, "<Flag>true</Flag>")
end)

test("serialize: blob (base64)", function()
    local schema = { type = stype.STRUCTURE, members = {
        Data = { type = stype.BLOB },
    }}
    local result = codec:serialize({ Data = "hello" }, schema, "R")
    assert_contains(result, "<Data>aGVsbG8=</Data>")
end)

test("serialize: float special values", function()
    local schema = { type = stype.STRUCTURE, members = {
        A = { type = stype.FLOAT },
        B = { type = stype.FLOAT },
        C = { type = stype.FLOAT },
    }}
    local result = codec:serialize({ A = 0/0, B = math.huge, C = -math.huge }, schema, "R")
    assert_contains(result, "<A>NaN</A>")
    assert_contains(result, "<B>Infinity</B>")
    assert_contains(result, "<C>-Infinity</C>")
end)

test("serialize: xml escape", function()
    local schema = { type = stype.STRUCTURE, members = {
        Name = { type = stype.STRING },
    }}
    local result = codec:serialize({ Name = '<a&b"c>' }, schema, "R")
    assert_contains(result, "&lt;a&amp;b&quot;c&gt;")
end)

test("serialize: union", function()
    local schema = {
        type = stype.UNION,
        members = {
            Str = { type = stype.STRING },
            Num = { type = stype.INTEGER },
        },
    }
    local result = codec:serialize({ Str = "hello" }, schema, "Choice")
    assert_contains(result, "<Choice>")
    assert_contains(result, "<Str>hello</Str>")
    assert_contains(result, "</Choice>")
end)

-- Deserialize tests

test("deserialize: simple structure", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Name = { type = stype.STRING },
            Age = { type = stype.INTEGER },
        },
    }
    local xml_str = "<Person><Name>Alice</Name><Age>30</Age></Person>"
    local result, err = codec:deserialize(xml_str, schema)
    assert(not err, tostring(err and err.message))
    assert_eq(result.Name, "Alice")
    assert_eq(result.Age, 30)
end)

test("deserialize: xml_name trait", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Name = { type = stype.STRING, traits = { [strait.XML_NAME] = "FullName" } },
        },
    }
    local result = codec:deserialize("<P><FullName>Bob</FullName></P>", schema)
    assert_eq(result.Name, "Bob")
end)

test("deserialize: xml_attribute", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Id = { type = stype.STRING, traits = { [strait.XML_ATTRIBUTE] = true } },
            Name = { type = stype.STRING },
        },
    }
    local result = codec:deserialize('<Item Id="123"><Name>Alice</Name></Item>', schema)
    assert_eq(result.Id, "123")
    assert_eq(result.Name, "Alice")
end)

test("deserialize: list (wrapped)", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Items = {
                type = stype.LIST,
                member = { type = stype.STRING },
            },
        },
    }
    local result = codec:deserialize(
        "<R><Items><member>a</member><member>b</member></Items></R>", schema)
    assert_eq(#result.Items, 2)
    assert_eq(result.Items[1], "a")
    assert_eq(result.Items[2], "b")
end)

test("deserialize: list (flattened)", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Item = {
                type = stype.LIST,
                member = { type = stype.STRING },
                traits = { [strait.XML_FLATTENED] = true },
            },
        },
    }
    local result = codec:deserialize(
        "<R><Item>a</Item><Item>b</Item></R>", schema)
    assert_eq(#result.Item, 2)
    assert_eq(result.Item[1], "a")
    assert_eq(result.Item[2], "b")
end)

test("deserialize: map (wrapped)", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Tags = {
                type = stype.MAP,
                key = { type = stype.STRING },
                value = { type = stype.STRING },
            },
        },
    }
    local result = codec:deserialize(
        "<R><Tags><entry><key>foo</key><value>bar</value></entry></Tags></R>", schema)
    assert_eq(result.Tags.foo, "bar")
end)

test("deserialize: map (flattened)", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Tag = {
                type = stype.MAP,
                key = { type = stype.STRING },
                value = { type = stype.STRING },
                traits = { [strait.XML_FLATTENED] = true },
            },
        },
    }
    local result = codec:deserialize(
        "<R><Tag><key>a</key><value>1</value></Tag><Tag><key>b</key><value>2</value></Tag></R>", schema)
    assert_eq(result.Tag.a, "1")
    assert_eq(result.Tag.b, "2")
end)

test("deserialize: boolean", function()
    local schema = { type = stype.STRUCTURE, members = {
        Flag = { type = stype.BOOLEAN },
    }}
    local result = codec:deserialize("<R><Flag>true</Flag></R>", schema)
    assert_eq(result.Flag, true)
end)

test("deserialize: blob (base64)", function()
    local schema = { type = stype.STRUCTURE, members = {
        Data = { type = stype.BLOB },
    }}
    local result = codec:deserialize("<R><Data>aGVsbG8=</Data></R>", schema)
    assert_eq(result.Data, "hello")
end)

test("deserialize: float special values", function()
    local schema = { type = stype.STRUCTURE, members = {
        A = { type = stype.FLOAT },
        B = { type = stype.FLOAT },
        C = { type = stype.FLOAT },
    }}
    local result = codec:deserialize("<R><A>NaN</A><B>Infinity</B><C>-Infinity</C></R>", schema)
    assert(result.A ~= result.A, "expected NaN")
    assert_eq(result.B, math.huge)
    assert_eq(result.C, -math.huge)
end)

test("deserialize: empty body", function()
    local schema = { type = stype.STRUCTURE, members = {} }
    local result, err = codec:deserialize("", schema)
    assert(not err)
    assert(type(result) == "table")
end)

test("deserialize: xml unescape", function()
    local schema = { type = stype.STRUCTURE, members = {
        Name = { type = stype.STRING },
    }}
    local result = codec:deserialize("<R><Name>&lt;a&amp;b&gt;</Name></R>", schema)
    assert_eq(result.Name, "<a&b>")
end)

test("roundtrip: nested structure", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Inner = {
                type = stype.STRUCTURE,
                members = {
                    Value = { type = stype.STRING },
                },
            },
        },
    }
    local input = { Inner = { Value = "test" } }
    local xml_str = codec:serialize(input, schema, "Root")
    local result = codec:deserialize(xml_str, schema)
    assert_eq(result.Inner.Value, "test")
end)

test("roundtrip: list of structures", function()
    local schema = {
        type = stype.STRUCTURE,
        members = {
            Items = {
                type = stype.LIST,
                member = {
                    type = stype.STRUCTURE,
                    members = {
                        Name = { type = stype.STRING },
                    },
                },
            },
        },
    }
    local input = { Items = { { Name = "a" }, { Name = "b" } } }
    local xml_str = codec:serialize(input, schema, "Root")
    local result = codec:deserialize(xml_str, schema)
    assert_eq(#result.Items, 2)
    assert_eq(result.Items[1].Name, "a")
    assert_eq(result.Items[2].Name, "b")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
