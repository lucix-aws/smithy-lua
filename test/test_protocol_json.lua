-- Test: runtime/protocol/awsjson.lua — awsJson1.0/1.1 protocol
-- Run: luajit test/test_protocol_json.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local aws_json = require("smithy.protocol.awsjson")
local http = require("smithy.http")
local schema = require("smithy.schema")
local shape_id = require("smithy.shape_id")
local traits = require("smithy.traits")
local stype = schema.type

local pass_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
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

-- Service schema
local service = schema.service({
    id = shape_id.from("com.amazonaws.sqs", "AmazonSQS"),
    version = "2012-11-05",
    traits = {},
})

-- Input/output schemas
local get_queue_url_input = schema.new({
    id = shape_id.from("com.amazonaws.sqs", "GetQueueUrlInput"),
    type = stype.STRUCTURE,
    members = {
        QueueName = schema.new({ type = stype.STRING, name = "QueueName" }),
    },
})

local get_queue_url_output = schema.new({
    id = shape_id.from("com.amazonaws.sqs", "GetQueueUrlOutput"),
    type = stype.STRUCTURE,
    members = {
        QueueUrl = schema.new({ type = stype.STRING, name = "QueueUrl" }),
    },
})

local send_message_input = schema.new({
    id = shape_id.from("com.amazonaws.sqs", "SendMessageInput"),
    type = stype.STRUCTURE,
    members = {
        QueueUrl = schema.new({ type = stype.STRING, name = "QueueUrl" }),
        MessageBody = schema.new({ type = stype.STRING, name = "MessageBody" }),
        DelaySeconds = schema.new({ type = stype.INTEGER, name = "DelaySeconds" }),
    },
})

local send_message_output = schema.new({
    id = shape_id.from("com.amazonaws.sqs", "SendMessageOutput"),
    type = stype.STRUCTURE,
    members = {
        MessageId = schema.new({ type = stype.STRING, name = "MessageId" }),
        MD5OfMessageBody = schema.new({ type = stype.STRING, name = "MD5OfMessageBody" }),
    },
})

local empty_output = schema.new({
    id = shape_id.from("com.amazonaws.sqs", "EmptyOutput"),
    type = stype.STRUCTURE,
})

-- Operation schemas
local operation = schema.operation({
    id = shape_id.from("com.amazonaws.sqs", "GetQueueUrl"),
    input = get_queue_url_input,
    output = get_queue_url_output,
    traits = {
        [traits.HTTP] = { method = "POST", path = "/" },
    },
})

-- === Serialize tests ===

local protocol = aws_json.new({ version = "1.0" })

test("serialize: content-type is application/x-amz-json-1.0", function()
    local req, err = protocol:serialize({ QueueName = "test" }, service, operation)
    assert(not err, tostring(err and err.message))
    assert_eq(req.headers["Content-Type"], "application/x-amz-json-1.0")
end)

test("serialize: X-Amz-Target is service.operation", function()
    local req, err = protocol:serialize({ QueueName = "test" }, service, operation)
    assert(not err)
    assert_eq(req.headers["X-Amz-Target"], "AmazonSQS.GetQueueUrl")
end)

test("serialize: method and path from operation", function()
    local req, err = protocol:serialize({ QueueName = "test" }, service, operation)
    assert(not err)
    assert_eq(req.method, "POST")
    assert_eq(req.url, "/")
end)

test("serialize: body is JSON-encoded input", function()
    local req, err = protocol:serialize({ QueueName = "my-queue" }, service, operation)
    assert(not err)
    local body = http.read_all(req.body)
    assert_eq(body, '{"QueueName":"my-queue"}')
end)

test("serialize: empty input produces {}", function()
    local req, err = protocol:serialize({}, service, operation)
    assert(not err)
    local body = http.read_all(req.body)
    assert_eq(body, '{}')
end)

test("serialize: nil input produces {}", function()
    local req, err = protocol:serialize(nil, service, operation)
    assert(not err)
    local body = http.read_all(req.body)
    assert_eq(body, '{}')
end)

test("serialize: multiple members", function()
    local op = schema.operation({
        id = shape_id.from("com.amazonaws.sqs", "SendMessage"),
        input = send_message_input,
        output = send_message_output,
        traits = {
            [traits.HTTP] = { method = "POST", path = "/" },
        },
    })
    local req, err = protocol:serialize({
        QueueUrl = "https://sqs.us-east-1.amazonaws.com/123/test",
        MessageBody = "hello",
        DelaySeconds = 10,
    }, service, op)
    assert(not err)
    local body = http.read_all(req.body)
    -- Keys sorted: DelaySeconds, MessageBody, QueueUrl
    assert_eq(body, '{"DelaySeconds":10,"MessageBody":"hello","QueueUrl":"https://sqs.us-east-1.amazonaws.com/123/test"}')
end)

