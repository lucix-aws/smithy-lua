-- smithy-lua runtime: error types, constructors, retry classification
-- See CONSTITUTION.md § Error Model

local M = {}

-- Error categories
M.API = "api"
M.HTTP = "http"
M.SDK = "sdk"

-- Throttling error codes returned by AWS services
local THROTTLE_CODES = {
    Throttling = true,
    ThrottlingException = true,
    ThrottledException = true,
    RequestThrottledException = true,
    TooManyRequestsException = true,
    ProvisionedThroughputExceededException = true,
    TransactionInProgressException = true,
    RequestLimitExceeded = true,
    BandwidthLimitExceeded = true,
    LimitExceededException = true,
    RequestThrottled = true,
    SlowDown = true,
    EC2ThrottledException = true,
}

-- Transient HTTP status codes
local TRANSIENT_STATUS = { [500] = true, [502] = true, [503] = true, [504] = true }

--- Create an API error (service returned an error response).
function M.new_api_error(code, message, status_code, extra)
    local err = {
        type = M.API,
        code = code,
        message = message,
        status_code = status_code,
    }
    if extra then
        for k, v in pairs(extra) do err[k] = v end
    end
    return err
end

--- Create an HTTP error (transport-level failure).
function M.new_http_error(message)
    return { type = M.HTTP, code = "HttpError", message = message }
end

--- Create an SDK error (client-side failure).
function M.new_sdk_error(code, message)
    return { type = M.SDK, code = code, message = message }
end

--- Is this a throttling error?
function M.is_throttle(err)
    if not err then return false end
    if err.status_code == 429 then return true end
    return THROTTLE_CODES[err.code] == true
end

--- Is this a transient error?
function M.is_transient(err)
    if not err then return false end
    if err.type == M.HTTP then return true end
    if err.status_code and TRANSIENT_STATUS[err.status_code] then return true end
    return false
end

--- Is this a timeout error?
function M.is_timeout(err)
    if not err then return false end
    return err.code == "RequestTimeout" or err.code == "RequestTimeoutException"
end

--- Is this error retryable?
function M.is_retryable(err)
    return M.is_throttle(err) or M.is_transient(err) or M.is_timeout(err)
end

return M
