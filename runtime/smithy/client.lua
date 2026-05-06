-- smithy-lua runtime: base client + invokeOperation pipeline
-- See INVOKE_OPERATION.md for the full contract.

local auth = require("smithy.auth")
local eventstream = require("smithy.eventstream")
local interceptor = require("smithy.interceptor")

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
local function do_attempt(config, input, request, operation, interceptors, ctx)
    -- read_before_attempt
    ctx.request = request
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_attempt", ctx)
        if hook_err then return nil, hook_err end
    end

    -- modify_before_signing
    if interceptors then
        local new_req, err = interceptor.run_modify(interceptors, "modify_before_signing", ctx, "request")
        if err then return nil, err end
        request = new_req
    end

    -- read_before_signing
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    -- 1. Resolve auth scheme
    local resolver = config.auth_scheme_resolver or auth.default_auth_scheme_resolver
    local options = resolver(operation, input)

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
    ctx.request = request

    -- read_after_signing
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    -- modify_before_transmit
    if interceptors then
        local new_req
        new_req, err = interceptor.run_modify(interceptors, "modify_before_transmit", ctx, "request")
        if err then return nil, err end
        request = new_req
    end

    -- read_before_transmit
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    -- 8. Transmit
    local response
    response, err = config.http_client(request)
    if err then return nil, err end
    ctx.response = response

    -- read_after_transmit
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    -- modify_before_deserialization
    if interceptors then
        local new_resp
        new_resp, err = interceptor.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
        if err then return nil, err end
        response = new_resp
    end

    -- read_before_deserialization
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_deserialization", ctx)
        if hook_err then return nil, hook_err end
    end

    -- 9. Deserialize
    if operation.event_stream then
        if response.status_code < 200 or response.status_code >= 300 then
            return config.protocol:deserialize(response, operation)
        end
        return response, nil
    end

    local output
    output, err = config.protocol:deserialize(response, operation)
    ctx.output = output

    -- read_after_deserialization
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_deserialization", ctx)
        if hook_err and not err then err = hook_err end
    end

    return output, err
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

    local interceptors = config.interceptors
    local has_interceptors = interceptors and #interceptors > 0

    -- Build the interceptor context table
    local ctx = { input = input, operation = operation }

    -- read_before_execution
    if has_interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_execution", ctx)
        if hook_err then
            -- Jump to modify_before_completion
            ctx.output = nil
            local output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, hook_err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
    end

    -- modify_before_serialization
    if has_interceptors then
        local new_input, err = interceptor.run_modify(interceptors, "modify_before_serialization", ctx, "input")
        if err then
            ctx.output = nil
            local output
            output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
        input = new_input
    end

    -- read_before_serialization
    if has_interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_serialization", ctx)
        if hook_err then
            ctx.output = nil
            local output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, hook_err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
    end

    -- 5. Serialize
    local request, serialize_err = config.protocol:serialize(input, operation)
    if serialize_err then
        if not has_interceptors then return nil, serialize_err end
        ctx.output = nil
        local output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, serialize_err)
        err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
        if err then return nil, err end
        return output, nil
    end
    ctx.request = request

    -- read_after_serialization
    if has_interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_serialization", ctx)
        if hook_err then
            ctx.output = nil
            local output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, hook_err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
    end

    -- modify_before_retry_loop
    if has_interceptors then
        local new_req, err = interceptor.run_modify(interceptors, "modify_before_retry_loop", ctx, "request")
        if err then
            ctx.output = nil
            local output
            output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
        request = new_req
    end

    -- Stash the original path so we can rebuild the URL on each attempt
    request._path = request.url

    -- 8. Retry loop
    local retryer = config.retry_strategy
    local result, attempt_err

    if not retryer then
        result, attempt_err = do_attempt(config, input, request, operation,
            has_interceptors and interceptors or nil, ctx)

        -- modify_before_attempt_completion + read_after_attempt
        if has_interceptors then
            ctx.output = result
            result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
            attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
        end
    else
        local token
        token, attempt_err = retryer:acquire_token()
        if not attempt_err then
            while true do
                result, attempt_err = do_attempt(config, input, request, operation,
                    has_interceptors and interceptors or nil, ctx)

                -- modify_before_attempt_completion + read_after_attempt
                if has_interceptors then
                    ctx.output = result
                    result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
                    attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
                end

                if not attempt_err then
                    retryer:record_success(token)
                    break
                end

                local delay
                delay, attempt_err = retryer:retry_token(token, attempt_err)
                if not delay then
                    break
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
    end

    -- modify_before_completion
    if has_interceptors then
        ctx.output = result
        result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, attempt_err)
    end

    -- read_after_execution
    if has_interceptors then
        attempt_err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, attempt_err)
    end

    if attempt_err then return nil, attempt_err end

    -- For event stream operations, wrap the response in a stream object
    if operation.event_stream then
        local protocol = config.protocol
        local stream = eventstream.new_stream(
            result.body,
            operation.event_stream,
            protocol.codec,
            {
                has_initial_message = protocol.has_event_stream_initial_message,
                output_schema = operation.output_schema,
                on_close = result.close,
            }
        )
        return stream, nil
    end

    return result, nil
end

return M
