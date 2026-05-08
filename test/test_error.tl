local assert = require("luassert") as any
-- Test: runtime/error.lua

local error_mod = require("smithy.error")

describe("error", function()
    -- === Constructor tests ===

    it("new_api_error", function()
        local err = error_mod.new_api_error("NoSuchBucket", "not found", 404)
        assert.are.equal("api", err.type)
        assert.are.equal("NoSuchBucket", err.code)
        assert.are.equal("not found", err.message)
        assert.are.equal(404, err.status_code)
    end)

    it("new_api_error with extra fields", function()
        local err = error_mod.new_api_error("InvalidObjectState", "bad", 409, { StorageClass = "GLACIER" })
        assert.are.equal("GLACIER", (err as {string:any}).StorageClass)
        assert.are.equal("InvalidObjectState", err.code)
    end)

    it("new_http_error", function()
        local err = error_mod.new_http_error("connection refused")
        assert.are.equal("http", err.type)
        assert.are.equal("HttpError", err.code)
        assert.are.equal("connection refused", err.message)
    end)

    it("new_sdk_error", function()
        local err = error_mod.new_sdk_error("SerializationError", "bad input")
        assert.are.equal("sdk", err.type)
        assert.are.equal("SerializationError", err.code)
    end)

    -- === Classification tests ===

    it("is_throttle: 429 status", function()
        assert(error_mod.is_throttle({ status_code = 429 }))
    end)

    it("is_throttle: Throttling code", function()
        assert(error_mod.is_throttle({ code = "Throttling" }))
    end)

    it("is_throttle: TooManyRequestsException", function()
        assert(error_mod.is_throttle({ code = "TooManyRequestsException" }))
    end)

    it("is_throttle: SlowDown", function()
        assert(error_mod.is_throttle({ code = "SlowDown" }))
    end)

    it("is_throttle: false for normal error", function()
        assert(not error_mod.is_throttle({ code = "NoSuchBucket", status_code = 404 }))
    end)

    it("is_throttle: nil safe", function()
        assert(not error_mod.is_throttle(nil))
    end)

    it("is_transient: HTTP error type", function()
        assert(error_mod.is_transient({ type = "http", message = "timeout" }))
    end)

    it("is_transient: 500", function()
        assert(error_mod.is_transient({ type = "api", status_code = 500 }))
    end)

    it("is_transient: 503", function()
        assert(error_mod.is_transient({ type = "api", status_code = 503 }))
    end)

    it("is_transient: false for 400", function()
        assert(not error_mod.is_transient({ type = "api", status_code = 400 }))
    end)

    it("is_timeout: RequestTimeout", function()
        assert(error_mod.is_timeout({ code = "RequestTimeout" }))
    end)

    it("is_timeout: RequestTimeoutException", function()
        assert(error_mod.is_timeout({ code = "RequestTimeoutException" }))
    end)

    it("is_timeout: false for other", function()
        assert(not error_mod.is_timeout({ code = "Throttling" }))
    end)

    it("is_retryable: throttle is retryable", function()
        assert(error_mod.is_retryable({ code = "Throttling" }))
    end)

    it("is_retryable: transient is retryable", function()
        assert(error_mod.is_retryable({ type = "http", message = "fail" }))
    end)

    it("is_retryable: timeout is retryable", function()
        assert(error_mod.is_retryable({ code = "RequestTimeout" }))
    end)

    it("is_retryable: non-retryable", function()
        assert(not error_mod.is_retryable({ type = "api", code = "ValidationError", status_code = 400 }))
    end)
end)
