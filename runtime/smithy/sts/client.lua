-- Minimal STS client for convergence testing.
-- Hand-written to match codegen output format.

local base_client = require("smithy.client")
local types = require("smithy.sts.types")

local M = {}

local Client = {}
Client.__index = Client
Client.invokeOperation = base_client.invokeOperation

function M.new(config)
    config.service_id = "STS"
    config.signing_name = "sts"
    return setmetatable(base_client.new(config), Client)
end

function Client:getCallerIdentity(input, options)
    return self:invokeOperation(input or {}, {
        name = "GetCallerIdentity",
        input_schema = types.GetCallerIdentityInput,
        output_schema = types.GetCallerIdentityOutput,
        http_method = "POST",
        http_path = "/",
    }, options)
end

return M
