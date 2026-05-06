-- Test: runtime/smithy/interceptor.lua + client.lua interceptor integration
-- Run: luajit test/test_interceptor.lua

package.path = "runtime/?.lua;" .. package.path

local client_mod = require("smithy.client")
local auth = require("smithy.auth")
local schema = require("smithy.schema")

local pass_count = 0
local fail_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print("PASS: " .. name)
    else
        fail_count = fail_count + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function assert_contains(tbl, value, msg)
    for _, v in ipairs(tbl) do
        if v == value then return end
    end
    error((msg or "assert_contains") .. ": " .. tostring(value) .. " not found", 2)
end

-- Mock protocol
local mock_protocol = {
    serialize = function(self, input, service, operation)
        return {
            method = "POST",
            url = "/",
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(self, response, service, operation)
        return { Result = "ok" }, nil
    end,
}

-- Mock identity
local mock_identity = { access_key = "AKID", secret_key = "SECRET" }

-- Standard test config
local function make_config(interceptors)
    return {
        service_id = "test",
        protocol = mock_protocol,
        http_client = function(request)
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
        endpoint_provider = function(params)
            return { url = "https://test.us-east-1.amazonaws.com" }, nil
        end,
        region = "us-east-1",
        auth_schemes = {
            ["aws.auth#sigv4"] = {
                scheme_id = "aws.auth#sigv4",
                identity_type = "aws_credentials",
                signer = function(req, id, props) return req, nil end,
                identity_resolver = function(self, resolvers)
                    return resolvers[self.identity_type]
                end,
            },
        },
        identity_resolvers = {
            aws_credentials = function() return mock_identity, nil end,
        },
        auth_scheme_resolver = function(service, operation, input)
            return { { scheme_id = "aws.auth#sigv4", signer_properties = { signing_name = "test", signing_region = "us-east-1" } } }
        end,
        interceptors = interceptors,
    }
end

local test_service = schema.service({ id = "test" })
local test_operation = schema.operation({ id = "TestOp" })

-- ============================================================
-- Tests
-- ============================================================

test("read hooks are called in order", function()
    local calls = {}
    local i1 = { read_before_execution = function(self, ctx) calls[#calls+1] = "i1" end }
    local i2 = { read_before_execution = function(self, ctx) calls[#calls+1] = "i2" end }

    local c = client_mod.new(make_config({i1, i2}))
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(calls[1], "i1")
    assert_eq(calls[2], "i2")
end)

test("full hook execution order", function()
    local calls = {}
    local i = {
        read_before_execution = function(self, ctx) calls[#calls+1] = "read_before_execution" end,
        modify_before_serialization = function(self, ctx) calls[#calls+1] = "modify_before_serialization"; return ctx.input end,
        read_before_serialization = function(self, ctx) calls[#calls+1] = "read_before_serialization" end,
        read_after_serialization = function(self, ctx) calls[#calls+1] = "read_after_serialization" end,
        modify_before_retry_loop = function(self, ctx) calls[#calls+1] = "modify_before_retry_loop"; return ctx.request end,
        read_before_attempt = function(self, ctx) calls[#calls+1] = "read_before_attempt" end,
        modify_before_signing = function(self, ctx) calls[#calls+1] = "modify_before_signing"; return ctx.request end,
        read_before_signing = function(self, ctx) calls[#calls+1] = "read_before_signing" end,
        read_after_signing = function(self, ctx) calls[#calls+1] = "read_after_signing" end,
        modify_before_transmit = function(self, ctx) calls[#calls+1] = "modify_before_transmit"; return ctx.request end,
        read_before_transmit = function(self, ctx) calls[#calls+1] = "read_before_transmit" end,
        read_after_transmit = function(self, ctx) calls[#calls+1] = "read_after_transmit" end,
        modify_before_deserialization = function(self, ctx) calls[#calls+1] = "modify_before_deserialization"; return ctx.response end,
        read_before_deserialization = function(self, ctx) calls[#calls+1] = "read_before_deserialization" end,
        read_after_deserialization = function(self, ctx) calls[#calls+1] = "read_after_deserialization" end,
        modify_before_attempt_completion = function(self, ctx, err) calls[#calls+1] = "modify_before_attempt_completion"; return ctx.output, err end,
        read_after_attempt = function(self, ctx, err) calls[#calls+1] = "read_after_attempt" end,
        modify_before_completion = function(self, ctx, err) calls[#calls+1] = "modify_before_completion"; return ctx.output, err end,
        read_after_execution = function(self, ctx, err) calls[#calls+1] = "read_after_execution" end,
    }

    local c = client_mod.new(make_config({i}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(err, nil, "no error")
    assert_eq(result.Result, "ok")

    local expected = {
        "read_before_execution",
        "modify_before_serialization",
        "read_before_serialization",
        "read_after_serialization",
        "modify_before_retry_loop",
        "read_before_attempt",
        "modify_before_signing",
        "read_before_signing",
        "read_after_signing",
        "modify_before_transmit",
        "read_before_transmit",
        "read_after_transmit",
        "modify_before_deserialization",
        "read_before_deserialization",
        "read_after_deserialization",
        "modify_before_attempt_completion",
        "read_after_attempt",
        "modify_before_completion",
        "read_after_execution",
    }
    assert_eq(#calls, #expected, "hook count")
    for idx, name in ipairs(expected) do
        assert_eq(calls[idx], name, "hook order at " .. idx)
    end
end)

test("modify_before_serialization can change input", function()
    local i = {
        modify_before_serialization = function(self, ctx)
            return { Name = "modified" }
        end,
    }

    local serialized_input
    local cfg = make_config({i})
    cfg.protocol = {
        serialize = function(self, input, svc, op)
            serialized_input = input
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self, resp, svc, op) return {}, nil end,
    }

    local c = client_mod.new(cfg)
    c:invokeOperation(test_service, test_operation, { Name = "original" })

    assert_eq(serialized_input.Name, "modified")
end)

test("modify_before_transmit can add headers", function()
    local i = {
        modify_before_transmit = function(self, ctx)
            local req = ctx.request
            req.headers["X-Custom"] = "intercepted"
            return req
        end,
    }

    local transmitted_request
    local cfg = make_config({i})
    cfg.http_client = function(request)
        transmitted_request = request
        return { status_code = 200, headers = {}, body = nil }, nil
    end

    local c = client_mod.new(cfg)
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(transmitted_request.headers["X-Custom"], "intercepted")
end)

test("read hook error jumps to modify_before_completion", function()
    local calls = {}
    local i = {
        read_before_execution = function(self, ctx)
            error("early failure")
        end,
        modify_before_completion = function(self, ctx, err)
            calls[#calls+1] = "modify_before_completion"
            return nil, err
        end,
        read_after_execution = function(self, ctx, err)
            calls[#calls+1] = "read_after_execution"
        end,
    }

    local c = client_mod.new(make_config({i}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(result, nil)
    -- err should be the error string from the hook
    assert_eq(type(err), "string")
    assert_contains(calls, "modify_before_completion")
    assert_contains(calls, "read_after_execution")
end)

test("modify hook error jumps to modify_before_completion", function()
    local i = {
        modify_before_serialization = function(self, ctx)
            error("modify failed")
        end,
        modify_before_completion = function(self, ctx, err)
            return nil, "wrapped: " .. tostring(err)
        end,
        read_after_execution = function(self, ctx, err) end,
    }

    local c = client_mod.new(make_config({i}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(result, nil)
    assert_eq(type(err), "string")
end)

test("no interceptors: pipeline works unchanged", function()
    local c = client_mod.new(make_config(nil))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(err, nil)
    assert_eq(result.Result, "ok")
end)

test("empty interceptors list: pipeline works unchanged", function()
    local c = client_mod.new(make_config({}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(err, nil)
    assert_eq(result.Result, "ok")
end)

test("context has input and operation in read_before_execution", function()
    local seen_ctx
    local i = {
        read_before_execution = function(self, ctx)
            seen_ctx = ctx
        end,
    }

    local c = client_mod.new(make_config({i}))
    c:invokeOperation(test_service, test_operation, { Foo = "bar" })

    assert_eq(seen_ctx.input.Foo, "bar")
    assert_eq(seen_ctx.operation.id, "TestOp")
end)

test("context has request after serialization", function()
    local seen_request
    local i = {
        read_after_serialization = function(self, ctx)
            seen_request = ctx.request
        end,
    }

    local c = client_mod.new(make_config({i}))
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(type(seen_request), "table")
    assert_eq(seen_request.method, "POST")
end)

test("context has response after transmit", function()
    local seen_response
    local i = {
        read_after_transmit = function(self, ctx)
            seen_response = ctx.response
        end,
    }

    local c = client_mod.new(make_config({i}))
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(seen_response.status_code, 200)
end)

test("context has output after deserialization", function()
    local seen_output
    local i = {
        read_after_deserialization = function(self, ctx)
            seen_output = ctx.output
        end,
    }

    local c = client_mod.new(make_config({i}))
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(seen_output.Result, "ok")
end)

test("modify_before_deserialization can swap response", function()
    local i = {
        modify_before_deserialization = function(self, ctx)
            return { status_code = 200, headers = { ["x-test"] = "yes" }, body = nil }
        end,
    }

    local deserialized_response
    local cfg = make_config({i})
    cfg.protocol = {
        serialize = function(self, input, svc, op)
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self, resp, svc, op)
            deserialized_response = resp
            return { Modified = true }, nil
        end,
    }

    local c = client_mod.new(cfg)
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(deserialized_response.headers["x-test"], "yes")
end)

test("modify_before_attempt_completion can replace output", function()
    local i = {
        modify_before_attempt_completion = function(self, ctx, err)
            return { Replaced = true }, nil
        end,
    }

    local c = client_mod.new(make_config({i}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(err, nil)
    assert_eq(result.Replaced, true)
end)

test("modify_before_completion can replace output", function()
    local i = {
        modify_before_completion = function(self, ctx, err)
            return { Final = "yes" }, nil
        end,
    }

    local c = client_mod.new(make_config({i}))
    local result, err = c:invokeOperation(test_service, test_operation, {})

    assert_eq(err, nil)
    assert_eq(result.Final, "yes")
end)

test("interceptors added via per-call plugin", function()
    local calls = {}
    local i = {
        read_before_execution = function(self, ctx) calls[#calls+1] = "intercepted" end,
    }

    local cfg = make_config(nil) -- no interceptors on base config
    local c = client_mod.new(cfg)
    local result, err = c:invokeOperation(test_service, test_operation, {}, {
        plugins = {
            function(cfg) cfg.interceptors = {i} end,
        },
    })

    assert_eq(err, nil)
    assert_eq(calls[1], "intercepted")
end)

test("multiple interceptors: modify hooks chain", function()
    local i1 = {
        modify_before_serialization = function(self, ctx)
            local input = ctx.input
            input.step1 = true
            return input
        end,
    }
    local i2 = {
        modify_before_serialization = function(self, ctx)
            local input = ctx.input
            input.step2 = true
            return input
        end,
    }

    local serialized_input
    local cfg = make_config({i1, i2})
    cfg.protocol = {
        serialize = function(self, input, svc, op)
            serialized_input = input
            return { method = "POST", url = "/", headers = {}, body = nil }, nil
        end,
        deserialize = function(self, resp, svc, op) return {}, nil end,
    }

    local c = client_mod.new(cfg)
    c:invokeOperation(test_service, test_operation, {})

    assert_eq(serialized_input.step1, true)
    assert_eq(serialized_input.step2, true)
end)

-- Summary
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
