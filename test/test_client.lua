-- Test: runtime/client.lua pipeline wiring with SRA auth resolution

local client_mod = require("smithy.client")
local auth = require("smithy.auth")
local schema = require("smithy.schema")

-- Track call order across all mocks
local calls = {}
local function record(name) calls[#calls + 1] = name end

-- Mock protocol (methods accept self for colon-call from client.lua)
local mock_protocol = {
    serialize = function(self, input, service, operation)
        record("serialize")
        return {
            method = "POST",
            url = "/",
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(self, response, service, operation)
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
        auth_scheme_resolver = function(service, operation, input)
            return operation.auth_schemes
        end,
    }
    if overrides then
        for k, v in pairs(overrides) do cfg[k] = v end
    end
    return cfg
end

local service = schema.service({ id = "sts" })

local operation = schema.operation({ id = "GetCallerIdentity" })
operation.auth_schemes = {
    { scheme_id = "aws.auth#sigv4", signer_properties = { signing_name = "sts", signing_region = "us-east-1" } },
}

describe("client", function()

it("pipeline calls components in correct order", function()
    calls = {}
    local c = client_mod.new(make_auth_config())
    local output, err = c:invokeOperation(service, operation, {})
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert.are.equal("ok", output.Result)
    assert.are.equal(6, #calls)
    assert.are.equal("serialize", calls[1])
    assert.are.equal("identity", calls[2])
    assert.are.equal("endpoint", calls[3])
    assert.are.equal("sign", calls[4])
    assert.are.equal("transmit", calls[5])
    assert.are.equal("deserialize", calls[6])
end)

it("endpoint is applied to request URL", function()
    calls = {}
    local captured_request
    local c = client_mod.new(make_auth_config({
        region = "us-west-2",
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
    }))
    c:invokeOperation(service, operation, {})
    assert.are.equal("https://sts.us-west-2.amazonaws.com/", captured_request.url)
end)

it("signer receives correct identity and signer_properties", function()
    calls = {}
    signer_args = {}
    local c = client_mod.new(make_auth_config())
    c:invokeOperation(service, operation, {})
    assert.are.equal("AKID", signer_args.identity.access_key)
    assert.are.equal("sts", signer_args.props.signing_name)
    assert.are.equal("us-east-1", signer_args.props.signing_region)
end)

it("operation plugins can override config", function()
    calls = {}
    local captured_request
    local c = client_mod.new(make_auth_config({
        http_client = function(req)
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
    }))
    c:invokeOperation(service, operation, {}, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert.are.equal("https://sts.ap-southeast-1.amazonaws.com/", captured_request.url)
end)

it("plugins do not mutate original client config", function()
    local c = client_mod.new(make_auth_config())
    c:invokeOperation(service, operation, {}, {
        plugins = {
            function(cfg) cfg.region = "ap-southeast-1" end,
        },
    })
    assert.are.equal("us-east-1", c.config.region)
end)

it("serialize error short-circuits pipeline", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        protocol = {
            serialize = function(self) return nil, { type = "sdk", message = "bad input" } end,
            deserialize = function(self) error("should not be called") end,
        },
    }))
    local output, err = c:invokeOperation(service, operation, {})
    assert(output == nil, "output should be nil")
    assert.are.equal("bad input", err.message)
    assert.are.equal(0, #calls)
end)

it("noAuth scheme skips signing", function()
    calls = {}
    local noauth_op = schema.operation({ id = "AssumeRoleWithWebIdentity" })
    noauth_op.auth_schemes = {
        { scheme_id = "smithy.api#noAuth" },
    }
    local c = client_mod.new(make_auth_config())
    local output, err = c:invokeOperation(service, noauth_op, {})
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    local has_identity = false
    local has_sign = false
    for _, call in ipairs(calls) do
        if call == "identity" then has_identity = true end
        if call == "sign" then has_sign = true end
    end
    assert(not has_identity, "should not resolve identity for noAuth")
    assert(not has_sign, "should not sign for noAuth")
end)

it("endpoint authSchemes overrides signer properties", function()
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
    c:invokeOperation(service, operation, {})
    assert.are.equal("custom-service", signer_args.props.signing_name)
    assert.are.equal("us-west-2", signer_args.props.signing_region)
end)

it("no supported auth scheme returns error", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        auth_schemes = {},
    }))
    local output, err = c:invokeOperation(service, operation, {})
    assert(output == nil, "output should be nil")
    assert(err.message:find("no auth scheme"), "error should mention no auth scheme: " .. err.message)
end)

end)
