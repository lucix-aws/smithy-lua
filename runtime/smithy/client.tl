-- smithy-lua runtime: base client + invokeOperation pipeline

local auth_mod = require("smithy.auth")
local interceptor_mod = require("smithy.interceptor")
local http_mod = require("smithy.http")

local record client_mod
    record Config
        protocol: any
        http_client: http_mod.HttpClient
        retry_strategy: any
        auth_scheme_resolver: function(any): {auth_mod.AuthOption}
        auth_schemes: {string:auth_mod.AuthScheme}
        identity_resolvers: {string:auth_mod.IdentityResolver}
        endpoint_provider: function({string:any}): auth_mod.Endpoint, string
        region: string
        use_fips: boolean
        use_dual_stack: boolean
        endpoint_url: string
        interceptors: {interceptor_mod.Interceptor}
        max_attempts: integer
    end

    record Client
        config: Config
    end

    record Operation
        name: string
        input_schema: any
        output_schema: any
        http_method: string
        http_path: string
        auth_schemes: {auth_mod.AuthOption}
        context_params: {string:string}
        event_stream: any
    end

    record Options
        plugins: {function(Config)}
    end
end

local function shallow_copy(t: {string:any}): {string:any}
    local out: {string:any} = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

function client_mod.new(config: client_mod.Config): client_mod.Client
    local c = { config = config } as client_mod.Client;
    (c as {string:any}).invokeOperation = client_mod.invokeOperation
    return c
end

local function do_attempt(config: {string:any}, input: any, request: http_mod.Request, operation: {string:any}, interceptors: {interceptor_mod.Interceptor}, ctx: interceptor_mod.Context): any, any
    ctx.request = request
    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_attempt", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req, err = interceptor_mod.run_modify(interceptors, "modify_before_signing", ctx, "request")
        if err then return nil, err end
        request = new_req as http_mod.Request
    end

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Resolve auth scheme
    local resolver = (config.auth_scheme_resolver as function(any): {auth_mod.AuthOption}) or auth_mod.default_auth_scheme_resolver
    local options = resolver(operation)

    local selected, sel_err = auth_mod.select_scheme(options, config.auth_schemes as {string:auth_mod.AuthScheme}, config.identity_resolvers as {string:auth_mod.IdentityResolver})
    if not selected then return nil, { type = "sdk", message = sel_err } end

    -- Resolve identity
    local identity: any
    local id_err: any
    identity, id_err = selected.identity_resolver()
    if id_err then return nil, id_err end

    -- Bind endpoint parameters
    local ep_params: {string:any} = {}
    if config.region then ep_params.Region = config.region end
    if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
    if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
    if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
    if operation.context_params then
        for param_name, input_field in pairs(operation.context_params as {string:string}) do
            ep_params[param_name] = (input as {string:any})[input_field]
        end
    end

    -- Resolve endpoint
    local ep_provider = config.endpoint_provider as function({string:any}): auth_mod.Endpoint, string
    local endpoint: auth_mod.Endpoint
    local ep_err: string
    endpoint, ep_err = ep_provider(ep_params)
    if ep_err then return nil, ep_err end

    -- Apply endpoint auth overrides
    local signer_props = shallow_copy(selected.signer_properties as {string:any})
    auth_mod.apply_endpoint_auth_overrides(endpoint, selected.scheme.scheme_id, signer_props as auth_mod.SignerProperties)

    -- Apply endpoint to request
    request.url = endpoint.url .. request._path
    if endpoint.headers then
        for k, v in pairs(endpoint.headers) do
            request.headers[k] = v[1]
        end
    end

    -- Sign
    local sign_err: any
    request, sign_err = selected.scheme.signer(request, identity, signer_props as auth_mod.SignerProperties)
    if sign_err then return nil, sign_err end
    ctx.request = request

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_after_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req: any
        local err: any
        new_req, err = interceptor_mod.run_modify(interceptors, "modify_before_transmit", ctx, "request")
        if err then return nil, err end
        request = new_req as http_mod.Request
    end

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Transmit
    local http_client = config.http_client as http_mod.HttpClient
    local response: http_mod.Response
    local tx_err: any
    response, tx_err = http_client(request)
    if tx_err then return nil, tx_err end
    ctx.response = response

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_after_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_resp: any
        local err: any
        new_resp, err = interceptor_mod.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
        if err then return nil, err end
        response = new_resp as http_mod.Response
    end

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_deserialization", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Deserialize
    local protocol = config.protocol as {string:any}
    local deser_fn = protocol.deserialize as function(any, http_mod.Response, {string:any}): any, any
    local output: any
    local deser_err: any
    output, deser_err = deser_fn(protocol, response, operation)
    ctx.output = output

    if interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_after_deserialization", ctx)
        if hook_err and not deser_err then deser_err = hook_err end
    end

    return output, deser_err
