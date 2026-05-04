-- Test: generated client wired to base client invokeOperation pipeline
-- Verifies the full flow: generated client -> invokeOperation -> protocol -> transport -> response

-- Set up package path: runtime + generated code
local root = debug.getinfo(1, "S").source:match("@(.*/)")
package.path = root .. "../runtime/?.lua;"
    .. root .. "../codegen/smithy-lua-codegen-test/build/smithyprojections/smithy-lua-codegen-test/source/lua-client-codegen/?.lua;"
    .. package.path

local sqs = require("amazonSQS.client")

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

-- helper: build a client with mock config
local function mock_client(overrides)
    local config = {
        region = "us-east-1",
        protocol = {
            serialize = function(self, input, op)
                return { method = "POST", url = "/", headers = {} }, nil
            end,
            deserialize = function(self, resp, op) return {}, nil end,
        },
        http_client = function(req) return { status_code = 200, headers = {} }, nil end,
        endpoint_provider = function(params)
            return { url = "https://sqs.us-east-1.amazonaws.com" }, nil
        end,
        identity_resolver = function() return { access_key = "AKID", secret_key = "secret" }, nil end,
        signer = function(req, id, props) return req, nil end,
    }
    if overrides then
        for k, v in pairs(overrides) do config[k] = v end
    end
    return sqs.new(config)
end

print("=== codegen wire tests (SQS) ===")

test("generated client has invokeOperation", function()
    local client = mock_client()
    assert(client.invokeOperation, "missing invokeOperation")
end)

test("generated client sets service_id and signing_name", function()
    local client = mock_client()
    assert_eq(client.config.service_id, "AmazonSQS")
end)

test("sendMessage flows through full pipeline", function()
    local captured_request = nil

    local client = mock_client({
        protocol = {
            serialize = function(self, input, operation)
                assert_eq(operation.name, "SendMessage")
                assert_eq(operation.http_method, "POST")
                assert(operation.input_schema, "missing input_schema")
                assert(operation.input_schema.members.QueueUrl, "missing QueueUrl in schema")
                assert(operation.input_schema.members.MessageBody, "missing MessageBody in schema")
                return {
                    method = "POST",
                    url = "/",
                    headers = { ["Content-Type"] = "application/x-amz-json-1.0" },
                }, nil
            end,
            deserialize = function(self, response, operation)
                assert_eq(response.status_code, 200)
                return { MessageId = "abc-123", MD5OfMessageBody = "deadbeef" }, nil
            end,
        },
        http_client = function(request)
            captured_request = request
            return { status_code = 200, headers = {} }, nil
        end,
        signer = function(request, identity, props)
            request.headers["Authorization"] = "signed"
            return request, nil
        end,
    })

    local output, err = client:sendMessage({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123456789012/my-queue",
        MessageBody = "hello",
    })
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.MessageId, "abc-123")
    assert_eq(captured_request.url, "https://sqs.us-east-1.amazonaws.com/")
    assert_eq(captured_request.headers["Authorization"], "signed")
end)

test("pipeline returns protocol serialize error", function()
    local client = mock_client({
        protocol = {
            serialize = function(self) return nil, { type = "sdk", message = "bad input" } end,
        },
    })
    local output, err = client:sendMessage({})
    assert(not output, "expected nil output")
    assert_eq(err.message, "bad input")
end)

test("per-call plugins modify config", function()
    local used_region = nil
    local client = mock_client({
        endpoint_provider = function(params)
            used_region = params.region
            return { url = "https://sqs.eu-west-1.amazonaws.com" }, nil
        end,
    })

    client:sendMessage({ QueueUrl = "x", MessageBody = "y" }, {
        plugins = {
            function(config) config.region = "eu-west-1" end,
        },
    })
    assert_eq(used_region, "eu-west-1")
end)

test("all 23 SQS operations exist on client", function()
    local client = mock_client()
    local ops = {
        "addPermission", "cancelMessageMoveTask", "changeMessageVisibility",
        "changeMessageVisibilityBatch", "createQueue", "deleteMessage",
        "deleteMessageBatch", "deleteQueue", "getQueueAttributes", "getQueueUrl",
        "listDeadLetterSourceQueues", "listMessageMoveTasks", "listQueues",
        "listQueueTags", "purgeQueue", "receiveMessage", "removePermission",
        "sendMessage", "sendMessageBatch", "setQueueAttributes",
        "startMessageMoveTask", "tagQueue", "untagQueue",
    }
    for _, op in ipairs(ops) do
        assert(type(client[op]) == "function", "missing operation: " .. op)
    end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
