-- smithy-lua runtime: error types, constructors, retry classification

local record error_mod
    record Error
        type: string
        code: string
        message: string
        status_code: integer
    end

    API: string
    HTTP: string
    SDK: string
end

error_mod.API = "api"
error_mod.HTTP = "http"
error_mod.SDK = "sdk"

local THROTTLE_CODES: {string:boolean} = {
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

local TRANSIENT_STATUS: {integer:boolean} = { [500] = true, [502] = true, [503] = true, [504] = true }

function error_mod.new_api_error(code: string, message: string, status_code: integer, extra: {string:any}): error_mod.Error
    local err: error_mod.Error = {
        type = error_mod.API,
        code = code,
        message = message,
        status_code = status_code,
    }
    if extra then
        for k, v in pairs(extra) do (err as {string:any})[k] = v end
    end
    return err
end

function error_mod.new_http_error(message: string): error_mod.Error
    return { type = error_mod.HTTP, code = "HttpError", message = message }
end

function error_mod.new_sdk_error(code: string, message: string): error_mod.Error
    return { type = error_mod.SDK, code = code, message = message }
end

function error_mod.is_throttle(err: error_mod.Error): boolean
    if not err then return false end
    if err.status_code == 429 then return true end
    return THROTTLE_CODES[err.code] == true
end

function error_mod.is_transient(err: error_mod.Error): boolean
    if not err then return false end
    if err.type == error_mod.HTTP then return true end
    if err.status_code and TRANSIENT_STATUS[err.status_code] then return true end
    return false
end

function error_mod.is_timeout(err: error_mod.Error): boolean
    if not err then return false end
    return err.code == "RequestTimeout" or err.code == "RequestTimeoutException"
end

function error_mod.is_retryable(err: error_mod.Error): boolean
    return error_mod.is_throttle(err) or error_mod.is_transient(err) or error_mod.is_timeout(err)
end

return error_mod
