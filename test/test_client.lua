-- Test: runtime/client.lua pipeline wiring with SRA auth resolution
-- Run: luajit test/test_client.lua

package.path = "runtime/?.lua;" .. package.path

local client_mod = require("smithy.client")
local auth = require("smithy.auth")

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

-- Track call order across all mocks
local calls = {}
local function record(name) calls[#calls + 1] = name end

-- Mock protocol (methods accept self for colon-call from client.lua)
local mock_protocol = {
    serialize = function(self, input, operation)
        record("serialize")
        return {
            method = operation.http_method,
            url = operation.http_path,
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(self, response, operation)
        record("deserialize")
        return { Result = "ok" }, nil
    end,
}

-- Mock identity resolver
local mock_identity = { access_key = "AKID", secret_key = "SECRET" }
local function mock_identity_resolver()
    record("identity")
    return mock_identity, nil
end

-- Mock endpoint provider
local function mock_endpoint_provider(params)
    record("endpoint")
    return { url = "https://sts." .. params.Region .. ".amazonaws.com" }, nil
end

-- Mock signer: records what it received, returns request unchanged
local signer_args = {}
local function mock_signer(request, identity, props)
    record("sign")
    signer_args.identity = identity
    signer_args.props = props
    return request, nil
end

-- Mock HTTP client
local function mock_http_client(request)
    record("transmit")
    return { status_code = 200, headers = {}, body = nil }, nil
end

-- Standard auth config for tests
local function make_auth_config(overrides)
    local cfg = {
        service_id = "sts",
        protocol = mock_protocol,
        http_client = mock_http_client,
        endpoint_provider = mock_endpoint_provider,
        region = "us-east-1",
        auth_schemes = {
            [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", mock_signer),
        },
        identity_resolvers = {
            aws_credentials = mock_identity_resolver,
        },
        auth_scheme_resolver = function(operation)
            return operation.auth_schemes
        end,
    }
    if overrides then
        for k, v in pairs(overrides) do cfg[k] = v end
    end
    return cfg
end

local operation = {
    name = "GetCallerIdentity",
    input_schema = {},
    output_schema = {},
    http_method = "POST",
    http_path = "/",
    effective_auth_schemes = { "aws.auth#sigv4" },
    auth_schemes = {
        { scheme_id = "aws.auth#sigv4", signer_properties = { signing_name = "sts", signing_region = "us-east-1" } },
    },
}

-- === Tests ===

test("pipeline calls components in correct order", function()
    calls = {}
    local c = client_mod.new(make_auth_config())
    local output, err = c:invokeOperation({}, operation)
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.Result, "ok", "output")

    -- Verify order: serialize -> identity -> endpoint -> sign -> transmit -> deserialize
    assert_eq(#calls, 6, "call count")
    assert_eq(calls[1], "serialize", "step 1")
    assert_eq(calls[2], "identity", "step 2")
    assert_eq(calls[3], "endpoint", "step 3")
    assert_eq(calls[4], "sign", "step 4")
    assert_eq(calls[5], "transmit", "step 5")
    assert_eq(calls[6], "deserialize", "step 6")
end)

test("endpoint is applied to request URL", function()
    calls = {}
    local captured_request
    local c = client_mod.new(make_auth_config({
        region = "us-west-2",
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
    }))

    c:invokeOperation({}, operation)
    assert_eq(captured_request.url, "https://sts.us-west-2.amazonaws.com/", "url")
end)

test("signer receives correct identity and signer_properties", function()
    calls = {}
    signer_args = {}
    local c = client_mod.new(make_auth_config())
    c:invokeOperation({}, operation)
    assert_eq(signer_args.identity.access_key, "AKID", "access_key")
    assert_eq(signer_args.props.signing_name, "sts", "signing_name")
    assert_eq(signer_args.props.signing_region, "us-east-1", "signing_region")
end)

test("operation plugins can override config", function()
    calls = {}
    local captured_request
    local c = client_mod.new(make_auth_config({
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
    }))

    c:invokeOperation({}, operation, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert_eq(captured_request.url, "https://sts.ap-southeast-1.amazonaws.com/", "plugin override url")
end)

test("plugins do not mutate original client config", function()
    local c = client_mod.new(make_auth_config())
    c:invokeOperation({}, operation, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert_eq(c.config.region, "us-east-1", "original config unchanged")
end)

test("serialize error short-circuits pipeline", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        protocol = {
            serialize = function(self) return nil, { type = "sdk", message = "bad input" } end,
            deserialize = function(self) error("should not be called") end,
        },
    }))

    local output, err = c:invokeOperation({}, operation)
    assert(output == nil, "output should be nil")
    assert_eq(err.message, "bad input", "error message")
    assert_eq(#calls, 0, "no further calls after serialize error")
end)

test("noAuth scheme skips signing", function()
    calls = {}
    local noauth_op = {
        name = "AssumeRoleWithWebIdentity",
        input_schema = {},
        output_schema = {},
        http_method = "POST",
        http_path = "/",
        effective_auth_schemes = { "smithy.api#noAuth" },
        auth_schemes = {
            { scheme_id = "smithy.api#noAuth" },
        },
    }
    local c = client_mod.new(make_auth_config())
    local output, err = c:invokeOperation({}, noauth_op)
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    -- Should not call identity resolver or signer
    local has_identity = false
    local has_sign = false
    for _, call in ipairs(calls) do
        if call == "identity" then has_identity = true end
        if call == "sign" then has_sign = true end
    end
    assert(not has_identity, "should not resolve identity for noAuth")
    assert(not has_sign, "should not sign for noAuth")
end)

test("endpoint authSchemes overrides signer properties", function()
    calls = {}
    signer_args = {}
    local c = client_mod.new(make_auth_config({
        endpoint_provider = function(params)
            return {
                url = "https://custom.endpoint.com",
                properties = {
                    authSchemes = {
                        { name = "sigv4", signingName = "custom-service", signingRegion = "us-west-2" },
                    },
                },
            }, nil
        end,
    }))

    c:invokeOperation({}, operation)
    assert_eq(signer_args.props.signing_name, "custom-service", "overridden signing_name")
    assert_eq(signer_args.props.signing_region, "us-west-2", "overridden signing_region")
end)

test("no supported auth scheme returns error", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        auth_schemes = {}, -- no schemes supported
    }))

    local output, err = c:invokeOperation({}, operation)
    assert(output == nil, "output should be nil")
    assert(err.message:find("no auth scheme"), "error should mention no auth scheme: " .. err.message)
end)

print("\nAll tests passed.")
