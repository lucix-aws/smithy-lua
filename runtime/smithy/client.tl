-- smithy-lua runtime: base client + invokeOperation pipeline

local async = require("smithy.async")
local auth = require("smithy.auth")
local endpoint_mod = require("smithy.endpoint")
local eventstream = require("smithy.eventstream")
local eventstream_signer = require("smithy.eventstream_signer")
local http = require("smithy.http")
local interceptor = require("smithy.interceptor")
local protocol_mod = require("smithy.protocol")
local retry_mod = require("smithy.retry")
local schema = require("smithy.schema")
local traits = require("smithy.traits")

local record M
    record ClientConfig
        protocol: protocol_mod.ClientProtocol
        http_client: http.HttpClient
        retry_strategy: retry_mod.RetryStrategy
        auth_schemes: {string:auth.AuthScheme}
        identity_resolvers: {string:function}
        auth_scheme_resolver: function(schema.ServiceSchema, schema.OperationSchema, {string:any}): {auth.AuthOption}
        endpoint_provider: function({string:any}): endpoint_mod.Endpoint, string
        interceptors: {any}
        region: string
        use_fips: boolean
        use_dual_stack: boolean
        endpoint_url: string
        disable_s3_express_session_auth: boolean
        max_attempts: number
        service_id: string
    end

    record Client
        config: ClientConfig
        invokeOperation: function(Client, schema.ServiceSchema, schema.OperationSchema, {string:any}, InvokeOptions): async.Operation<any>
    end

    record InvokeOptions
        plugins: {function(ClientConfig)}
    end

    new: function(config: ClientConfig): Client
    invokeOperation: function(self: Client, service: schema.ServiceSchema, operation: schema.OperationSchema, input: {string:any}, options: InvokeOptions): async.Operation<any>
    _doInvoke: function(self: Client, service: schema.ServiceSchema, operation: schema.OperationSchema, input: {string:any}, options: InvokeOptions): any, any
end

local function shallow_copy(t: M.ClientConfig): M.ClientConfig
    local out = {} as M.ClientConfig
    for k, v in pairs(t as {string:any}) do
        (out as {string:any})[k] = v
    end
    return out
end

local function find_input_event_stream(operation: schema.OperationSchema): string, schema.Schema
    local input_schema = operation.input
    if not input_schema then return nil, nil end
    local members = input_schema:members()
    if not members then return nil, nil end
    for name, ms in pairs(members) do
        if ms:trait(traits.STREAMING) and ms.type == "union" then
            return name, ms
        end
    end
    return nil, nil
end

local function extract_signature(auth_header: string): string
    return auth_header and auth_header:match("Signature=(%x+)")
end

function M.new(config: M.ClientConfig): M.Client
    local c: M.Client = {
        config = config,
        invokeOperation = M.invokeOperation,
    }
    return c
end

local function do_attempt(config: M.ClientConfig, service: schema.ServiceSchema, operation: schema.OperationSchema, input: {string:any}, request: http.Request, interceptors: {any}, ctx: {string:any}): any, any
    ctx.request = request
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_attempt", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req, err = interceptor.run_modify(interceptors, "modify_before_signing", ctx, "request")
        if err then return nil, err end
        request = new_req as http.Request
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Resolve auth scheme
    local resolver = (config.auth_scheme_resolver or auth.default_auth_scheme_resolver) as function(schema.ServiceSchema, schema.OperationSchema, {string:any}): {auth.AuthOption}
    local options = resolver(service, operation, input)

    local selected: auth.AuthSelection
    local sel_err: string
    selected, sel_err = auth.select_scheme(options, config.auth_schemes, config.identity_resolvers)
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
    if config.disable_s3_express_session_auth then
        ep_params.DisableS3ExpressSessionAuth = true
    end

    local static_ctx = operation:trait(traits.STATIC_CONTEXT_PARAMS) as {string:{string:any}}
    if static_ctx then
        for param_name, param_def in pairs(static_ctx) do
            ep_params[param_name] = param_def.value
        end
    end
    local ctx_params = operation:trait(traits.CONTEXT_PARAMS) as {string:string}
    if ctx_params then
        for param_name, input_field in pairs(ctx_params) do
            ep_params[param_name] = input[input_field]
        end
    end

    -- Resolve endpoint
    local ep: endpoint_mod.Endpoint
    local ep_err: string
    ep, ep_err = config.endpoint_provider(ep_params)
    if ep_err then return nil, { type = "sdk", message = ep_err } end

    -- Apply endpoint auth scheme overrides
    local signer_props: {string:any} = {}
    for k, v in pairs(selected.signer_properties) do
        signer_props[k] = v
    end
    auth.apply_endpoint_auth_overrides(ep as {string:any}, selected.scheme.scheme_id, signer_props)

    -- Apply endpoint to request
    request.url = ep.url .. ((request as {string:any})._path as string)
    if ep.headers then
        for k, vals in pairs(ep.headers) do
            request.headers[k] = vals[1]
        end
    end

    -- Sign
    local input_es_name = find_input_event_stream(operation)
    if input_es_name then
        request.headers["X-Amz-Content-Sha256"] = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
        request.headers["Transfer-Encoding"] = "chunked"
        request.headers["Content-Type"] = "application/vnd.amazon.eventstream"
    end

    local signed_req: any
    local sign_err: any
    signed_req, sign_err = selected.scheme.signer(request, identity, signer_props)
    if sign_err then return nil, sign_err end
    request = signed_req as http.Request

    -- For input event streams: set up the signing writer
    local signing_writer: any
    if input_es_name then
        local seed = extract_signature(request.headers["Authorization"])
        if not seed then
            return nil, { type = "sdk", message = "failed to extract signature for event stream signing" }
        end
        local es_signer = eventstream_signer.new(
            identity as eventstream_signer.Identity,
            signer_props as eventstream_signer.Props,
            seed
        )
        local new_sw = (eventstream as {string:any}).new_signing_writer as function(any): any
        signing_writer = new_sw(es_signer)
        request.body = (signing_writer as {string:any}).body_reader as http.Reader
        (request as {string:any}).streaming = true
    end

    ctx.request = request

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req, mod_err = interceptor.run_modify(interceptors, "modify_before_transmit", ctx, "request")
        if mod_err then return nil, mod_err end
        request = new_req as http.Request
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Transmit
    local response: http.Response
    local tx_err: any
    local tx_op = config.http_client:roundtrip(request)
    response, tx_err = tx_op:await()
    if tx_err then return nil, tx_err end
    ctx.response = response

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_resp, mod_err = interceptor.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
        if mod_err then return nil, mod_err end
        response = new_resp as http.Response
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_deserialization", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Deserialize
    local es = operation:trait(traits.EVENT_STREAM)
    if es then
        if response.status_code < 200 or response.status_code >= 300 then
            return config.protocol:deserialize(response, operation)
        end
        local resp_tbl = response as {string:any}
        resp_tbl._signing_writer = signing_writer
        resp_tbl._input_event_stream = input_es_name
        return response, nil
    end

    local output: {string:any}
    local deser_err: http.Error
    output, deser_err = config.protocol:deserialize(response, operation)
    ctx.output = output

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_deserialization", ctx)
        if hook_err and not deser_err then return output, hook_err end
    end

    return output, deser_err
