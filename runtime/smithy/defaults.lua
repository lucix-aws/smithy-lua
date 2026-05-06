-- smithy-lua runtime: default config resolvers.
-- Each resolver checks if a config field is set and fills in a default if not.
-- Generated client constructors call these after setting service-specific fields.

local M = {}

--- Resolve the default auth schemes (sigv4 + sigv4a + noAuth).
function M.resolve_auth_schemes(cfg)
    if cfg.auth_schemes then return end
    local auth = require("smithy.auth")
    local signer = require("smithy.signer")
    local sigv4a = require("smithy.sigv4a")
    cfg.auth_schemes = {
        [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", signer.sign),
        [auth.SIGV4A] = auth.new_auth_scheme(auth.SIGV4A, "aws_credentials", sigv4a.sign),
        [auth.NO_AUTH] = auth.no_auth_scheme,
    }
end

--- Resolve the default identity resolvers.
--- This is a no-op at the smithy-lua layer. The aws-sdk-lua layer provides
--- the default credential chain via its own config resolver integration.
function M.resolve_identity_resolvers(cfg)
    if cfg.identity_resolvers then return end
    cfg.identity_resolvers = {}
end

--- Resolve the default HTTP client (auto-detect backend).
function M.resolve_http_client(cfg)
    if cfg.http_client then return end
    local http_client = require("smithy.http.client")
    cfg.http_client = http_client.resolve()
end

--- Resolve the default retry strategy (AWS standard retry).
function M.resolve_retry_strategy(cfg)
    if cfg.retry_strategy then return end
    local standard = require("smithy.retry.standard")
    local opts = {}
    if cfg.max_attempts then opts.max_attempts = cfg.max_attempts end
    cfg.retry_strategy = standard.new(opts)
end

return M
