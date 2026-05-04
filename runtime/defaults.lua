-- smithy-lua runtime: default config resolvers.
-- Each resolver checks if a config field is set and fills in a default if not.
-- Generated client constructors call these after setting service-specific fields.

local M = {}

--- Resolve the default SigV4 signer.
function M.resolve_signer(cfg)
    if cfg.signer then return end
    local signer = require("signer")
    cfg.signer = signer.sign
end

--- Resolve the default HTTP client (auto-detect backend).
function M.resolve_http_client(cfg)
    if cfg.http_client then return end
    local http_client = require("http.client")
    cfg.http_client = http_client.resolve()
end

--- Resolve the default retry strategy (AWS standard retry).
function M.resolve_retry_strategy(cfg)
    if cfg.retry_strategy then return end
    local standard = require("retry.standard")
    local opts = {}
    if cfg.max_attempts then opts.max_attempts = cfg.max_attempts end
    cfg.retry_strategy = standard.new(opts)
end

return M
