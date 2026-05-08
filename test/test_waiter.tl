local assert = require("luassert") as any
-- Test: runtime/waiter.lua

local waiter = require("smithy.waiter")
local eval_path = waiter._eval_path
local eval_acceptor = waiter._eval_acceptor

describe("waiter", function()

-- === eval_path tests ===

it("eval_path: simple field", function()
    assert.are.equal("ACTIVE", eval_path({ Status = "ACTIVE" }, "Status"))
end)

it("eval_path: nested field", function()
    assert.are.equal("ACTIVE", eval_path({ Table = { TableStatus = "ACTIVE" } }, "Table.TableStatus"))
end)

it("eval_path: missing field returns nil", function()
    assert.are.equal(nil, eval_path({ Table = {} }, "Table.TableStatus"))
end)

it("eval_path: nil root returns nil", function()
    assert.are.equal(nil, eval_path(nil, "Foo"))
end)

it("eval_path: flatten array", function()
    local obj = {
        Reservations = {
            { Instances = { { State = { Name = "running" } } } },
            { Instances = { { State = { Name = "stopped" } } } },
        }
    }
    local result = eval_path(obj, "Reservations[].Instances[].State.Name") as {string}
    assert.are.equal("table", type(result))
    assert.are.equal(2, #result)
    assert.are.equal("running", result[1])
    assert.are.equal("stopped", result[2])
end)

it("eval_path: flatten single level", function()
    local obj = { Items = { { Status = "ok" }, { Status = "err" } } }
    local result = eval_path(obj, "Items[].Status") as {string}
    assert.are.equal(2, #result)
    assert.are.equal("ok", result[1])
    assert.are.equal("err", result[2])
end)

it("eval_path: inputOutput synthetic", function()
    local obj = { input = { Id = "abc" }, output = { Name = "xyz" } }
    assert.are.equal("xyz", eval_path(obj, "output.Name"))
    assert.are.equal("abc", eval_path(obj, "input.Id"))
end)

-- === comparator tests ===

it("stringEquals: match", function()
    assert.are.equal("success", waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, { Status = "ACTIVE" }, nil
    ))
end)

it("stringEquals: no match", function()
    assert.are.equal(nil, waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, { Status = "CREATING" }, nil
    ))
end)

it("booleanEquals: match true", function()
    assert.are.equal("success", waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Ready", comparator = "booleanEquals", expected = "true" } } },
        nil, { Ready = true }, nil
    ))
end)

it("allStringEquals: all match", function()
    assert.are.equal("success", waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = { { Status = "running" }, { Status = "running" } } }, nil
    ))
end)

it("allStringEquals: not all match", function()
    assert.are.equal(nil, waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = { { Status = "running" }, { Status = "stopped" } } }, nil
    ))
end)

it("allStringEquals: empty list", function()
    assert.are.equal(nil, waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = {} }, nil
    ))
end)

it("anyStringEquals: one matches", function()
    assert.are.equal("failure", waiter._eval_acceptor(
        { state = "failure", matcher = { output = { path = "Items[].Status", comparator = "anyStringEquals", expected = "terminated" } } },
        nil, { Items = { { Status = "running" }, { Status = "terminated" } } }, nil
    ))
end)

it("anyStringEquals: none match", function()
    assert.are.equal(nil, waiter._eval_acceptor(
        { state = "failure", matcher = { output = { path = "Items[].Status", comparator = "anyStringEquals", expected = "terminated" } } },
        nil, { Items = { { Status = "running" }, { Status = "stopped" } } }, nil
    ))
end)

-- === acceptor matcher type tests ===

it("success matcher: true on success", function()
    assert.are.equal("success", eval_acceptor(
        { state = "success", matcher = { success = true } },
        nil, { Foo = "bar" }, nil
    ))
end)

it("success matcher: true on error returns nil", function()
    assert.are.equal(nil, eval_acceptor(
        { state = "success", matcher = { success = true } },
        nil, nil, { type = "api", code = "Err" }
    ))
end)

it("success matcher: false on error", function()
    assert.are.equal("failure", eval_acceptor(
        { state = "failure", matcher = { success = false } },
        nil, nil, { type = "api", code = "Err" }
    ))
end)

it("errorType matcher: match", function()
    assert.are.equal("retry", eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, nil, { type = "api", code = "ResourceNotFoundException" }
    ))
end)

it("errorType matcher: no match", function()
    assert.are.equal(nil, eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, nil, { type = "api", code = "OtherError" }
    ))
end)

it("errorType matcher: no error", function()
    assert.are.equal(nil, eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, { Foo = "bar" }, nil
    ))
end)

it("output matcher: skipped on error", function()
    assert.are.equal(nil, eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, nil, { type = "api", code = "Err" }
    ))
