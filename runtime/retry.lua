-- smithy-lua runtime: retryer interface
-- See CONSTITUTION.md § Retry Strategy
--
-- A retryer controls whether and when to retry failed attempts.
-- Interface:
--   acquire_token(self) -> token, err
--     Called before the retry loop. Returns a token or an error if
--     the client is circuit-broken.
--
--   retry_token(self, token, err) -> delay, err
--     Called after a failed attempt. Returns a delay (seconds) to wait
--     before retrying, or nil + err if the error is not retryable or
--     max attempts exhausted.
--
--   record_success(self, token)
--     Called after a successful attempt. Returns capacity to the bucket.

local M = {}

--- No-op retryer: single attempt, no retries.
function M.none()
    return {
        acquire_token = function() return {} end,
        retry_token = function(_, _, err) return nil, err end,
        record_success = function() end,
    }
end

return M
