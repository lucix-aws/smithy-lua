-- SQS test harness: exercises the full pipeline with real runtime components
-- and a mock HTTP transport. Prints what happens at each stage.
--
-- Usage: cd smithy-lua && luajit test/harness_sqs.lua

local root = (debug.getinfo(1, "S").source as string):match("@(.*/)")
package.path = root .. "../runtime/?.lua;"
    .. root .. "../runtime/?/init.lua;"
    .. root .. "../codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/sqs/lua-client-codegen/?.lua;"
    .. package.path

local sqs = require("smithy.sqs.client")
local protocol_json = require("smithy.protocol.awsjson")
local signer = require("smithy.signer")
local auth = require("smithy.auth")
local http = require("smithy.http")

local passed, failed = 0, 0
local function test(name: string, fn: function())
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

local function assert_eq(a: any, b: any, msg: string)
    if a ~= b then
        error((msg or "") .. " expected: " .. tostring(b) .. ", got: " .. tostring(a), 2)
    end
end

-- Wrapping transport: captures the signed request, returns a canned response
local function mock_transport(response_status: number, response_body: string): function(any): any, any, {string:any}
    local captured: {string:any} = {}
    local transport = function(request: any): any, any
        local req = request as {string:any}
        -- snapshot the request at send time
        captured["method"] = req["method"]
        captured["url"] = req["url"]
        captured["headers"] = {}
        for k, v in pairs(req["headers"] as {string:string}) do
            (captured["headers"] as {string:string})[k] = v
        end
        local body = http.read_all(req["body"] as function(): string)
        captured["body"] = body

        print("  [transport] " .. (req["method"] as string) .. " " .. (req["url"] as string))
        print("  [transport] headers:")
        local sorted: {string} = {}
        for k in pairs(req["headers"] as {string:string}) do sorted[#sorted + 1] = k end
        table.sort(sorted)
        for _, k in ipairs(sorted) do
            local v = (req["headers"] as {string:string})[k]
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
local function make_client(transport: any): any
    return sqs.new({
        region = "us-east-1",
        protocol = protocol_json.new({ version = "1.0", service_id = "AmazonSQS" } as any),
        http_client = transport,
        endpoint_provider = function(params: {string:any}): any, any
            print("  [endpoint] resolved for region=" .. (params["Region"] as string))
            return { url = "https://sqs." .. (params["Region"] as string) .. ".amazonaws.com" }, nil
        end,
        auth_schemes = {
            [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", function(request: any, identity: any, props: {string:any}): any, any
                print("  [signer] signing for " .. ((props["signing_name"] as string) or "?") .. " / " .. ((props["signing_region"] as string) or "?"))
                return signer.sign(request, identity, props)
            end),
        },
        identity_resolvers = {
            aws_credentials = function(): any, any
                print("  [identity] returning test credentials")
                return { access_key = "AKIAIOSFODNN7EXAMPLE", secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" }, nil
            end,
        },
    } as any)
end

-- =========================================================================

test("sendMessage: full pipeline", function()
    local transport, captured = mock_transport(200, '{"MessageId":"test-msg-id-123","MD5OfMessageBody":"abc123"}')
    local client = make_client(transport)

    local output, err = (client as any):sendMessage({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123456789012/my-queue",
        MessageBody = "hello from the harness",
    })

    assert(not err, "unexpected error: " .. tostring(err and (err as {string:any}).message))
    assert_eq((output as {string:any}).MessageId, "test-msg-id-123")
    assert_eq((output as {string:any}).MD5OfMessageBody, "abc123")
    print("  [result] MessageId=" .. (output as {string:any}).MessageId as string)

    -- verify the signed request looks right
    assert_eq((captured as {string:any})["method"], "POST")
    assert((captured["headers"] as {string:string})["Authorization"], "missing Authorization header")
    assert((captured["headers"] as {string:string})["X-Amz-Target"], "missing X-Amz-Target")
    assert_eq((captured["headers"] as {string:string})["X-Amz-Target"], "AmazonSQS.SendMessage")
end)

test("getQueueUrl: full pipeline", function()
    local transport, captured = mock_transport(200, '{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123456789012/test-queue"}')
    local client = make_client(transport)

    local output, err = (client as any):getQueueUrl({ QueueName = "test-queue" })

    assert(not err, "unexpected error: " .. tostring(err and (err as {string:any}).message))
    assert_eq((output as {string:any}).QueueUrl, "https://sqs.us-east-1.amazonaws.com/123456789012/test-queue")
    print("  [result] QueueUrl=" .. (output as {string:any}).QueueUrl as string)
    assert_eq((captured["headers"] as {string:string})["X-Amz-Target"], "AmazonSQS.GetQueueUrl")
end)

test("listQueues: empty result", function()
    local transport = mock_transport(200, '{"QueueUrls":[]}')
    local client = make_client(transport)

    local output, err = (client as any):listQueues({})

    assert(not err, "unexpected error: " .. tostring(err and (err as {string:any}).message))
    assert((output as {string:any}).QueueUrls, "expected QueueUrls in output")
    assert_eq(#((output as {string:any}).QueueUrls as {any}), 0)
    print("  [result] QueueUrls (empty list)")
end)

test("API error: QueueDoesNotExist", function()
    local transport = mock_transport(400,
        '{"__type":"com.amazonaws.sqs#QueueDoesNotExist","message":"The specified queue does not exist."}')
    local client = make_client(transport)

    local output, err = (client as any):getQueueUrl({ QueueName = "nope" })

    assert(not output, "expected nil output on error")
    assert(err, "expected error")
    assert_eq((err as {string:any})["type"], "api")
    assert_eq((err as {string:any}).code, "QueueDoesNotExist")
    print("  [error] " .. (err as {string:any}).code as string .. ": " .. (err as {string:any}).message as string)
end)

test("per-call plugin: override region", function()
    local transport, captured = mock_transport(200, '{}')
    local client = make_client(transport)

    ;(client as any):deleteQueue({ QueueUrl = "x" }, {
        plugins = { function(config: {string:any}) config["region"] = "eu-west-1" end },
    })

    assert(((captured as {string:any})["url"] as string):find("eu%-west%-1"), "expected eu-west-1 in URL, got: " .. (captured as {string:any})["url"] as string)
    print("  [result] URL=" .. (captured as {string:any})["url"] as string)
end)

test("serialized body is valid JSON with correct members", function()
    local transport, captured = mock_transport(200, '{"MessageId":"x","MD5OfMessageBody":"y"}')
    local client = make_client(transport)

    ;(client as any):sendMessage({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123456789012/q",
        MessageBody = "test body",
        DelaySeconds = 10,
    })

    -- decode the captured body
    local json_decoder = require("smithy.json.decoder")
    local body = json_decoder.decode(captured["body"] as string)
    assert_eq((body as {string:any}).QueueUrl, "https://sqs.us-east-1.amazonaws.com/123456789012/q")
    assert_eq((body as {string:any}).MessageBody, "test body")
    assert_eq((body as {string:any}).DelaySeconds, 10)
    print("  [body] QueueUrl=" .. (body as {string:any}).QueueUrl as string)
    print("  [body] MessageBody=" .. (body as {string:any}).MessageBody as string)
    print("  [body] DelaySeconds=" .. tostring((body as {string:any}).DelaySeconds))
end)

-- =========================================================================

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
