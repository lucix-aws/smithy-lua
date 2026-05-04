-- smithy-lua runtime: auth scheme interfaces
-- See CONSTITUTION.md § Credential Resolution / Abstractions

local M = {}

--- Auth scheme IDs
M.SIGV4 = "aws.auth#sigv4"

--- Create a credentials identity (SigV4).
function M.new_credentials(access_key, secret_key, session_token, expiration)
    return {
        access_key = access_key,
        secret_key = secret_key,
        session_token = session_token,
        expiration = expiration,
    }
end

--- Create an auth scheme.
function M.new_auth_scheme(scheme_id, identity_resolver, signer)
    return {
        scheme_id = scheme_id,
        identity_resolver = identity_resolver,
        signer = signer,
    }
end

return M
