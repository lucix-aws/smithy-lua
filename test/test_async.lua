-- Test: smithy/async.lua

local async = require("smithy.async")

describe("async", function()

describe("Operation", function()
    it("resolve then await returns value", function()
        local op = async.new_operation()
        op:resolve("hello", nil)
        local val, err = op:await()
        assert.are.equal("hello", val)
        assert.is_nil(err)
    end)

    it("resolve with error", function()
        local op = async.new_operation()
        op:resolve(nil, { code = "Fail" })
        local val, err = op:await()
        assert.is_nil(val)
        assert.are.equal("Fail", err.code)
    end)

    it("double resolve is no-op", function()
        local op = async.new_operation()
        op:resolve("first", nil)
        op:resolve("second", nil)
        local val = op:await()
        assert.are.equal("first", val)
    end)

    it("await inside coroutine yields until resolved", function()
        local op = async.new_operation()
        local result = nil

        local co = coroutine.create(function()
            result = op:await()
        end)

        coroutine.resume(co)
        assert.is_nil(result) -- still pending
        assert.are.equal("suspended", coroutine.status(co))

        op:resolve("done", nil)
        assert.are.equal("done", result) -- resolve resumed the coroutine
    end)

    it("await_all with already-resolved ops", function()
        local op1 = async.new_operation()
        local op2 = async.new_operation()
        op1:resolve("a", nil)
        op2:resolve("b", nil)

        local results = async.await_all({op1, op2})
        assert.are.equal("a", results[1][1])
        assert.are.equal("b", results[2][1])
    end)

    it("await_all inside coroutine waits for all", function()
        local op1 = async.new_operation()
        local op2 = async.new_operation()
        local results = nil

        local co = coroutine.create(function()
            results = async.await_all({op1, op2})
        end)

        coroutine.resume(co)
        assert.is_nil(results)

        op1:resolve("x", nil)
        -- op2 still pending, coroutine should still be suspended
        assert.is_nil(results)

        op2:resolve("y", nil)
        assert.is_not_nil(results)
        assert.are.equal("x", results[1][1])
        assert.are.equal("y", results[2][1])
    end)
end)

describe("Loop + curl_async integration", function()
    local curl_async = require("smithy.http.curl_async")

    it("single async GET request", function()
        local http = curl_async.new()
        local request = {
            method = "GET",
            url = "https://httpbin.org/get",
            headers = {},
        }
        local op = http:send(request)
        local response, err = op:await()
        assert(response, "expected response, got error: " .. tostring(err and err.message))
        assert.are.equal(200, response.status_code)
    end)

    it("multiple concurrent requests", function()
        local http = curl_async.new()
        local ops = {}
        for i = 1, 3 do
            ops[i] = http:send({
                method = "GET",
                url = "https://httpbin.org/get?n=" .. i,
                headers = {},
            })
        end
        local results = async.await_all(ops)
        for i = 1, 3 do
            assert(results[i][1], "request " .. i .. " should succeed")
            assert.are.equal(200, results[i][1].status_code)
        end
    end)

    it("POST with body", function()
        local http = curl_async.new()
        local smithy_http = require("smithy.http")
        local op = http:send({
            method = "POST",
            url = "https://httpbin.org/post",
            headers = { ["content-type"] = "application/json" },
            body = smithy_http.string_reader('{"key":"value"}'),
        })
        local response, err = op:await()
        assert(response, "expected response: " .. tostring(err and err.message))
        assert.are.equal(200, response.status_code)
    end)
end)

end)
