-- Test: runtime/error.lua
-- Run: luajit test/test_error.lua

package.path = "runtime/?.lua;" .. package.path

local error_mod = require("error")

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
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

-- === Constructor tests ===

test("new_api_error", function()
    local err = error_mod.new_api_error("NoSuchBucket", "not found", 404)
    assert_eq(err.type, "api")
    assert_eq(err.code, "NoSuchBucket")
    assert_eq(err.message, "not found")
    assert_eq(err.status_code, 404)
end)

test("new_api_error with extra fields", function()
    local err = error_mod.new_api_error("InvalidObjectState", "bad", 409, { StorageClass = "GLACIER" })
    assert_eq(err.StorageClass, "GLACIER")
    assert_eq(err.code, "InvalidObjectState")
end)

test("new_http_error", function()
    local err = error_mod.new_http_error("connection refused")
    assert_eq(err.type, "http")
    assert_eq(err.code, "HttpError")
    assert_eq(err.message, "connection refused")
end)

test("new_sdk_error", function()
    local err = error_mod.new_sdk_error("SerializationError", "bad input")
    assert_eq(err.type, "sdk")
    assert_eq(err.code, "SerializationError")
end)

-- === Classification tests ===

test("is_throttle: 429 status", function()
    assert(error_mod.is_throttle({ status_code = 429 }))
end)

test("is_throttle: Throttling code", function()
    assert(error_mod.is_throttle({ code = "Throttling" }))
end)

test("is_throttle: TooManyRequestsException", function()
    assert(error_mod.is_throttle({ code = "TooManyRequestsException" }))
end)

test("is_throttle: SlowDown", function()
    assert(error_mod.is_throttle({ code = "SlowDown" }))
end)

test("is_throttle: false for normal error", function()
    assert(not error_mod.is_throttle({ code = "NoSuchBucket", status_code = 404 }))
end)

test("is_throttle: nil safe", function()
    assert(not error_mod.is_throttle(nil))
end)

test("is_transient: HTTP error type", function()
    assert(error_mod.is_transient({ type = "http", message = "timeout" }))
end)

test("is_transient: 500", function()
    assert(error_mod.is_transient({ type = "api", status_code = 500 }))
end)

test("is_transient: 503", function()
    assert(error_mod.is_transient({ type = "api", status_code = 503 }))
end)

test("is_transient: false for 400", function()
    assert(not error_mod.is_transient({ type = "api", status_code = 400 }))
end)

test("is_timeout: RequestTimeout", function()
    assert(error_mod.is_timeout({ code = "RequestTimeout" }))
end)

test("is_timeout: RequestTimeoutException", function()
    assert(error_mod.is_timeout({ code = "RequestTimeoutException" }))
end)

test("is_timeout: false for other", function()
    assert(not error_mod.is_timeout({ code = "Throttling" }))
end)

test("is_retryable: throttle is retryable", function()
    assert(error_mod.is_retryable({ code = "Throttling" }))
end)

test("is_retryable: transient is retryable", function()
    assert(error_mod.is_retryable({ type = "http", message = "fail" }))
end)

test("is_retryable: timeout is retryable", function()
    assert(error_mod.is_retryable({ code = "RequestTimeout" }))
end)

test("is_retryable: non-retryable", function()
    assert(not error_mod.is_retryable({ type = "api", code = "ValidationError", status_code = 400 }))
end)

print("\nAll tests passed.")
