-- Test: runtime/retry.lua + runtime/retry/standard.lua + client.lua retry loop
-- Run: luajit test/test_retry.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local retry = require("smithy.retry")
local standard = require("smithy.retry.standard")
local error_mod = require("smithy.error")
local client_mod = require("smithy.client")
local schema = require("smithy.schema")

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

-- === retry.none() tests ===

test("none: acquire_token returns token", function()
    local r = retry.none()
    local token, err = r:acquire_token()
    assert(token, "should return token")
    assert(not err, "no error")
end)

test("none: retry_token always returns nil + error", function()
    local r = retry.none()
    local token = r:acquire_token()
    local the_err = { code = "Throttling" }
    local delay, err = r:retry_token(token, the_err)
    assert(delay == nil, "no delay")
    assert_eq(err.code, "Throttling", "passes through error")
end)

-- === standard retry tests ===

test("standard: defaults", function()
    local r = standard.new()
    assert_eq(r:available_capacity(), 500, "initial capacity")
end)

test("standard: retries transient error", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay, "should return delay, got: " .. tostring(retry_err))
    assert(delay >= 0, "delay non-negative")
    assert_eq(r:available_capacity(), 495, "capacity reduced by 5")
end)

test("standard: retries throttle error", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("Throttling", "slow down", 429)
    local delay = r:retry_token(token, err)
    assert(delay, "should retry throttle")
    assert_eq(r:available_capacity(), 495, "capacity reduced by 5")
end)

test("standard: timeout costs 10 tokens", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = { code = "RequestTimeout" }
    local delay = r:retry_token(token, err)
    assert(delay, "should retry timeout")
    assert_eq(r:available_capacity(), 490, "capacity reduced by 10")
end)

test("standard: non-retryable error returns nil", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("ValidationError", "bad", 400)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay == nil, "should not retry")
    assert_eq(retry_err.code, "ValidationError", "passes through error")
end)

test("standard: max attempts exhausted", function()
    local r = standard.new({ max_attempts = 2 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    -- First retry (attempt becomes 1, max is 2 so 1 < 2 → ok)
    local delay = r:retry_token(token, err)
    assert(delay, "first retry should succeed")
    -- Second retry (attempt becomes 2, 2 >= 2 → exhausted)
    delay = r:retry_token(token, err)
    assert(delay == nil, "should be exhausted")
end)

test("standard: record_success restores cost", function()
    local r = standard.new()
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    r:retry_token(token, err) -- costs 5
    assert_eq(r:available_capacity(), 495)
    r:record_success(token) -- restores 5
    assert_eq(r:available_capacity(), 500)
end)

test("standard: first-attempt success adds increment", function()
    local r = standard.new()
    local token = r:acquire_token()
    -- Drain some capacity first
    local token2 = r:acquire_token()
    r:retry_token(token2, error_mod.new_api_error("X", "x", 500))
    assert_eq(r:available_capacity(), 495)
    -- Now record success on first-attempt token (no cost set)
    r:record_success(token)
    assert_eq(r:available_capacity(), 496, "adds 1 increment")
end)

test("standard: capacity cannot exceed max", function()
    local r = standard.new()
    local token = r:acquire_token()
    r:record_success(token)
    assert_eq(r:available_capacity(), 500, "capped at max")
end)

test("standard: bucket exhaustion prevents retry", function()
    local r = standard.new({ rate_tokens = 3, retry_cost = 5 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay, retry_err = r:retry_token(token, err)
    assert(delay == nil, "insufficient tokens")
    assert(retry_err, "should return error")
end)

test("standard: backoff delay within expected range", function()
    local r = standard.new({ max_backoff = 20 })
    local token = r:acquire_token()
    local err = error_mod.new_api_error("InternalError", "fail", 500)
    local delay = r:retry_token(token, err)
    -- attempt=1: rand() * 2^1 = rand() * 2, so delay in [0, 2)
    assert(delay >= 0, "delay >= 0")
    assert(delay < 2, "delay < 2 for first retry, got " .. tostring(delay))
end)

-- === Client retry integration tests ===

local test_service = schema.service({ id = "test" })
local test_op = schema.operation({ id = "Op" })
test_op.auth_schemes = { { scheme_id = "aws.auth#sigv4", signer_properties = {} } }

local test_op_with_path = schema.operation({ id = "Op" })
test_op_with_path.auth_schemes = { { scheme_id = "aws.auth#sigv4", signer_properties = {} } }

test("client: no retry_strategy = single attempt (backward compat)", function()
    local attempt_count = 0
    local c = client_mod.new({
        protocol = {
            serialize = function(self, input, svc, op)
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self)
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("InternalError", "fail", 500)
            end,
        },
        http_client = function() return { status_code = 500, headers = {} } end,
        endpoint_provider = function() return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req) return req end, identity_resolver = function(self, ir) return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function() return {} end },
        auth_scheme_resolver = function(svc, op, input) return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {})
    assert_eq(attempt_count, 1, "single attempt")
    assert_eq(err.code, "InternalError")
end)

test("client: retry loop retries transient errors", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self, input, svc, op)
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self)
                attempt_count = attempt_count + 1
                if attempt_count < 3 then
                    return nil, error_mod.new_api_error("InternalError", "fail", 500)
                end
                return { Result = "ok" }
            end,
        },
        http_client = function() return { status_code = 200, headers = {} } end,
        endpoint_provider = function() return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req) return req end, identity_resolver = function(self, ir) return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function() return {} end },
        auth_scheme_resolver = function(svc, op, input) return op.auth_schemes end,
        region = "us-east-1",
    })
    local output, err = c:invokeOperation(test_service, test_op, {})
    assert(not err, "should succeed: " .. tostring(err and err.message))
    assert_eq(output.Result, "ok")
    assert_eq(attempt_count, 3, "3 attempts")
