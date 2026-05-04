-- SQS test harness: exercises the full pipeline with real runtime components
-- and a mock HTTP transport. Prints what happens at each stage.
--
-- Usage: cd smithy-lua && luajit test/harness_sqs.lua

local root = debug.getinfo(1, "S").source:match("@(.*/)")
package.path = root .. "../runtime/?.lua;"
    .. root .. "../runtime/?/init.lua;"
    .. root .. "../codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/sqs/lua-client-codegen/?.lua;"
    .. package.path

local sqs = require("sqs.client")
local protocol_json = require("protocol.awsjson")
local signer = require("signer")
local auth = require("auth")
local http = require("http")

local passed, failed = 0, 0
local function test(name, fn)
    print("\n--- " .. name .. " ---")
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS")
    else
        failed = failed + 1
        print("  FAIL: " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. " expected: " .. tostring(b) .. ", got: " .. tostring(a), 2)
    end
end

-- Wrapping transport: captures the signed request, returns a canned response
local function mock_transport(response_status, response_body)
    local captured = {}
    local transport = function(request)
        -- snapshot the request at send time
        captured.method = request.method
        captured.url = request.url
        captured.headers = {}
        for k, v in pairs(request.headers) do captured.headers[k] = v end
        local body = http.read_all(request.body)
        captured.body = body

        print("  [transport] " .. request.method .. " " .. request.url)
        print("  [transport] headers:")
        local sorted = {}
        for k in pairs(request.headers) do sorted[#sorted + 1] = k end
        table.sort(sorted)
        for _, k in ipairs(sorted) do
            local v = request.headers[k]
            if k == "Authorization" then v = v:sub(1, 60) .. "..." end
            print("              " .. k .. ": " .. v)
        end
        if body and #body > 0 then
            local display = #body > 200 and body:sub(1, 200) .. "..." or body
            print("  [transport] body: " .. display)
        end

        return {
            status_code = response_status,
            headers = { ["content-type"] = "application/x-amz-json-1.0" },
            body = http.string_reader(response_body or "{}"),
        }, nil
    end
    return transport, captured
end

-- Build a client wired to real runtime components
local function make_client(transport)
    return sqs.new({
        region = "us-east-1",
        protocol = protocol_json.new({ version = "1.0", service_id = "AmazonSQS" }),
        http_client = transport,
        endpoint_provider = function(params)
            print("  [endpoint] resolved for region=" .. params.Region)
            return { url = "https://sqs." .. params.Region .. ".amazonaws.com" }, nil
        end,
        auth_schemes = {
            [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", function(request, identity, props)
                print("  [signer] signing for " .. (props.signing_name or "?") .. " / " .. (props.signing_region or "?"))
                return signer.sign(request, identity, props)
            end),
        },
        identity_resolvers = {
            aws_credentials = function()
                print("  [identity] returning test credentials")
                return { access_key = "AKIAIOSFODNN7EXAMPLE", secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" }, nil
            end,
        },
    })
end

-- =========================================================================

test("sendMessage: full pipeline", function()
    local transport, captured = mock_transport(200, '{"MessageId":"test-msg-id-123","MD5OfMessageBody":"abc123"}')
    local client = make_client(transport)

    local output, err = client:sendMessage({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123456789012/my-queue",
        MessageBody = "hello from the harness",
    })

    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.MessageId, "test-msg-id-123")
    assert_eq(output.MD5OfMessageBody, "abc123")
    print("  [result] MessageId=" .. output.MessageId)

    -- verify the signed request looks right
    assert_eq(captured.method, "POST")
    assert(captured.headers["Authorization"], "missing Authorization header")
    assert(captured.headers["X-Amz-Target"], "missing X-Amz-Target")
    assert_eq(captured.headers["X-Amz-Target"], "AmazonSQS.SendMessage")
end)

test("getQueueUrl: full pipeline", function()
    local transport, captured = mock_transport(200, '{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123456789012/test-queue"}')
    local client = make_client(transport)

    local output, err = client:getQueueUrl({ QueueName = "test-queue" })

    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.QueueUrl, "https://sqs.us-east-1.amazonaws.com/123456789012/test-queue")
    print("  [result] QueueUrl=" .. output.QueueUrl)
    assert_eq(captured.headers["X-Amz-Target"], "AmazonSQS.GetQueueUrl")
end)

test("listQueues: empty result", function()
    local transport = mock_transport(200, '{"QueueUrls":[]}')
    local client = make_client(transport)

    local output, err = client:listQueues({})

    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert(output.QueueUrls, "expected QueueUrls in output")
    assert_eq(#output.QueueUrls, 0)
    print("  [result] QueueUrls (empty list)")
end)

test("API error: QueueDoesNotExist", function()
    local transport = mock_transport(400,
        '{"__type":"com.amazonaws.sqs#QueueDoesNotExist","message":"The specified queue does not exist."}')
    local client = make_client(transport)

    local output, err = client:getQueueUrl({ QueueName = "nope" })

    assert(not output, "expected nil output on error")
    assert(err, "expected error")
    assert_eq(err.type, "api")
    assert_eq(err.code, "QueueDoesNotExist")
    print("  [error] " .. err.code .. ": " .. err.message)
end)

test("per-call plugin: override region", function()
    local transport, captured = mock_transport(200, '{}')
    local client = make_client(transport)

    client:deleteQueue({ QueueUrl = "x" }, {
        plugins = { function(config) config.region = "eu-west-1" end },
    })

    assert(captured.url:find("eu%-west%-1"), "expected eu-west-1 in URL, got: " .. captured.url)
    print("  [result] URL=" .. captured.url)
end)

test("serialized body is valid JSON with correct members", function()
    local transport, captured = mock_transport(200, '{"MessageId":"x","MD5OfMessageBody":"y"}')
    local client = make_client(transport)

    client:sendMessage({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123456789012/q",
        MessageBody = "test body",
        DelaySeconds = 10,
    })

    -- decode the captured body
    local json_decoder = require("json.decoder")
    local body = json_decoder.decode(captured.body)
    assert_eq(body.QueueUrl, "https://sqs.us-east-1.amazonaws.com/123456789012/q")
    assert_eq(body.MessageBody, "test body")
    assert_eq(body.DelaySeconds, 10)
    print("  [body] QueueUrl=" .. body.QueueUrl)
    print("  [body] MessageBody=" .. body.MessageBody)
    print("  [body] DelaySeconds=" .. tostring(body.DelaySeconds))
end)

-- =========================================================================

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
