local assert = require("luassert") as any
-- Test: runtime/smithy/interceptor.lua + client.lua interceptor integration

local async = require("smithy.async")
local client_mod = require("smithy.client")
local auth = require("smithy.auth")
local schema = require("smithy.schema")

local function wrap_http(fn: function(any): any, any): {string:any}
    return { roundtrip = function(_: any, req: any): any
        local op = async.new_operation()
        op:resolve(fn(req))
        return op
    end }
end

local function assert_contains(tbl: {any}, value: any, msg: string)
    for _, v in ipairs(tbl) do
        if v == value then return end
    end
    error((msg or "assert_contains") .. ": " .. tostring(value) .. " not found", 2)
end

-- Mock protocol
local mock_protocol: {string:any} = {
    serialize = function(self: any, input: any, service: any, operation: any): any, any
        return {
            method = "POST",
            url = "/",
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(self: any, response: any, service: any, operation: any): any, any
        return { Result = "ok" }, nil
    end,
}

-- Mock identity
local mock_identity: {string:string} = { access_key = "AKID", secret_key = "SECRET" }

-- Standard test config
local function make_config(interceptors: {any}): {string:any}
    return {
        service_id = "test",
        protocol = mock_protocol,
        http_client = wrap_http(function(request: any): any, any
            return { status_code = 200, headers = {}, body = nil }, nil
        end),
        endpoint_provider = function(params: {string:any}): any, any
            return { url = "https://test.us-east-1.amazonaws.com" }, nil
        end,
        region = "us-east-1",
        auth_schemes = {
            ["aws.auth#sigv4"] = {
                scheme_id = "aws.auth#sigv4",
                identity_type = "aws_credentials",
                signer = function(req: any, id: any, props: any): any, any return req, nil end,
                identity_resolver = function(self: any, resolvers: any): any
                    return (resolvers as {string:any})[(self as {string:any}).identity_type as string]
                end,
            },
        },
        identity_resolvers = {
            aws_credentials = function(): any, any return mock_identity, nil end,
        },
        auth_scheme_resolver = function(service: any, operation: any, input: any): {any}
            return { { scheme_id = "aws.auth#sigv4", signer_properties = { signing_name = "test", signing_region = "us-east-1" } } }
        end,
        interceptors = interceptors,
    }
end

local test_service = schema.service({ id = "test" } as any)
local test_operation = schema.operation({ id = "TestOp" } as any)

describe("interceptor", function()

it("read hooks are called in order", function()
    local calls: {string} = {}
    local i1: {string:any} = { read_before_execution = function(self: any, ctx: any) calls[#calls+1] = "i1" end }
    local i2: {string:any} = { read_before_execution = function(self: any, ctx: any) calls[#calls+1] = "i2" end }
    local c = client_mod.new(make_config({i1, i2}))
    ;(c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal("i1", calls[1])
    assert.are.equal("i2", calls[2])
end)

it("full hook execution order", function()
    local calls: {string} = {}
    local i: {string:any} = {
        read_before_execution = function(self: any, ctx: any) calls[#calls+1] = "read_before_execution" end,
        modify_before_serialization = function(self: any, ctx: any): any calls[#calls+1] = "modify_before_serialization"; return (ctx as {string:any}).input end,
        read_before_serialization = function(self: any, ctx: any) calls[#calls+1] = "read_before_serialization" end,
        read_after_serialization = function(self: any, ctx: any) calls[#calls+1] = "read_after_serialization" end,
        modify_before_retry_loop = function(self: any, ctx: any): any calls[#calls+1] = "modify_before_retry_loop"; return (ctx as {string:any}).request end,
        read_before_attempt = function(self: any, ctx: any) calls[#calls+1] = "read_before_attempt" end,
        modify_before_signing = function(self: any, ctx: any): any calls[#calls+1] = "modify_before_signing"; return (ctx as {string:any}).request end,
        read_before_signing = function(self: any, ctx: any) calls[#calls+1] = "read_before_signing" end,
        read_after_signing = function(self: any, ctx: any) calls[#calls+1] = "read_after_signing" end,
        modify_before_transmit = function(self: any, ctx: any): any calls[#calls+1] = "modify_before_transmit"; return (ctx as {string:any}).request end,
        read_before_transmit = function(self: any, ctx: any) calls[#calls+1] = "read_before_transmit" end,
        read_after_transmit = function(self: any, ctx: any) calls[#calls+1] = "read_after_transmit" end,
        modify_before_deserialization = function(self: any, ctx: any): any calls[#calls+1] = "modify_before_deserialization"; return (ctx as {string:any}).response end,
        read_before_deserialization = function(self: any, ctx: any) calls[#calls+1] = "read_before_deserialization" end,
        read_after_deserialization = function(self: any, ctx: any) calls[#calls+1] = "read_after_deserialization" end,
        modify_before_attempt_completion = function(self: any, ctx: any, err: any): any, any calls[#calls+1] = "modify_before_attempt_completion"; return (ctx as {string:any}).output, err end,
        read_after_attempt = function(self: any, ctx: any, err: any) calls[#calls+1] = "read_after_attempt" end,
        modify_before_completion = function(self: any, ctx: any, err: any): any, any calls[#calls+1] = "modify_before_completion"; return (ctx as {string:any}).output, err end,
        read_after_execution = function(self: any, ctx: any, err: any) calls[#calls+1] = "read_after_execution" end,
    }
    local c = client_mod.new(make_config({i}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, err)
    assert.are.equal("ok", (result as {string:any}).Result)
    local expected: {string} = {
        "read_before_execution", "modify_before_serialization", "read_before_serialization",
        "read_after_serialization", "modify_before_retry_loop", "read_before_attempt",
        "modify_before_signing", "read_before_signing", "read_after_signing",
        "modify_before_transmit", "read_before_transmit", "read_after_transmit",
        "modify_before_deserialization", "read_before_deserialization", "read_after_deserialization",
        "modify_before_attempt_completion", "read_after_attempt", "modify_before_completion",
        "read_after_execution",
    }
    assert.are.equal(#expected, #calls)
    for idx, name in ipairs(expected) do
        assert.are.equal(name, calls[idx])
    end
end)

it("modify_before_serialization can change input", function()
    local i: {string:any} = {
        modify_before_serialization = function(self: any, ctx: any): any
            return { Name = "modified" }
        end,
    }
    local serialized_input: any
    local cfg = make_config({i})
    cfg["protocol"] = {
        serialize = function(self: any, input: any, svc: any, op: any): any, any
            serialized_input = input
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self: any, resp: any, svc: any, op: any): any, any return {}, nil end,
    }
    local c = client_mod.new(cfg)
    ;(c as any):invokeOperation(test_service, test_operation, { Name = "original" }):await()
    assert.are.equal("modified", (serialized_input as {string:any}).Name)
end)

it("modify_before_transmit can add headers", function()
    local i: {string:any} = {
        modify_before_transmit = function(self: any, ctx: any): any
            local req = (ctx as {string:any}).request as {string:any}
            ;(req["headers"] as {string:string})["X-Custom"] = "intercepted"
            return req
        end,
    }
    local transmitted_request: any
    local cfg = make_config({i})
    cfg["http_client"] = wrap_http(function(request: any): any, any
        transmitted_request = request
        return { status_code = 200, headers = {}, body = nil }, nil
    end)
    local c = client_mod.new(cfg)
    ;(c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal("intercepted", ((transmitted_request as {string:any}).headers as {string:string})["X-Custom"])
end)

it("read hook error jumps to modify_before_completion", function()
    local calls: {string} = {}
    local i: {string:any} = {
        read_before_execution = function(self: any, ctx: any)
            error("early failure")
        end,
        modify_before_completion = function(self: any, ctx: any, err: any): any, any
            calls[#calls+1] = "modify_before_completion"
            return nil, err
        end,
        read_after_execution = function(self: any, ctx: any, err: any)
            calls[#calls+1] = "read_after_execution"
        end,
    }
    local c = client_mod.new(make_config({i}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, result)
    assert.are.equal("string", type(err))
    assert_contains(calls, "modify_before_completion")
    assert_contains(calls, "read_after_execution")
end)

it("modify hook error jumps to modify_before_completion", function()
    local i: {string:any} = {
        modify_before_serialization = function(self: any, ctx: any): any
            error("modify failed")
        end,
        modify_before_completion = function(self: any, ctx: any, err: any): any, any
            return nil, "wrapped: " .. tostring(err)
        end,
        read_after_execution = function(self: any, ctx: any, err: any) end,
    }
    local c = client_mod.new(make_config({i}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, result)
    assert.are.equal("string", type(err))
end)

it("no interceptors: pipeline works unchanged", function()
    local c = client_mod.new(make_config(nil))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, err)
    assert.are.equal("ok", (result as {string:any}).Result)
end)

it("empty interceptors list: pipeline works unchanged", function()
    local c = client_mod.new(make_config({}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, err)
    assert.are.equal("ok", (result as {string:any}).Result)
end)

it("context has input and operation in read_before_execution", function()
    local seen_ctx: any
    local i: {string:any} = {
        read_before_execution = function(self: any, ctx: any)
            seen_ctx = ctx
        end,
    }
    local c = client_mod.new(make_config({i}))
    ;(c as any):invokeOperation(test_service, test_operation, { Foo = "bar" })
    assert.are.equal("bar", ((seen_ctx as {string:any}).input as {string:any}).Foo)
    assert.are.equal("TestOp", ((seen_ctx as {string:any}).operation as {string:any}).id)
end)

it("context has request after serialization", function()
    local seen_request: any
    local i: {string:any} = {
        read_after_serialization = function(self: any, ctx: any)
            seen_request = (ctx as {string:any}).request
        end,
    }
    local c = client_mod.new(make_config({i}))
    ;(c as any):invokeOperation(test_service, test_operation, {})
    assert.are.equal("table", type(seen_request))
    assert.are.equal("POST", (seen_request as {string:any}).method)
end)

it("context has response after transmit", function()
    local seen_response: any
    local i: {string:any} = {
        read_after_transmit = function(self: any, ctx: any)
            seen_response = (ctx as {string:any}).response
        end,
    }
    local c = client_mod.new(make_config({i}))
    ;(c as any):invokeOperation(test_service, test_operation, {})
    assert.are.equal(200, (seen_response as {string:any}).status_code)
end)

it("context has output after deserialization", function()
    local seen_output: any
    local i: {string:any} = {
        read_after_deserialization = function(self: any, ctx: any)
            seen_output = (ctx as {string:any}).output
        end,
    }
    local c = client_mod.new(make_config({i}))
    ;(c as any):invokeOperation(test_service, test_operation, {})
    assert.are.equal("ok", (seen_output as {string:any}).Result)
end)

it("modify_before_deserialization can swap response", function()
    local i: {string:any} = {
        modify_before_deserialization = function(self: any, ctx: any): any
            return { status_code = 200, headers = { ["x-test"] = "yes" }, body = nil }
        end,
    }
    local deserialized_response: any
    local cfg = make_config({i})
    cfg["protocol"] = {
        serialize = function(self: any, input: any, svc: any, op: any): any, any
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self: any, resp: any, svc: any, op: any): any, any
            deserialized_response = resp
            return { Modified = true }, nil
        end,
    }
    local c = client_mod.new(cfg)
    ;(c as any):invokeOperation(test_service, test_operation, {})
    assert.are.equal("yes", ((deserialized_response as {string:any}).headers as {string:string})["x-test"])
end)

it("modify_before_attempt_completion can replace output", function()
    local i: {string:any} = {
        modify_before_attempt_completion = function(self: any, ctx: any, err: any): any, any
            return { Replaced = true }, nil
        end,
    }
    local c = client_mod.new(make_config({i}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, err)
    assert.are.equal(true, (result as {string:any}).Replaced)
end)

it("modify_before_completion can replace output", function()
    local i: {string:any} = {
        modify_before_completion = function(self: any, ctx: any, err: any): any, any
            return { Final = "yes" }, nil
        end,
    }
    local c = client_mod.new(make_config({i}))
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}):await()
    assert.are.equal(nil, err)
    assert.are.equal("yes", (result as {string:any}).Final)
end)

it("interceptors added via per-call plugin", function()
    local calls: {string} = {}
    local i: {string:any} = {
        read_before_execution = function(self: any, ctx: any) calls[#calls+1] = "intercepted" end,
    }
    local cfg = make_config(nil)
    local c = client_mod.new(cfg)
    local result, err = (c as any):invokeOperation(test_service, test_operation, {}, {
        plugins = {
            function(cfg: {string:any}) cfg["interceptors"] = {i} end,
        },
    })
    assert.are.equal(nil, err)
    assert.are.equal("intercepted", calls[1])
end)

it("multiple interceptors: modify hooks chain", function()
    local i1: {string:any} = {
        modify_before_serialization = function(self: any, ctx: any): any
            local input = (ctx as {string:any}).input as {string:any}
            input["step1"] = true
            return input
        end,
    }
    local i2: {string:any} = {
        modify_before_serialization = function(self: any, ctx: any): any
            local input = (ctx as {string:any}).input as {string:any}
            input["step2"] = true
            return input
        end,
    }
    local serialized_input: any
    local cfg = make_config({i1, i2})
    cfg["protocol"] = {
        serialize = function(self: any, input: any, svc: any, op: any): any, any
            serialized_input = input
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self: any, resp: any, svc: any, op: any): any, any return {}, nil end,
    }
    local c = client_mod.new(cfg)
    ;(c as any):invokeOperation(test_service, test_operation, {})
    assert.are.equal(true, (serialized_input as {string:any})["step1"])
    assert.are.equal(true, (serialized_input as {string:any})["step2"])
end)

end)