end)

test("client: retry loop stops on non-retryable error", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self, input, svc, op)
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self)
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("ValidationError", "bad", 400)
            end,
        },
        http_client = function() return { status_code = 400, headers = {} } end,
        endpoint_provider = function() return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req) return req end, identity_resolver = function(self, ir) return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function() return {} end },
        auth_scheme_resolver = function(svc, op, input) return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {})
    assert_eq(attempt_count, 1, "only 1 attempt for non-retryable")
    assert_eq(err.code, "ValidationError")
end)

test("client: retry loop stops at max attempts", function()
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 2 }),
        protocol = {
            serialize = function(self, input, svc, op)
                return { method = "POST", url = "/", headers = {} }
            end,
            deserialize = function(self)
                attempt_count = attempt_count + 1
                return nil, error_mod.new_api_error("InternalError", "fail", 500)
            end,
        },
        http_client = function() return { status_code = 500, headers = {} } end,
        endpoint_provider = function() return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req) return req end, identity_resolver = function(self, ir) return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function() return {} end },
        auth_scheme_resolver = function(svc, op, input) return op.auth_schemes end,
        region = "us-east-1",
    })
    local _, err = c:invokeOperation(test_service, test_op, {})
    assert_eq(attempt_count, 2, "max 2 attempts")
    assert_eq(err.code, "InternalError")
end)

test("client: URL rebuilt on each retry attempt", function()
    local urls = {}
    local attempt_count = 0
    local c = client_mod.new({
        retry_strategy = standard.new({ max_attempts = 3 }),
        protocol = {
            serialize = function(self, input, svc, op)
                return { method = "POST", url = "/test", headers = {} }
            end,
            deserialize = function(self)
                attempt_count = attempt_count + 1
                if attempt_count < 2 then
                    return nil, error_mod.new_api_error("InternalError", "fail", 500)
                end
                return { Result = "ok" }
            end,
        },
        http_client = function(req)
            urls[#urls + 1] = req.url
            return { status_code = 200, headers = {} }
        end,
        endpoint_provider = function() return { url = "https://example.com" } end,
        auth_schemes = { ["aws.auth#sigv4"] = { scheme_id = "aws.auth#sigv4", identity_type = "aws_credentials", signer = function(req) return req end, identity_resolver = function(self, ir) return ir.aws_credentials end } },
        identity_resolvers = { aws_credentials = function() return {} end },
        auth_scheme_resolver = function(svc, op, input) return op.auth_schemes end,
        region = "us-east-1",
    })
    c:invokeOperation(test_service, test_op_with_path, {})
    -- Both attempts should have the correct full URL
    assert_eq(urls[1], "https://example.com/test", "attempt 1 URL")
    assert_eq(urls[2], "https://example.com/test", "attempt 2 URL")
end)

print("\nAll tests passed.")