test("serialize: version 1.1", function()
    local p11 = aws_json.new({ version = "1.1" })
    local svc = schema.service({
        id = shape_id.from("com.amazonaws.dynamodb", "DynamoDB_20120810"),
        version = "2012-08-10",
        traits = {},
    })
    local req, err = p11:serialize({}, svc, operation)
    assert(not err)
    assert_eq(req.headers["Content-Type"], "application/x-amz-json-1.1")
end)

-- === Deserialize tests ===

test("deserialize: success with body", function()
    local response = {
        status_code = 200,
        headers = { ["Content-Type"] = "application/x-amz-json-1.0" },
        body = http.string_reader('{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123/test"}'),
    }
    local output, err = protocol:deserialize(response, operation)
    assert(not err, tostring(err and err.message))
    assert_eq(output.QueueUrl, "https://sqs.us-east-1.amazonaws.com/123/test")
end)

test("deserialize: empty body returns empty table", function()
    local response = {
        status_code = 200,
        headers = {},
        body = http.string_reader(""),
    }
    local op = schema.operation({
        id = shape_id.from("com.amazonaws.sqs", "DeleteQueue"),
        input = empty_output,
        output = empty_output,
        traits = { [traits.HTTP] = { method = "POST", path = "/" } },
    })
    local output, err = protocol:deserialize(response, op)
    assert(not err)
    assert(output, "expected non-nil output")
end)

test("deserialize: {} body returns empty table", function()
    local response = {
        status_code = 200,
        headers = {},
        body = http.string_reader("{}"),
    }
    local output, err = protocol:deserialize(response, operation)
    assert(not err)
    assert(output, "expected non-nil output")
end)

test("deserialize: error from x-amzn-errortype header", function()
    local response = {
        status_code = 400,
        headers = { ["x-amzn-errortype"] = "QueueDoesNotExist" },
        body = http.string_reader('{"message":"The queue does not exist"}'),
    }
    local output, err = protocol:deserialize(response, operation)
    assert(not output, "expected nil output on error")
    assert_eq(err.type, "api")
    assert_eq(err.code, "QueueDoesNotExist")
    assert_eq(err.message, "The queue does not exist")
    assert_eq(err.status_code, 400)
end)

test("deserialize: error from __type in body", function()
    local response = {
        status_code = 400,
        headers = {},
        body = http.string_reader('{"__type":"com.amazonaws.sqs#QueueDoesNotExist","message":"not found"}'),
    }
    local output, err = protocol:deserialize(response, operation)
    assert(not output)
    assert_eq(err.code, "QueueDoesNotExist")
    assert_eq(err.message, "not found")
end)

test("deserialize: error strips colon from header", function()
    local response = {
        status_code = 400,
        headers = { ["x-amzn-errortype"] = "ValidationException:http://internal" },
        body = http.string_reader('{"message":"bad input"}'),
    }
    local _, err = protocol:deserialize(response, operation)
    assert_eq(err.code, "ValidationException")
end)

test("deserialize: error with Message (capital M)", function()
    local response = {
        status_code = 500,
        headers = {},
        body = http.string_reader('{"__type":"InternalError","Message":"something broke"}'),
    }
    local _, err = protocol:deserialize(response, operation)
    assert_eq(err.code, "InternalError")
    assert_eq(err.message, "something broke")
end)

test("deserialize: error with empty body", function()
    local response = {
        status_code = 503,
        headers = {},
        body = http.string_reader(""),
    }
    local _, err = protocol:deserialize(response, operation)
    assert_eq(err.type, "api")
    assert_eq(err.code, "UnknownError")
    assert_eq(err.status_code, 503)
end)

test("deserialize: 5xx is an error", function()
    local response = {
        status_code = 500,
        headers = { ["x-amzn-errortype"] = "ServiceUnavailable" },
        body = http.string_reader('{"message":"try again"}'),
    }
    local _, err = protocol:deserialize(response, operation)
    assert_eq(err.type, "api")
    assert_eq(err.code, "ServiceUnavailable")
end)

print(string.format("\nAll %d protocol tests passed.", pass_count))
