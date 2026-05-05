-- smithy-lua runtime: base client + invokeOperation pipeline
-- See INVOKE_OPERATION.md for the full contract.

local auth = require("smithy.auth")
local eventstream = require("smithy.eventstream")

local M = {}

local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

--- Create a new base client.
function M.new(config)
    return { config = config, invokeOperation = M.invokeOperation }
end

--- Execute a single attempt.
--- Auth resolution → endpoint → apply endpoint auth overrides → sign → send → deserialize.
local function do_attempt(config, input, request, operation)
    -- 1. Resolve auth scheme
    local resolver = config.auth_scheme_resolver or auth.default_auth_scheme_resolver
    local options = resolver(operation)

    local selected, err = auth.select_scheme(options, config.auth_schemes, config.identity_resolvers)
    if not selected then return nil, { type = "sdk", message = err } end

    -- 2. Resolve identity
    local identity
    identity, err = selected.identity_resolver()
    if err then return nil, err end

    -- 3. Bind endpoint parameters
    local ep_params = {}
    if config.region then ep_params.Region = config.region end
    if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
    if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
    if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
    if operation.context_params then
        for param_name, input_field in pairs(operation.context_params) do
            ep_params[param_name] = input[input_field]
        end
    end

    -- 4. Resolve endpoint
    local endpoint
    endpoint, err = config.endpoint_provider(ep_params)
    if err then return nil, err end

    -- 5. Apply endpoint auth scheme overrides to signer properties
    local signer_props = shallow_copy(selected.signer_properties)
    auth.apply_endpoint_auth_overrides(endpoint, selected.scheme.scheme_id, signer_props)

    -- 6. Apply endpoint to request
    request.url = endpoint.url .. request._path
    if endpoint.headers then
        for k, v in pairs(endpoint.headers) do
            request.headers[k] = v
        end
    end

    -- 7. Sign
    request, err = selected.scheme.signer(request, identity, signer_props)
    if err then return nil, err end

    -- 8. Transmit
    local response
    response, err = config.http_client(request)
    if err then return nil, err end

    -- 9. Deserialize
    -- For event stream operations, check for HTTP-level errors but don't
    -- consume the body — it will be read as a stream.
    if operation.event_stream then
        if response.status_code < 200 or response.status_code >= 300 then
            -- Operation-level error: deserialize normally
            return config.protocol:deserialize(response, operation)
        end
        -- Success: return the raw response for stream wrapping
        return response, nil
    end

    return config.protocol:deserialize(response, operation)
end

--- The SDK operation pipeline.
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
    local result

    if not retryer then
        result, err = do_attempt(config, input, request, operation)
    else
        local token
        token, err = retryer:acquire_token()
        if err then return nil, err end

        while true do
            result, err = do_attempt(config, input, request, operation)

            if not err then
                retryer:record_success(token)
                break
            end

            local delay
            delay, err = retryer:retry_token(token, err)
            if not delay then
                return nil, err
            end

            if delay > 0 then
                local socket_ok, socket = pcall(require, "socket")
                if socket_ok and socket.sleep then
                    socket.sleep(delay)
                else
                    local target = os.clock() + delay
                    while os.clock() < target do end
                end
            end
        end
    end

    if err then return nil, err end

    -- For event stream operations, wrap the response in a stream object
    if operation.event_stream then
        local protocol = config.protocol
        local stream = eventstream.new_stream(
            result.body,  -- response body reader
            operation.event_stream,  -- the streaming union schema
            protocol.codec,
            {
                has_initial_message = protocol.has_event_stream_initial_message,
                output_schema = operation.output_schema,
                on_close = result.close,
            }
        )
        -- For REST protocols, the initial response is in HTTP headers/body
        -- which was already deserialized. For RPC protocols, it's in the stream.
        -- Either way, return the stream as the result.
        return stream, nil
    end

    return result, nil
end

return M
