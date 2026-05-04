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

--- Execute a single attempt (identity → endpoint → sign → send → deserialize).
--- Returns output, err. The request is mutated (endpoint applied).
local function do_attempt(config, request, operation)
    -- Resolve identity
    local identity, err = config.identity_resolver()
    if err then return nil, err end

    -- Resolve endpoint
    local endpoint
    endpoint, err = config.endpoint_provider({ region = config.region })
    if err then return nil, err end

    -- Apply endpoint to request (build full URL for this attempt)
    request.url = endpoint.url .. request._path
    if endpoint.headers then
        for k, v in pairs(endpoint.headers) do
            request.headers[k] = v
        end
    end

    -- Sign
    request, err = config.signer(request, identity, {
        signing_name = config.signing_name,
        region = config.region,
    })
    if err then return nil, err end

    -- Transmit
    local response
    response, err = config.http_client(request)
    if err then return nil, err end

    -- Deserialize
    return config.protocol:deserialize(response, operation)
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

    -- 5. Serialize
    local request, err = config.protocol:serialize(input, operation)
    if err then return nil, err end

    -- Stash the original path so we can rebuild the URL on each attempt
    request._path = request.url

    -- 8. Retry loop
    local retryer = config.retry_strategy
    if not retryer then
        -- No retry strategy: single attempt
        local output
        output, err = do_attempt(config, request, operation)
        return output, err
    end

    local token
    token, err = retryer:acquire_token()
    if err then return nil, err end

    local output
    while true do
        output, err = do_attempt(config, request, operation)

        if not err then
            retryer:record_success(token)
            return output, nil
        end

        -- Attempt failed — ask retryer if we should retry
        local delay
        delay, err = retryer:retry_token(token, err)
        if not delay then
            -- Not retryable or max attempts exhausted
            return nil, err
        end

        -- Wait before next attempt
        if delay > 0 then
            local socket_ok, socket = pcall(require, "socket")
            if socket_ok and socket.sleep then
                socket.sleep(delay)
            else
                -- Fallback: busy-wait (only for environments without socket)
                local target = os.clock() + delay
                while os.clock() < target do end
            end
        end
    end
end

return M
