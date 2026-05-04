-- Test: runtime/waiter.lua
-- Run: luajit test/test_waiter.lua

package.path = "runtime/?.lua;" .. package.path

local waiter = require("smithy.waiter")
local eval_path = waiter._eval_path
local eval_acceptor = waiter._eval_acceptor

local pass_count = 0
local fail_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print("PASS: " .. name)
    else
        fail_count = fail_count + 1
        print("FAIL: " .. name .. "\n  " .. tostring(err))
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

-- === eval_path tests ===

test("eval_path: simple field", function()
    assert_eq(eval_path({ Status = "ACTIVE" }, "Status"), "ACTIVE")
end)

test("eval_path: nested field", function()
    assert_eq(eval_path({ Table = { TableStatus = "ACTIVE" } }, "Table.TableStatus"), "ACTIVE")
end)

test("eval_path: missing field returns nil", function()
    assert_eq(eval_path({ Table = {} }, "Table.TableStatus"), nil)
end)

test("eval_path: nil root returns nil", function()
    assert_eq(eval_path(nil, "Foo"), nil)
end)

test("eval_path: flatten array", function()
    local obj = {
        Reservations = {
            { Instances = { { State = { Name = "running" } } } },
            { Instances = { { State = { Name = "stopped" } } } },
        }
    }
    local result = eval_path(obj, "Reservations[].Instances[].State.Name")
    assert_eq(type(result), "table")
    assert_eq(#result, 2)
    assert_eq(result[1], "running")
    assert_eq(result[2], "stopped")
end)

test("eval_path: flatten single level", function()
    local obj = { Items = { { Status = "ok" }, { Status = "err" } } }
    local result = eval_path(obj, "Items[].Status")
    assert_eq(#result, 2)
    assert_eq(result[1], "ok")
    assert_eq(result[2], "err")
end)

test("eval_path: inputOutput synthetic", function()
    local obj = { input = { Id = "abc" }, output = { Name = "xyz" } }
    assert_eq(eval_path(obj, "output.Name"), "xyz")
    assert_eq(eval_path(obj, "input.Id"), "abc")
end)

-- === comparator tests ===

test("stringEquals: match", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, { Status = "ACTIVE" }, nil
    ), "success")
end)

test("stringEquals: no match", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, { Status = "CREATING" }, nil
    ), nil)
end)

test("booleanEquals: match true", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Ready", comparator = "booleanEquals", expected = "true" } } },
        nil, { Ready = true }, nil
    ), "success")
end)

test("allStringEquals: all match", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = { { Status = "running" }, { Status = "running" } } }, nil
    ), "success")
end)

test("allStringEquals: not all match", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = { { Status = "running" }, { Status = "stopped" } } }, nil
    ), nil)
end)

test("allStringEquals: empty list", function()
    assert_eq(waiter._eval_acceptor(
        { state = "success", matcher = { output = { path = "Items[].Status", comparator = "allStringEquals", expected = "running" } } },
        nil, { Items = {} }, nil
    ), nil)
end)

test("anyStringEquals: one matches", function()
    assert_eq(waiter._eval_acceptor(
        { state = "failure", matcher = { output = { path = "Items[].Status", comparator = "anyStringEquals", expected = "terminated" } } },
        nil, { Items = { { Status = "running" }, { Status = "terminated" } } }, nil
    ), "failure")
end)

test("anyStringEquals: none match", function()
    assert_eq(waiter._eval_acceptor(
        { state = "failure", matcher = { output = { path = "Items[].Status", comparator = "anyStringEquals", expected = "terminated" } } },
        nil, { Items = { { Status = "running" }, { Status = "stopped" } } }, nil
    ), nil)
end)

-- === acceptor matcher type tests ===

test("success matcher: true on success", function()
    assert_eq(eval_acceptor(
        { state = "success", matcher = { success = true } },
        nil, { Foo = "bar" }, nil
    ), "success")
end)

test("success matcher: true on error returns nil", function()
    assert_eq(eval_acceptor(
        { state = "success", matcher = { success = true } },
        nil, nil, { type = "api", code = "Err" }
    ), nil)
end)

test("success matcher: false on error", function()
    assert_eq(eval_acceptor(
        { state = "failure", matcher = { success = false } },
        nil, nil, { type = "api", code = "Err" }
    ), "failure")
end)

test("errorType matcher: match", function()
    assert_eq(eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, nil, { type = "api", code = "ResourceNotFoundException" }
    ), "retry")
end)

test("errorType matcher: no match", function()
    assert_eq(eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, nil, { type = "api", code = "OtherError" }
    ), nil)
end)

test("errorType matcher: no error", function()
    assert_eq(eval_acceptor(
        { state = "retry", matcher = { errorType = "ResourceNotFoundException" } },
        nil, { Foo = "bar" }, nil
    ), nil)
end)

test("output matcher: skipped on error", function()
    assert_eq(eval_acceptor(
        { state = "success", matcher = { output = { path = "Status", comparator = "stringEquals", expected = "ACTIVE" } } },
        nil, nil, { type = "api", code = "Err" }
    ), nil)
end)

test("inputOutput matcher: cross-reference", function()
    assert_eq(eval_acceptor(
        { state = "success", matcher = { inputOutput = { path = "output.Name", comparator = "stringEquals", expected = "test" } } },
        { Id = "123" }, { Name = "test" }, nil
    ), "success")
end)

-- === compute_delay tests ===

test("compute_delay: first attempt returns min_delay", function()
    assert_eq(waiter.compute_delay(1, 2, 120), 2)
end)

test("compute_delay: grows exponentially", function()
    math.randomseed(42)
    local d = waiter.compute_delay(3, 2, 120)
    -- attempt 3: min * 2^2 = 8, jitter between 2 and 8
    assert(d >= 2 and d <= 8, "delay should be between 2 and 8, got " .. d)
end)

test("compute_delay: capped at max_delay", function()
    math.randomseed(42)
    local d = waiter.compute_delay(20, 2, 10)
    assert(d >= 2 and d <= 10, "delay should be capped at 10, got " .. d)
end)

-- === wait() integration tests (with mock client) ===

test("wait: success on first attempt", function()
    local mock_client = {
        describeTable = function(self, input)
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
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(output.Table.TableStatus, "ACTIVE")
end)

test("wait: retries then succeeds", function()
    local attempt = 0
    local mock_client = {
        describeTable = function(self, input)
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
    assert(not err, "unexpected error: " .. tostring(err and err.message))
    assert_eq(attempt, 3)
    assert_eq(output.Table.TableStatus, "ACTIVE")
end)

test("wait: failure acceptor stops immediately", function()
    local mock_client = {
        describe = function(self, input)
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
    assert_eq(err.code, "WaiterFailure")
end)

test("wait: unmatched error propagates", function()
    local mock_client = {
        describe = function(self, input)
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
    assert_eq(err.code, "AccessDenied")
end)

test("wait: missing max_wait_time returns error", function()
    local output, err = waiter.wait({}, "op", {}, { acceptors = {} }, {})
    assert_eq(err.code, "WaiterInvalidConfig")
end)

test("wait: success=true matcher (BucketExists pattern)", function()
    local mock_client = {
        headBucket = function(self, input)
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

test("wait: errorType success (BucketNotExists pattern)", function()
    local mock_client = {
        headBucket = function(self, input)
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
    assert(not err, "unexpected error: " .. tostring(err and err.message))
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
