-- Test: runtime/client.lua pipeline wiring
-- Run: luajit test/test_client.lua

package.path = "runtime/?.lua;" .. package.path

local client_mod = require("client")

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

-- Mock protocol
local mock_protocol = {
    serialize = function(input, operation)
        record("serialize")
        return {
            method = operation.http_method,
            url = operation.http_path,
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(response, operation)
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
    return { url = "https://sts." .. params.region .. ".amazonaws.com" }, nil
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

local operation = {
    name = "GetCallerIdentity",
    input_schema = {},
    output_schema = {},
    http_method = "POST",
    http_path = "/",
}

-- === Tests ===

test("pipeline calls components in correct order", function()
    calls = {}
    local c = client_mod.new({
        service_id = "sts",
        protocol = mock_protocol,
        http_client = mock_http_client,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = mock_signer,
        signing_name = "sts",
        region = "us-east-1",
    })

    local output, err = c:invokeOperation({}, operation)
    assert(not err, "unexpected error: " .. tostring(err))
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
    local c = client_mod.new({
        service_id = "sts",
        protocol = mock_protocol,
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = function(req, _, _) return req, nil end,
        signing_name = "sts",
        region = "us-west-2",
    })

    c:invokeOperation({}, operation)
    assert_eq(captured_request.url, "https://sts.us-west-2.amazonaws.com/", "url")
end)

test("signer receives correct identity and props", function()
    calls = {}
    signer_args = {}
    local c = client_mod.new({
        service_id = "sts",
        protocol = mock_protocol,
        http_client = mock_http_client,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = mock_signer,
        signing_name = "sts",
        region = "eu-west-1",
    })

    c:invokeOperation({}, operation)
    assert_eq(signer_args.identity.access_key, "AKID", "access_key")
    assert_eq(signer_args.props.signing_name, "sts", "signing_name")
    assert_eq(signer_args.props.region, "eu-west-1", "region")
end)

test("operation plugins can override config", function()
    calls = {}
    local captured_request
    local c = client_mod.new({
        service_id = "sts",
        protocol = mock_protocol,
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = function(req, _, _) return req, nil end,
        signing_name = "sts",
        region = "us-east-1",
    })

    c:invokeOperation({}, operation, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert_eq(captured_request.url, "https://sts.ap-southeast-1.amazonaws.com/", "plugin override url")
end)

test("plugins do not mutate original client config", function()
    local c = client_mod.new({
        service_id = "sts",
        protocol = mock_protocol,
        http_client = mock_http_client,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = function(req, _, _) return req, nil end,
        signing_name = "sts",
        region = "us-east-1",
    })

    c:invokeOperation({}, operation, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert_eq(c.config.region, "us-east-1", "original config unchanged")
end)

test("serialize error short-circuits pipeline", function()
    calls = {}
    local c = client_mod.new({
        service_id = "sts",
        protocol = {
            serialize = function() return nil, { type = "sdk", message = "bad input" } end,
            deserialize = function() error("should not be called") end,
        },
        http_client = mock_http_client,
        endpoint_provider = mock_endpoint_provider,
        identity_resolver = mock_identity_resolver,
        signer = mock_signer,
        signing_name = "sts",
        region = "us-east-1",
    })

    local output, err = c:invokeOperation({}, operation)
    assert(output == nil, "output should be nil")
    assert_eq(err.message, "bad input", "error message")
    assert_eq(#calls, 0, "no further calls after serialize error")
end)

print("\nAll tests passed.")
