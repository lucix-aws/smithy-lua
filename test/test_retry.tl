local assert = require("luassert") as any
-- Test: runtime/retry.lua + runtime/retry/standard.lua + client.lua retry loop

local async = require("smithy.async")
local retry = require("smithy.retry")
local standard = require("smithy.retry.standard")
local error_mod = require("smithy.error")
local client_mod = require("smithy.client")
local schema = require("smithy.schema")

local function wrap_http(fn: function({string:any}): {string:any}, any): {string:any}
    return { roundtrip = function(_: any, req: {string:any}): any
        local op = async.new_operation()
        op:resolve(fn(req))
        return op
    end }
end

describe("retry", function()

it("none: acquire_token returns token", function()
    local r = retry.none()
    local token, err = r:acquire_token()
    assert(token, "should return token")
    assert(not err, "no error")
end)

it("none: retry_token always returns nil + error", function()
    local r = retry.none()
    local token = r:acquire_token()
    local the_err = { code = "Throttling" }
    local delay, err = r:retry_token(token, the_err)
    assert(delay == nil, "no delay")
    assert.are.equal("Throttling", (err as {string:string}).code)
end)

it("standard: defaults", function()
    local r = standard.new()
    assert.are.equal(500, r:available_capacity())
end)

it("standard: retries transient error", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay, "should return delay, got: " .. tostring(retry_err))
    assert(delay >= 0, "delay non-negative")
    assert.are.equal(495, r:available_capacity())
end)

it("standard: retries throttle error", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("Throttling", "slow down", 429)
    local delay = r:retry_token(token, err)
    assert(delay, "should retry throttle")
    assert.are.equal(495, r:available_capacity())
end)

it("standard: timeout costs 10 tokens", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = { code = "RequestTimeout" }
    local delay = r:retry_token(token, err)
    assert(delay, "should retry timeout")
    assert.are.equal(490, r:available_capacity())
end)

it("standard: non-retryable error returns nil", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("ValidationError", "bad", 400)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay == nil, "should not retry")
    assert.are.equal("ValidationError", (retry_err as {string:string}).code)
end)

it("standard: max attempts exhausted", function()
    local r = standard.new({ max_attempts = 2 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay = r:retry_token(token, err)
    assert(delay, "first retry should succeed")
    delay = r:retry_token(token, err)
    assert(delay == nil, "should be exhausted")
end)

it("standard: record_success restores cost", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    r:retry_token(token, err)
    assert.are.equal(495, r:available_capacity())
    r:record_success(token)
    assert.are.equal(500, r:available_capacity())
end)

it("standard: first-attempt success adds increment", function()
    local r = standard.new()
    local token = r:acquire_token()
    local token2 = r:acquire_token()
    r:retry_token(token2, error_mod.new_api_error("X", "x", 500))
    assert.are.equal(495, r:available_capacity())
    r:record_success(token)
    assert.are.equal(496, r:available_capacity())
end)

it("standard: capacity cannot exceed max", function()
    local r = standard.new()
    local token = r:acquire_token()
    r:record_success(token)
    assert.are.equal(500, r:available_capacity())
end)

it("standard: bucket exhaustion prevents retry", function()
    local r = standard.new({ rate_tokens = 3, retry_cost = 5 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay == nil, "insufficient tokens")
    assert(retry_err, "should return error")
end)

it("standard: backoff delay within expected range", function()
    local r = standard.new({ max_backoff = 20 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay = r:retry_token(token, err)
    assert(delay >= 0, "delay >= 0")
    assert(delay < 2, "delay < 2 for first retry, got " .. tostring(delay))
end)

-- Client retry integration tests

local test_service = schema.service({ id = "test" })
local test_op = schema.operation({ id = "Op" })
test_op.auth_schemes = { { scheme_id = "aws.auth#sigv4", signer_properties = {} } }

local test_op_with_path = schema.operation({ id = "Op" })
test_op_with_path.auth_schemes = { { scheme_id = "aws.auth#sigv4", signer_properties = {} } }

it("client: no retry_strategy = single attempt (backward compat)", function()
    local attempt_count = 0
    local c = client_mod.new({
        protocol = {
            serialize = function(self: any, input: any, svc: any, op: any): {string:any}
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self: any): any, any
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("InternalError", "fail", 500)
            end,
        },
        http_client = wrap_http(function(_: {string:any}): {string:any}, any return { status_code = 500, headers = {} }, nil end),
        endpoint_provider = function(): {string:string} return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req: any): any return req end, identity_resolver = function(self: any, ir: any): any return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function(): {string:any} return {} end },
        auth_scheme_resolver = function(svc: any, op: any, input: any): {any} return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {}):await()
    assert.are.equal(1, attempt_count)
    assert.are.equal("InternalError", (err as {string:string}).code)
end)

it("client: retry loop retries transient errors", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self: any, input: any, svc: any, op: any): {string:any}
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self: any): any, any
                attempt_count = attempt_count + 1
                if attempt_count < 3 then
                    return nil, error_mod.new_api_error("InternalError", "fail", 500)
                end
                return { Result = "ok" }
            end,
        },
        http_client = wrap_http(function(_: {string:any}): {string:any}, any return { status_code = 200, headers = {} }, nil end),
        endpoint_provider = function(): {string:string} return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req: any): any return req end, identity_resolver = function(self: any, ir: any): any return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function(): {string:any} return {} end },
        auth_scheme_resolver = function(svc: any, op: any, input: any): {any} return op.auth_schemes end,
        region = "us-east-1",
    })
    local output, err = c:invokeOperation(test_service, test_op, {}):await()
    assert(not err, "should succeed: " .. tostring(err and (err as {string:string}).message))
    assert.are.equal("ok", (output as {string:string}).Result)
    assert.are.equal(3, attempt_count)
