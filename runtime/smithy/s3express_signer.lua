-- smithy-lua runtime: S3Express signer
-- SigV4 with x-amz-s3session-token header instead of X-Amz-Security-Token.

local signer = require("smithy.signer")

local M = {}

--- Sign a request using S3Express credentials.
--- Adds x-amz-s3session-token header and signs with SigV4, suppressing the
--- normal X-Amz-Security-Token header.
function M.sign(request, identity, props)
    -- Add the S3Express session token header
    request.headers = request.headers or {}
    request.headers["x-amz-s3session-token"] = identity.session_token

    -- Sign with SigV4 using a copy of identity without session_token
    -- (prevents signer from adding X-Amz-Security-Token)
    local signing_identity = {
        access_key = identity.access_key,
        secret_key = identity.secret_key,
    }
    return signer.sign(request, signing_identity, props)
end

return M