end

function M.invokeOperation(self: M.Client, service: schema.ServiceSchema, operation: schema.OperationSchema, input: {string:any}, options: M.InvokeOptions): async.Operation<any>
    local op: async.Operation<any> = async.new_operation()
    local result, err = M._doInvoke(self, service, operation, input, options)
    op:resolve(result, err)
    return op
end

function M._doInvoke(self: M.Client, service: schema.ServiceSchema, operation: schema.OperationSchema, input: {string:any}, options: M.InvokeOptions): any, any
    local config = shallow_copy(self.config)
    if options then
        if options.plugins then
            for _, plugin in ipairs(options.plugins) do
                plugin(config)
            end
        end
    end

    local interceptors = config.interceptors
    local has_interceptors = interceptors and #interceptors > 0

    local ctx: {string:any} = { input = input, operation = operation }

    -- read_before_execution
    if has_interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_execution", ctx)
        if hook_err then
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
            local output: any
            output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
        input = new_input as {string:any}
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

    -- Serialize
    local request: http.Request
    local serialize_err: http.Error
    request, serialize_err = config.protocol:serialize(input or {}, service, operation)
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
            local output: any
            output, err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, err)
            err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, err)
            if err then return nil, err end
            return output, nil
        end
        request = new_req as http.Request
    end

    -- Stash original path
    (request as {string:any})._path = request.url

    -- Retry loop
    local retryer = config.retry_strategy
    local result: any
    local attempt_err: any

    if not retryer then
        result, attempt_err = do_attempt(config, service, operation, input, request,
            has_interceptors and interceptors or nil, ctx)

        if has_interceptors then
            ctx.output = result
            result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
            attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
        end
    else
        local token: retry_mod.RetryToken
        local acq_err: any
        token, acq_err = retryer:acquire_token()
        if acq_err then
            attempt_err = acq_err
        else
            while true do
                result, attempt_err = do_attempt(config, service, operation, input, request,
                    has_interceptors and interceptors or nil, ctx)

                if has_interceptors then
                    ctx.output = result
                    result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
                    attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
                end

                if not attempt_err then
                    retryer:record_success(token)
                    break
                end

                local delay: number
                delay, attempt_err = retryer:retry_token(token, attempt_err)
                if not delay then
                    break
                end

                if delay > 0 then
                    local req_fn = require as function(string): any
                    local socket_ok, socket = pcall(req_fn, "socket") as (boolean, any)
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
        result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, attempt_err)
    end

    -- read_after_execution
    if has_interceptors then
        attempt_err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, attempt_err)
    end

    if attempt_err then return nil, attempt_err end

    -- For event stream operations, wrap the response in a stream object
    local es = operation:trait(traits.EVENT_STREAM)
    if es then
        local result_tbl = result as {string:any}
        local stream_opts: {string:any} = {
            has_initial_message = config.protocol.has_event_stream_initial_message,
            output_schema = operation.output,
            on_close = result_tbl.close,
        }
        local es_mod = eventstream as {string:any}
        local body_fn = result_tbl.body as function(): string
        local stream: any = (es_mod.new_stream as function(any, any, any, any): any)(body_fn, es, config.protocol.codec, stream_opts)

        -- For bidirectional streams, add send capability
        if result_tbl._signing_writer then
            local sw = result_tbl._signing_writer as {string:any}
            local input_es_name = result_tbl._input_event_stream as string
            local input_members = operation.input:members()
            local es_member = input_members[input_es_name]
            local input_es_schema = es_member._target or es_member

            local stream_tbl = stream as {string:any}
            local serialize_event = (eventstream as {string:any}).serialize_event as function(any, any, any): string, string
            stream_tbl.send = function(_self_stream: any, event: any): any, any
                local frame, err = serialize_event(event, input_es_schema, config.protocol.codec)
                if err then return nil, { type = "sdk", message = err } end
                local write_fn = sw.write as function(any, string): boolean, string
                return write_fn(sw, frame)
            end

            stream_tbl.close_input = function(_self_stream: any)
                local close_fn = sw.close as function(any)
                close_fn(sw)
            end
        end

        return stream, nil
    end

    return result, nil
end

return M
