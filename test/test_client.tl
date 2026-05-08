local assert = require("luassert") as any
-- Test: runtime/client.lua pipeline wiring with SRA auth resolution

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

-- Track call order across all mocks
local calls: {string} = {}
local function record(name: string) calls[#calls + 1] = name end

-- Mock protocol (methods accept self for colon-call from client.lua)
local mock_protocol: {string:any} = {
    serialize = function(self: any, input: any, service: any, operation: any): any, any
        record("serialize")
        return {
            method = "POST",
            url = "/",
            headers = { ["Content-Type"] = "application/json" },
            body = nil,
        }, nil
    end,
    deserialize = function(self: any, response: any, service: any, operation: any): any, any
        record("deserialize")
        return { Result = "ok" }, nil
    end,
}

-- Mock identity resolver
local mock_identity: {string:string} = { access_key = "AKID", secret_key = "SECRET" }
local function mock_identity_resolver(): any, any
    record("identity")
    return mock_identity, nil
end

-- Mock endpoint provider
local function mock_endpoint_provider(params: {string:any}): any, any
    record("endpoint")
    return { url = "https://sts." .. (params["Region"] as string) .. ".amazonaws.com" }, nil
end

-- Mock signer: records what it received, returns request unchanged
local signer_args: {string:any} = {}
local function mock_signer(request: any, identity: any, props: {string:any}): any, any
    record("sign")
    signer_args["identity"] = identity
    signer_args["props"] = props
    return request, nil
end

-- Mock HTTP client
local function mock_http_client(request: any): any, any
    record("transmit")
    return { status_code = 200, headers = {}, body = nil }, nil
end

-- Standard auth config for tests
local function make_auth_config(overrides: {string:any}): {string:any}
    local cfg: {string:any} = {
        service_id = "sts",
        protocol = mock_protocol,
        http_client = wrap_http(mock_http_client),
        endpoint_provider = mock_endpoint_provider,
        region = "us-east-1",
        auth_schemes = {
            [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", mock_signer),
        },
        identity_resolvers = {
            aws_credentials = mock_identity_resolver,
        },
        auth_scheme_resolver = function(service: any, operation: any, input: any): any
            return (operation as {string:any}).auth_schemes
        end,
    }
    if overrides then
        for k, v in pairs(overrides) do cfg[k] = v end
    end
    return cfg
end

local service = schema.service({ id = "sts" } as any)

local operation = schema.operation({ id = "GetCallerIdentity" } as any)
;(operation as {string:any}).auth_schemes = {
    { scheme_id = "aws.auth#sigv4", signer_properties = { signing_name = "sts", signing_region = "us-east-1" } },
}

describe("client", function()

it("pipeline calls components in correct order", function()
    calls = {}
    local c = client_mod.new(make_auth_config())
    local output, err = (c as any):invokeOperation(service, operation, {}):await()
    assert(not err, "unexpected error: " .. tostring(err and (err as {string:any}).message))
    assert.are.equal("ok", (output as {string:any}).Result)
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
    local captured_request: any
    local c = client_mod.new(make_auth_config({
        region = "us-west-2",
        http_client = wrap_http(function(req: any): any, any
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end),
    } as {string:any}))
    ;(c as any):invokeOperation(service, operation, {}):await()
    assert.are.equal("https://sts.us-west-2.amazonaws.com/", (captured_request as {string:any}).url)
end)

it("signer receives correct identity and signer_properties", function()
    calls = {}
    signer_args = {}
    local c = client_mod.new(make_auth_config())
    ;(c as any):invokeOperation(service, operation, {}):await()
    assert.are.equal("AKID", (signer_args["identity"] as {string:any}).access_key)
    assert.are.equal("sts", (signer_args["props"] as {string:any}).signing_name)
    assert.are.equal("us-east-1", (signer_args["props"] as {string:any}).signing_region)
end)

it("operation plugins can override config", function()
    calls = {}
    local captured_request: any
    local c = client_mod.new(make_auth_config({
        http_client = wrap_http(function(req: any): any, any
            captured_request = req
            return { status_code = 200, headers = {}, body = nil }, nil
        end),
    } as {string:any}))
    ;(c as any):invokeOperation(service, operation, {}, {
        plugins = {
            function(cfg: {string:any}) cfg["region"] = "ap-southeast-1" end,
        },
    }):await()
    assert.are.equal("https://sts.ap-southeast-1.amazonaws.com/", (captured_request as {string:any}).url)
end)

it("plugins do not mutate original client config", function()
    local c = client_mod.new(make_auth_config())
    ;(c as any):invokeOperation(service, operation, {}, {
        plugins = {
            function(cfg: {string:any}) cfg["region"] = "ap-southeast-1" end,
        },
    }):await()
    assert.are.equal("us-east-1", (c as {string:any}).config.region)
end)

it("serialize error short-circuits pipeline", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        protocol = {
            serialize = function(self: any): any, any return nil, { type = "sdk", message = "bad input" } end,
            deserialize = function(self: any): any, any error("should not be called") end,
        },
    } as {string:any}))
    local output, err = (c as any):invokeOperation(service, operation, {}):await()
    assert(output == nil, "output should be nil")
    assert.are.equal("bad input", (err as {string:any}).message)
    assert.are.equal(0, #calls)
end)

it("noAuth scheme skips signing", function()
    calls = {}
    local noauth_op = schema.operation({ id = "AssumeRoleWithWebIdentity" } as any)
    ;(noauth_op as {string:any}).auth_schemes = {
        { scheme_id = "smithy.api#noAuth" },
    }
    local c = client_mod.new(make_auth_config())
    local output, err = (c as any):invokeOperation(service, noauth_op, {}):await()
    assert(not err, "unexpected error: " .. tostring(err and (err as {string:any}).message))
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
        endpoint_provider = function(params: {string:any}): any, any
            return {
                url = "https://custom.endpoint.com",
                properties = {
                    authSchemes = {
                        { name = "sigv4", signingName = "custom-service", signingRegion = "us-west-2" },
                    },
                },
            }, nil
        end,
    } as {string:any}))
    ;(c as any):invokeOperation(service, operation, {}):await()
    assert.are.equal("custom-service", (signer_args["props"] as {string:any}).signing_name)
    assert.are.equal("us-west-2", (signer_args["props"] as {string:any}).signing_region)
end)

it("no supported auth scheme returns error", function()
    calls = {}
    local c = client_mod.new(make_auth_config({
        auth_schemes = {},
    } as {string:any}))
    local output, err = (c as any):invokeOperation(service, operation, {}):await()
    assert(output == nil, "output should be nil")
    assert(((err as {string:any}).message as string):find("no auth scheme"), "error should mention no auth scheme: " .. (err as {string:any}).message as string)
end)

end)
