-- smithy-lua runtime: base client + invokeOperation pipeline
-- See INVOKE_OPERATION.md for the full contract.

local M = {}

local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

--- Create a new base client.
--- @param config table: locked fields per INVOKE_OPERATION.md
--- @return table: client with invokeOperation method
function M.new(config)
    return { config = config, invokeOperation = M.invokeOperation }
end

--- The SDK operation pipeline.
--- @param self table: client
--- @param input table: user input (modeled members)
--- @param operation table: static codegen operation metadata
--- @param options table|nil: { plugins = { fn, ... } }
--- @return table|nil, table|nil: output, err
function M.invokeOperation(self, input, operation, options)
    -- 1. Config resolution: copy + apply operation plugins
    local config = shallow_copy(self.config)
    if options and options.plugins then
        for _, plugin in ipairs(options.plugins) do
            plugin(config)
        end
    end

    -- [STUB] interceptors: readBeforeExecution
    -- [STUB] interceptors: modifyBeforeSerialization
    -- [STUB] interceptors: readBeforeSerialization

    -- 5. Serialize
    local request, err = config.protocol.serialize(input, operation)
    if err then return nil, err end

    -- [STUB] interceptors: readAfterSerialization
    -- [STUB] interceptors: modifyBeforeRetryLoop
    -- [STUB] retry_strategy:acquire_token()

    -- == begin attempt (single attempt, no retry loop yet) ==

    -- [STUB] interceptors: readBeforeAttempt
    -- [STUB] auth scheme resolution

    -- 9c. Resolve identity
    local identity
    identity, err = config.identity_resolver()
    if err then return nil, err end

    -- 9d. Resolve endpoint
    local endpoint
    endpoint, err = config.endpoint_provider({ region = config.region })
    if err then return nil, err end

    -- 9e. Apply endpoint to request
    request.url = endpoint.url .. request.url
    if endpoint.headers then
        for k, v in pairs(endpoint.headers) do
            request.headers[k] = v
        end
    end

    -- [STUB] interceptors: modifyBeforeSigning
    -- [STUB] interceptors: readBeforeSigning

    -- 9h. Sign
    request, err = config.signer(request, identity, {
        signing_name = config.signing_name,
        region = config.region,
    })
    if err then return nil, err end

    -- [STUB] interceptors: readAfterSigning
    -- [STUB] interceptors: modifyBeforeTransmit
    -- [STUB] interceptors: readBeforeTransmit

    -- 9l. Transmit
    local response
    response, err = config.http_client(request)
    if err then return nil, err end

    -- [STUB] interceptors: readAfterTransmit
    -- [STUB] interceptors: modifyBeforeDeserialization
    -- [STUB] interceptors: readBeforeDeserialization

    -- 9p. Deserialize
    local output
    output, err = config.protocol.deserialize(response, operation)

    -- [STUB] interceptors: readAfterDeserialization
    -- [STUB] interceptors: modifyBeforeAttemptCompletion
    -- [STUB] interceptors: readAfterAttempt

    -- == end attempt ==

    -- [STUB] retry classification
    -- [STUB] interceptors: modifyBeforeCompletion
    -- [STUB] interceptors: readAfterExecution

    return output, err
end

return M