end)

it("client: retry loop stops on non-retryable error", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self: any, input: any, svc: any, op: any): {string:any}
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self: any): any, any
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("ValidationError", "bad", 400)
            end,
        },
        http_client = wrap_http(function(_: {string:any}): {string:any}, any return { status_code = 400, headers = {} }, nil end),
        endpoint_provider = function(): {string:string} return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req: any): any return req end, identity_resolver = function(self: any, ir: any): any return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function(): {string:any} return {} end },
        auth_scheme_resolver = function(svc: any, op: any, input: any): {any} return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {}):await()
    assert.are.equal(1, attempt_count)
    assert.are.equal("ValidationError", (err as {string:string}).code)
end)

it("client: retry loop stops at max attempts", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 2 }),
        protocol = {
            serialize = function(self: any, input: any, svc: any, op: any): {string:any}
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self: any): any, any
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("InternalError", "fail", 500)
            end,
        },
        http_client = wrap_http(function(_: {string:any}): {string:any}, any return { status_code = 500, headers = {} }, nil end),
        endpoint_provider = function(): {string:string} return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req: any): any return req end, identity_resolver = function(self: any, ir: any): any return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function(): {string:any} return {} end },
        auth_scheme_resolver = function(svc: any, op: any, input: any): {any} return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {}):await()
    assert.are.equal(2, attempt_count)
    assert.are.equal("InternalError", (err as {string:string}).code)
end)

it("client: URL rebuilt on each retry attempt", function()
    local urls: {string} = {}
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self: any, input: any, svc: any, op: any): {string:any}
                return { method = "POST", url = "/test", headers = {} }
            end,
            deserialize = function(self: any): any, any
                attempt_count = attempt_count + 1
                if attempt_count < 2 then
                    return nil, error_mod.new_api_error("InternalError", "fail", 500)
                end
                return { Result = "ok" }
            end,
        },
        http_client = wrap_http(function(req: {string:any}): {string:any}, any
            urls[#urls + 1] = req.url as string
            return { status_code = 200, headers = {} }, nil
        end),
        endpoint_provider = function(): {string:string} return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req: any): any return req end, identity_resolver = function(self: any, ir: any): any return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function(): {string:any} return {} end },
        auth_scheme_resolver = function(svc: any, op: any, input: any): {any} return op.auth_schemes end,
        region = "us-east-1",
    })
    c:invokeOperation(test_service, test_op_with_path, {}):await()
    assert.are.equal("https://example.com/test", urls[1])
    assert.are.equal("https://example.com/test", urls[2])
end)

end)
