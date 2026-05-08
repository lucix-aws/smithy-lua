local assert = require("luassert") as any
-- Test: runtime/smithy/dynamic.lua

local async = require("smithy.async")
local dynamic = require("smithy.dynamic")
local traits = require("smithy.traits")

local function wrap_http(fn: function({string:any}): {string:any}, any): {string:any}
    return { roundtrip = function(_: any, req: {string:any}): any
        local op = async.new_operation()
        op:resolve(fn(req))
        return op
    end }
end

local REST_MODEL: {string:any} = {
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

describe("dynamic", function()

it("load_model from file", function()
    local model, err = dynamic.load_model("test/fixtures/test_service.json")
    assert.is_truthy(model)
    assert.is_nil(err)
    assert.are.equal("2.0", (model as {string:any}).smithy)
    assert.is_truthy((model as {string:any}).shapes)
end)

it("load_model from table", function()
    local input = { smithy = "2.0", shapes = {} }
    local model = dynamic.load_model(input)
    assert.are.equal(input, model)
end)

it("load_model bad path", function()
    local model, err = dynamic.load_model("/nonexistent/path.json")
    assert.is_nil(model)
    assert.is_truthy(err)
end)

it("new with model file", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert.is_truthy(client)
    assert.is_nil(err)
end)

it("new auto-detects single service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert.is_truthy(client)
end)

it("new with explicit service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        service = "test.example#TestService",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert.is_truthy(client)
end)

it("new fails with bad service", function()
    local client, err = dynamic.new({
        model = "test/fixtures/test_service.json",
        service = "test.example#NonExistent",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    assert.is_nil(client)
    assert.is_truthy(err)
end)

it("operations() lists available ops", function()
    local client = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    local ops = client:operations()
    assert.are.equal(2, #ops)
    assert.are.equal("GetItem", ops[1])
    assert.are.equal("PutItem", ops[2])
end)

it("call unknown operation returns error", function()
    local client = dynamic.new({
        model = "test/fixtures/test_service.json",
        region = "us-east-1",
        endpoint_url = "https://example.com",
    })
    local result, err = client:call("NonExistent", {})
    assert.is_nil(result)
    assert.are.equal("sdk", (err as {string:string}).type)
end)

it("call serializes and deserializes via pipeline", function()
    local captured_request: {string:any} = nil
    local http = require("smithy.http")
    local mock_http = function(request: {string:any}): {string:any}, any
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
        http_client = wrap_http(mock_http),
        auth_scheme_resolver = function(): {any}
            return { { scheme_id = "smithy.api#noAuth" } }
        end,
    })

    local result, err = client:call("GetItem", {
        TableName = "my-table",
        Key = { id = { S = "123" } },
    }):await()

    assert.is_truthy(captured_request)
    assert.are.equal("POST", (captured_request as {string:any}).method)
    assert.is_truthy(result)
    assert.is_truthy((result as {string:any}).Item)
    assert.are.equal("hello", (result as {string:any}).Item.name.S)
end)

it("REST protocol: HTTP bindings in path and query", function()
    local captured_request: {string:any} = nil
    local http = require("smithy.http")
    local mock_http = function(request: {string:any}): {string:any}, any
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
        http_client = wrap_http(mock_http),
        auth_scheme_resolver = function(): {any}
            return { { scheme_id = "smithy.api#noAuth" } }
        end,
    })

    local result, err = client:call("GetThing", {
        thingId = "abc123",
        filter = "active",
    }):await()

    assert.is_truthy(captured_request)
    local url = (captured_request as {string:any}).url as string
    assert(url:find("abc123"), "URL should contain thingId: " .. url)
    assert(url:find("filter=active"), "URL should contain query: " .. url)
    assert.are.equal("GET", (captured_request as {string:any}).method)
    assert.is_truthy(result)
    assert.are.equal("widget", (result as {string:any}).name)
    assert.are.equal(42, (result as {string:any}).count)
end)

end)