end)

it("inputOutput matcher: cross-reference", function()
    assert.are.equal("success", eval_acceptor(
        { state = "success", matcher = { inputOutput = { path = "output.Name", comparator = "stringEquals", expected = "test" } } },
        { Id = "123" }, { Name = "test" }, nil
    ))
end)

-- === compute_delay tests ===

it("compute_delay: first attempt returns min_delay", function()
    assert.are.equal(2, waiter.compute_delay(1, 2, 120))
end)

it("compute_delay: grows exponentially", function()
    math.randomseed(42)
    local d = waiter.compute_delay(3, 2, 120)
    assert(d >= 2 and d <= 8, "delay should be between 2 and 8, got " .. d)
end)

it("compute_delay: capped at max_delay", function()
    math.randomseed(42)
    local d = waiter.compute_delay(20, 2, 10)
    assert(d >= 2 and d <= 10, "delay should be capped at 10, got " .. d)
end)

-- === wait() integration tests (with mock client) ===

it("wait: success on first attempt", function()
    local mock_client = {
        describeTable = function(self: any, input: {string:any}): {string:any}, any
            return { Table = { TableStatus = "ACTIVE" } }, nil
        end,
    }
    local config = {
        acceptors = {
            { state = "success", matcher = { output = { path = "Table.TableStatus", comparator = "stringEquals", expected = "ACTIVE" } } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "describeTable", { TableName = "t" }, config, { max_wait_time = 5 })
    assert(not err, "unexpected error: " .. tostring(err and (err as {string:string}).message))
    assert.are.equal("ACTIVE", (output as {string:any}).Table.TableStatus)
end)

it("wait: retries then succeeds", function()
    local attempt = 0
    local mock_client = {
        describeTable = function(self: any, input: {string:any}): {string:any}, any
            attempt = attempt + 1
            if attempt < 3 then
                return nil, { type = "api", code = "ResourceNotFoundException", message = "not found" }
            end
            return { Table = { TableStatus = "ACTIVE" } }, nil
        end,
    }
    local config = {
        acceptors = {
            { state = "success", matcher = { output = { path = "Table.TableStatus", comparator = "stringEquals", expected = "ACTIVE" } } },
            { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "describeTable", {}, config, { max_wait_time = 5 })
    assert(not err, "unexpected error: " .. tostring(err and (err as {string:string}).message))
    assert.are.equal(3, attempt)
    assert.are.equal("ACTIVE", (output as {string:any}).Table.TableStatus)
end)

it("wait: failure acceptor stops immediately", function()
    local mock_client = {
        describe = function(self: any, input: {string:any}): {string:any}, any
            return { Status = "FAILED" }, nil
        end,
    }
    local config = {
        acceptors = {
            { state = "failure", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "FAILED" } } },
            { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "describe", {}, config, { max_wait_time = 5 })
    assert(output == nil, "output should be nil on failure")
    assert.are.equal("WaiterFailure", (err as {string:string}).code)
end)

it("wait: unmatched error propagates", function()
    local mock_client = {
        describe = function(self: any, input: {string:any}): {string:any}, any
            return nil, { type = "api", code = "AccessDenied", message = "forbidden" }
        end,
    }
    local config = {
        acceptors = {
            { state = "success", matcher = { success = true } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "describe", {}, config, { max_wait_time = 5 })
    assert.are.equal("AccessDenied", (err as {string:string}).code)
end)

it("wait: missing max_wait_time returns error", function()
    local output, err = waiter.wait({}, "op", {}, { acceptors = {} }, {})
    assert.are.equal("WaiterInvalidConfig", (err as {string:string}).code)
end)

it("wait: success=true matcher (BucketExists pattern)", function()
    local mock_client = {
        headBucket = function(self: any, input: {string:any}): {string:any}, any
            return {}, nil
        end,
    }
    local config = {
        acceptors = {
            { state = "success", matcher = { success = true } },
            { state = "retry", matcher = { errorType = "NotFound" } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "headBucket", {}, config, { max_wait_time = 5 })
    assert(not err)
    assert(output)
end)

it("wait: errorType success (BucketNotExists pattern)", function()
    local mock_client = {
        headBucket = function(self: any, input: {string:any}): {string:any}, any
            return nil, { type = "api", code = "NotFound", message = "not found" }
        end,
    }
    local config = {
        acceptors = {
            { state = "success", matcher = { errorType = "NotFound" } },
        },
        min_delay = 0.01,
        max_delay = 0.01,
    }
    local output, err = waiter.wait(mock_client, "headBucket", {}, config, { max_wait_time = 5 })
    assert(not err, "unexpected error: " .. tostring(err and (err as {string:string}).message))
end)

end)
