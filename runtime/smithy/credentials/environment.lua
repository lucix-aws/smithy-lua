-- Environment variable credential provider.
-- Reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN.
-- Returns: function() -> identity, err

local auth = require("smithy.auth")

local M = {}

--- Create an identity resolver that reads credentials from environment variables.
function M.new()
    return function()
        local ak = os.getenv("AWS_ACCESS_KEY_ID")
        local sk = os.getenv("AWS_SECRET_ACCESS_KEY")
        if not ak or not sk then
            return nil, { type = "sdk", code = "NoCredentials",
                message = "AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must be set" }
        end
        return auth.new_credentials(ak, sk, os.getenv("AWS_SESSION_TOKEN")), nil
    end
end

return M
