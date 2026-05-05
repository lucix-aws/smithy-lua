-- smithy-lua runtime: default config resolvers

local record M
    resolve_auth_schemes: function(cfg: {string:any})
    resolve_identity_resolvers: function(cfg: {string:any})
    resolve_http_client: function(cfg: {string:any})
    resolve_retry_strategy: function(cfg: {string:any})
end

function M.resolve_auth_schemes(cfg: {string:any})
    if cfg.auth_schemes then return end
    local auth = require("smithy.auth")
    local signer = require("smithy.signer")
    cfg.auth_schemes = {
        [auth.SIGV4] = auth.new_auth_scheme(auth.SIGV4, "aws_credentials", signer.sign as auth.Signer),
        [auth.NO_AUTH] = auth.no_auth_scheme,
    }
end

function M.resolve_identity_resolvers(cfg: {string:any})
    if cfg.identity_resolvers then return end
    cfg.identity_resolvers = {}
end

function M.resolve_http_client(cfg: {string:any})
    if cfg.http_client then return end
    local http_client = require("smithy.http.client")
    cfg.http_client = http_client.resolve()
end

function M.resolve_retry_strategy(cfg: {string:any})
    if cfg.retry_strategy then return end
    local standard = require("smithy.retry.standard")
    local opts: standard.Options = {}
    if cfg.max_attempts then opts.max_attempts = cfg.max_attempts as integer end
    cfg.retry_strategy = standard.new(opts)
end

return M