end

function client_mod.invokeOperation(self: client_mod.Client, input: any, operation: any, options: client_mod.Options): any, any
    local config = shallow_copy(self.config as {string:any})
    if options and options.plugins then
        for _, plugin in ipairs(options.plugins) do
            plugin(config as client_mod.Config)
        end
    end

    local interceptors = config.interceptors as {interceptor_mod.Interceptor}
    local has_interceptors = interceptors and #interceptors > 0

    local ctx: interceptor_mod.Context = { input = input, operation = operation }

    if has_interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_execution", ctx)
        if hook_err then return nil, hook_err end
    end

    if has_interceptors then
        local new_input, err = interceptor_mod.run_modify(interceptors, "modify_before_serialization", ctx, "input")
        if err then return nil, err end
        input = new_input
    end

    if has_interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_before_serialization", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Serialize
    local protocol = config.protocol as {string:any}
    local ser_fn = protocol.serialize as function(any, any, any): http_mod.Request, any
    local request: http_mod.Request
    local serialize_err: any
    request, serialize_err = ser_fn(protocol, input, operation)
    if serialize_err then return nil, serialize_err end
    ctx.request = request

    if has_interceptors then
        local hook_err = interceptor_mod.run_read(interceptors, "read_after_serialization", ctx)
        if hook_err then return nil, hook_err end
    end

    if has_interceptors then
        local new_req, err = interceptor_mod.run_modify(interceptors, "modify_before_retry_loop", ctx, "request")
        if err then return nil, err end
        request = new_req as http_mod.Request
    end

    request._path = request.url

    -- Retry loop
    local retryer = config.retry_strategy as {string:any}
    local result: any
    local attempt_err: any

    if not retryer then
        result, attempt_err = do_attempt(config, input, request, operation as {string:any}, has_interceptors and interceptors or nil, ctx)
        if has_interceptors then
            ctx.output = result
            result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
            attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
        end
    else
        local acquire_fn = retryer.acquire_token as function(any): any, any
        local token: any
        token, attempt_err = acquire_fn(retryer)
        if not attempt_err then
            while true do
                result, attempt_err = do_attempt(config, input, request, operation as {string:any}, has_interceptors and interceptors or nil, ctx)

                if has_interceptors then
                    ctx.output = result
                    result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
                    attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
                end

                if not attempt_err then
                    local success_fn = retryer.record_success as function(any, any)
                    success_fn(retryer, token)
                    break
                end

                local retry_fn = retryer.retry_token as function(any, any, any): number, any
                local delay: number
                delay, attempt_err = retry_fn(retryer, token, attempt_err)
                if not delay then break end

                if delay > 0 then
                    local socket_ok, socket = pcall(require, "socket") as (boolean, any)
                    if socket_ok and (socket as {string:any}).sleep then
                        local sleep_fn = (socket as {string:any}).sleep as function(number)
                        sleep_fn(delay)
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
        result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_completion", ctx, attempt_err)
    end

    -- read_after_execution
    if has_interceptors then
        attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_execution", ctx, attempt_err)
    end

    if attempt_err then return nil, attempt_err end
    return result, nil
end

return client_mod
