-- Test: generated client wired to base client invokeOperation pipeline
-- Verifies the full flow: generated client -> invokeOperation -> protocol -> transport -> response

-- Set up package path: runtime + generated code
local root = debug.getinfo(1, "S").source:match("@(.*/)")
package.path = root .. "../runtime/?.lua;"
    .. root .. "../codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/source/lua-client-codegen/?.lua;"
    .. package.path

local weather = require("weather.client")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " - " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. " expected: " .. tostring(b) .. ", got: " .. tostring(a), 2)
    end
end

print("=== codegen wire tests ===")

test("generated client has invokeOperation", function()
    local client = weather.new({ region = "us-east-1" })
    assert(client.invokeOperation, "missing invokeOperation")
end)

test("generated client sets service_id and signing_name", function()
    local config = { region = "us-east-1" }
    local client = weather.new(config)
    assert_eq(client.config.service_id, "Weather")
    assert_eq(client.config.signing_name, "weather")
end)

test("getCity flows through full pipeline", function()
    local captured_request = nil

    local client = weather.new({
        region = "us-east-1",
        protocol = {
            serialize = function(input, operation)
                -- Verify operation metadata passed through
                assert_eq(operation.name, "GetCity")
                assert_eq(operation.http_method, "GET")
                assert_eq(operation.http_path, "/cities/{cityId}")
                assert(operation.input_schema, "missing input_schema")
                return {
                    method = "GET",
                    url = "/cities/seattle",
                    headers = { ["Content-Type"] = "application/json" },
                }, nil
            end,
            deserialize = function(response, operation)
                assert_eq(response.status_code, 200)
                return { name = "Seattle" }, nil
            end,
        },
        http_client = function(request)
            captured_request = request
            return { status_code = 200, headers = {}, body = nil }, nil
        end,
        endpoint_provider = function(params)
            assert_eq(params.region, "us-east-1")
            return { url = "https://weather.us-east-1.amazonaws.com" }, nil
        end,
        identity_resolver = function()
            return { access_key = "AKID", secret_key = "secret" }, nil
        end,
        signer = function(request, identity, props)
            assert_eq(identity.access_key, "AKID")
            assert_eq(props.signing_name, "weather")
            assert_eq(props.region, "us-east-1")
            request.headers["Authorization"] = "signed"
            return request, nil
        end,
    })

    local output, err = client:getCity({ cityId = "seattle" })
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.name, "Seattle")
    -- Verify request was sent with endpoint + signing
    assert_eq(captured_request.url, "https://weather.us-east-1.amazonaws.com/cities/seattle")
    assert_eq(captured_request.headers["Authorization"], "signed")
end)

test("pipeline returns protocol serialize error", function()
    local client = weather.new({
        region = "us-east-1",
        protocol = {
            serialize = function() return nil, { type = "sdk", message = "bad input" } end,
        },
    })
    local output, err = client:getCity({})
    assert(not output, "expected nil output")
    assert_eq(err.message, "bad input")
end)

test("per-call plugins modify config", function()
    local used_region = nil
    local client = weather.new({
        region = "us-east-1",
        protocol = {
            serialize = function(input, op)
                return { method = "GET", url = "/", headers = {} }, nil
            end,
            deserialize = function(resp, op) return {}, nil end,
        },
        http_client = function(req) return { status_code = 200, headers = {} }, nil end,
        endpoint_provider = function(params)
            used_region = params.region
            return { url = "https://example.com" }, nil
        end,
        identity_resolver = function() return { access_key = "A", secret_key = "S" }, nil end,
        signer = function(req, id, props) return req, nil end,
    })

    client:getCity({ cityId = "x" }, {
        plugins = {
            function(config) config.region = "eu-west-1" end,
        },
    })
    assert_eq(used_region, "eu-west-1")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
