-- Test: runtime/smithy/dynamic.lua
-- Run: luajit test/test_dynamic.lua

package.path = "runtime/?.lua;" .. package.path

local dynamic = require("smithy.dynamic")
local traits = require("smithy.traits")

local pass, fail = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
        print("PASS: " .. name)
    else
        fail = fail + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function assert_not_nil(a, msg)
    if a == nil then error((msg or "assert_not_nil") .. ": got nil", 2) end
end

local function assert_nil(a, msg)
    if a ~= nil then error((msg or "assert_nil") .. ": expected nil, got " .. tostring(a), 2) end
end

-- === Model loading ===

test("load_model from file", function()
    local model, err = dynamic.load_model("test/fixtures/test_service.json")
    assert_not_nil(model, "model")
    assert_nil(err)
    assert_eq(model.smithy, "2.0")
    assert_not_nil(model.shapes)
end)

test("load_model from table", function()
    local input = { smithy = "2.0", shapes = {} }
    local model = dynamic.load_model(input)
    assert_eq(model, input)
end)

test("load_model bad path", function()
    local model, err = dynamic.load_model("/nonexistent/path.json")
    assert_nil(model)
    assert_not_nil(err)
end)

-- === Client creation ===

test("new with model file", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert_not_nil(client, "client should not be nil: " .. tostring(err))
    assert_nil(err)
end)

test("new auto-detects single service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert_not_nil(client, tostring(err))
end)

test("new with explicit service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        service = "test.example#TestService",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert_not_nil(client, tostring(err))
end)

test("new fails with bad service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        service = "test.example#NonExistent",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert_nil(client)
    assert_not_nil(err)
end)

-- === Operations listing ===

test("operations() lists available ops", function()
    local client = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    local ops = client:operations()
    assert_eq(#ops, 2)
    -- sorted
    assert_eq(ops[1], "GetItem")
    assert_eq(ops[2], "PutItem")
end)

-- === Schema conversion ===

test("call unknown operation returns error", function()
    local client = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    local result, err = client:call("NonExistent", {})
    assert_nil(result)
    assert_eq(err.type, "sdk")
end)

-- === Full call with mock transport ===

test("call serializes and deserializes via pipeline", function()
    local captured_request = nil
    local http = require("smithy.http")
    local mock_http = function(request)
        captured_request = request
        return {
            status_code = 200,
            headers = { ["content-type"] = "application/x-amz-json-1.0" },
            body = http.string_reader('{"Item":{"name":{"S":"hello"}}}'),
        }, nil
    end

    local client = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
        http_client = mock_http,
        -- Skip auth for this test
        auth_scheme_resolver = function()
            return { { scheme_id = "smithy.api#noAuth" } }
        end,
    })

    local result, err = client:call("GetItem", {
        TableName = "my-table",
        Key = { id = { S = "123" } },
    })

    -- Verify request was made
    assert_not_nil(captured_request, "request should have been captured")
    assert_eq(captured_request.method, "POST")

    -- Verify response was deserialized
    assert_not_nil(result, "result: " .. tostring(err and err.message))
    assert_not_nil(result.Item)
    assert_eq(result.Item.name.S, "hello")
end)

-- === REST protocol test ===

local REST_MODEL = {
    smithy = "2.0",
    shapes = {
        ["test.rest#RestService"] = {
            type = "service",
            version = "2023-01-01",
            operations = { { target = "test.rest#GetThing" } },
            traits = {
                ["aws.protocols#restJson1"] = {},
                ["aws.auth#sigv4"] = { name = "resttest" },
                ["smithy.api#auth"] = { "aws.auth#sigv4" },
            },
        },
        ["test.rest#GetThing"] = {
            type = "operation",
            input = { target = "test.rest#GetThingInput" },
            output = { target = "test.rest#GetThingOutput" },
            traits = {
                ["smithy.api#http"] = { method = "GET", uri = "/things/{thingId}" },
            },
        },
        ["test.rest#GetThingInput"] = {
            type = "structure",
            members = {
                thingId = {
                    target = "smithy.api#String",
                    traits = {
                        ["smithy.api#required"] = {},
                        ["smithy.api#httpLabel"] = {},
                    },
                },
                filter = {
                    target = "smithy.api#String",
                    traits = {
                        ["smithy.api#httpQuery"] = "filter",
                    },
                },
            },
        },
        ["test.rest#GetThingOutput"] = {
            type = "structure",
            members = {
                name = { target = "smithy.api#String" },
                count = { target = "smithy.api#Integer" },
            },
        },
        ["smithy.api#String"] = { type = "string" },
        ["smithy.api#Integer"] = { type = "integer" },
    },
}

test("REST protocol: HTTP bindings in path and query", function()
    local captured_request = nil
    local http = require("smithy.http")
    local mock_http = function(request)
        captured_request = request
        return {
            status_code = 200,
            headers = { ["content-type"] = "application/json" },
            body = http.string_reader('{"name":"widget","count":42}'),
        }, nil
    end

    local client = dynamic.new({
        model = REST_MODEL,
        region = "us-east-1",
        endpoint_url = "https://example.com",
        http_client = mock_http,
        auth_scheme_resolver = function()
            return { { scheme_id = "smithy.api#noAuth" } }
        end,
    })

    local result, err = client:call("GetThing", {
        thingId = "abc123",
        filter = "active",
    })

    assert_not_nil(captured_request, "request captured")
    -- Path should have label expanded
    assert(captured_request.url:find("abc123"), "URL should contain thingId: " .. captured_request.url)
    -- Query param
    assert(captured_request.url:find("filter=active"), "URL should contain query: " .. captured_request.url)
    -- Method
    assert_eq(captured_request.method, "GET")

    -- Response
    assert_not_nil(result, "result: " .. tostring(err and err.message))
    assert_eq(result.name, "widget")
    assert_eq(result.count, 42)
end)

-- === Summary ===
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
