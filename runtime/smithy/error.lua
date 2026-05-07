

local M = { Error = {} }












M.API = "api"
M.HTTP = "http"
M.SDK = "sdk"

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

local TRANSIENT_STATUS = { [500] = true, [502] = true, [503] = true, [504] = true }

function M.new_api_error(code, message, status_code, extra)
   local err = {
      type = M.API,
      code = code,
      message = message,
      status_code = status_code,
   }
   if extra then
      for k, v in pairs(extra) do (err)[k] = v end
   end
   return err
end

function M.new_http_error(message)
   return { type = M.HTTP, code = "HttpError", message = message }
end

function M.new_sdk_error(code, message)
   return { type = M.SDK, code = code, message = message }
end

function M.is_throttle(err)
   if not err then return false end
   if err.status_code == 429 then return true end
   return THROTTLE_CODES[err.code] == true
end

function M.is_transient(err)
   if not err then return false end
   if err.type == M.HTTP then return true end
   if err.status_code and TRANSIENT_STATUS[err.status_code] then return true end
   return false
end

function M.is_timeout(err)
   if not err then return false end
   return err.code == "RequestTimeout" or err.code == "RequestTimeoutException"
end

function M.is_retryable(err)
   return M.is_throttle(err) or M.is_transient(err) or M.is_timeout(err)
end

return M
