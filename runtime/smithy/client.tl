-- smithy-lua runtime: base client + invokeOperation pipeline

local async = require("smithy.async")
local auth = require("smithy.auth")
local eventstream = require("smithy.eventstream")
local eventstream_signer = require("smithy.eventstream_signer")
local http = require("smithy.http")
local interceptor = require("smithy.interceptor")
local traits = require("smithy.traits")

local record M
    new: function(config: {string:any}): {string:any}
    invokeOperation: function(self: any, service: any, operation: any, input: any, options: any): any, any
end

local function shallow_copy(t: {string:any}): {string:any}
    local out: {string:any} = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function find_input_event_stream(operation: any): string, any
    local op = operation as {string:any}
    local input_schema = op.input as any
    if not input_schema then return nil, nil end
    local members_fn = (input_schema as {string:any}).members as function(any): {string:any}
    if not members_fn then return nil, nil end
    local members = members_fn(input_schema)
    if not members then return nil, nil end
    for name, ms in pairs(members) do
        local schema = ms as {string:any}
        local trait_fn = schema.trait as function(any, any): any
        if trait_fn and trait_fn(ms, traits.STREAMING) and schema.type == "union" then
            return name, ms
        end
    end
    return nil, nil
end

local function extract_signature(auth_header: string): string
    return auth_header and auth_header:match("Signature=(%x+)")
end

function M.new(config: {string:any}): {string:any}
    return { config = config, invokeOperation = M.invokeOperation }
end

local function do_attempt(config: {string:any}, service: any, operation: any, input: any, request: {string:any}, interceptors: {any}, ctx: {string:any}): any, any
    ctx.request = request
    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_attempt", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req, err = interceptor.run_modify(interceptors, "modify_before_signing", ctx, "request")
        if err then return nil, err end
        request = new_req as {string:any}
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Resolve auth scheme
    local resolver = (config.auth_scheme_resolver or auth.default_auth_scheme_resolver) as function(any, any, any): {any}
    local options = resolver(service, operation, input)

    local selected: auth.AuthSelection
    local sel_err: string
    selected, sel_err = auth.select_scheme(options as {auth.AuthOption}, config.auth_schemes as {string:auth.AuthScheme}, config.identity_resolvers as {string:function})
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

    local op = operation as {string:any}
    local trait_fn = op.trait as function(any, any): any
    local static_ctx = trait_fn(operation, traits.STATIC_CONTEXT_PARAMS) as {string:{string:any}}
    if static_ctx then
        for param_name, param_def in pairs(static_ctx) do
            ep_params[param_name] = param_def.value
        end
    end
    local ctx_params = trait_fn(operation, traits.CONTEXT_PARAMS) as {string:string}
    if ctx_params then
        local inp = input as {string:any}
        for param_name, input_field in pairs(ctx_params) do
            ep_params[param_name] = inp[input_field]
        end
    end

    -- Resolve endpoint
    local ep_fn = config.endpoint_provider as function({string:any}): any, any
    local endpoint: any
    local ep_err: any
    endpoint, ep_err = ep_fn(ep_params)
    if ep_err then return nil, ep_err end

    -- Apply endpoint auth scheme overrides
    local signer_props = shallow_copy(selected.signer_properties as {string:any})
    auth.apply_endpoint_auth_overrides(endpoint as {string:any}, selected.scheme.scheme_id, signer_props)

    -- Apply endpoint to request
    local ep_tbl = endpoint as {string:any}
    request.url = (ep_tbl.url as string) .. (request._path as string)
    local ep_headers = ep_tbl.headers as {string:string}
    if ep_headers then
        local req_headers = request.headers as {string:string}
        for k, v in pairs(ep_headers) do
            req_headers[k] = v
        end
    end

    -- Sign
    local input_es_name = find_input_event_stream(operation)
    if input_es_name then
        local req_headers = request.headers as {string:string}
        req_headers["X-Amz-Content-Sha256"] = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
        req_headers["Transfer-Encoding"] = "chunked"
        req_headers["Content-Type"] = "application/vnd.amazon.eventstream"
    end

    local sign_fn = selected.scheme.signer
    local signed_req: any
    local sign_err: any
    signed_req, sign_err = sign_fn(request, identity, signer_props)
    if sign_err then return nil, sign_err end
    request = signed_req as {string:any}

    -- For input event streams: set up the signing writer
    local signing_writer: any
    if input_es_name then
        local req_headers = request.headers as {string:string}
        local seed = extract_signature(req_headers["Authorization"])
        if not seed then
            return nil, { type = "sdk", message = "failed to extract signature for event stream signing" }
        end
        local es_signer_mod = eventstream_signer as {string:any}
        local es_new = es_signer_mod.new as function(any, any, string): any
        local es_signer = es_new(identity, signer_props, seed)
        local es_mod = eventstream as {string:any}
        local new_sw = es_mod.new_signing_writer as function(any): any
        signing_writer = new_sw(es_signer)
        local sw = signing_writer as {string:any}
        request.body = sw.body_reader
        request.streaming = true
    end

    ctx.request = request

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_signing", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_req: any
        local mod_err: any
        new_req, mod_err = interceptor.run_modify(interceptors, "modify_before_transmit", ctx, "request")
        if mod_err then return nil, mod_err end
        request = new_req as {string:any}
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Transmit
    local http_client = config.http_client as http.HttpClient
    local response: any
    local tx_err: any
    local tx_op = http_client:roundtrip(request as http.Request)
    response, tx_err = tx_op:await()
    if tx_err then return nil, tx_err end
    ctx.response = response

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_transmit", ctx)
        if hook_err then return nil, hook_err end
    end

    if interceptors then
        local new_resp: any
        local mod_err: any
        new_resp, mod_err = interceptor.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
        if mod_err then return nil, mod_err end
        response = new_resp
    end

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_before_deserialization", ctx)
        if hook_err then return nil, hook_err end
    end

    -- Deserialize
    local es = trait_fn(operation, traits.EVENT_STREAM)
    if es then
        local resp = response as {string:any}
        local status = resp.status_code as integer
        if status < 200 or status >= 300 then
            local proto = config.protocol as {string:any}
            local deser = proto.deserialize as function(any, any, any): any, any
            return deser(config.protocol, response, operation)
        end
        resp._signing_writer = signing_writer
        resp._input_event_stream = input_es_name
        return response, nil
    end

    local proto = config.protocol as {string:any}
    local deser = proto.deserialize as function(any, any, any): any, any
    local output: any
    local deser_err: any
    output, deser_err = deser(config.protocol, response, operation)
    ctx.output = output

    if interceptors then
        local hook_err = interceptor.run_read(interceptors, "read_after_deserialization", ctx)
        if hook_err and not deser_err then deser_err = hook_err end
    end

    return output, deser_err
end

function M.invokeOperation(self: any, service: any, operation: any, input: any, options: any): any, any
    local op = async.new_operation() as any
    local result, err = M._doInvoke(self, service, operation, input, options)
    op:resolve(result, err)
    return op
end

function M._doInvoke(self: any, service: any, operation: any, input: any, options: any): any, any
    local self_tbl = self as {string:any}
    local config = shallow_copy(self_tbl.config as {string:any})
    if options then
        local opts = options as {string:any}
        local plugins = opts.plugins as {function({string:any})}
        if plugins then
            for _, plugin in ipairs(plugins) do
                plugin(config)
            end
        end
    end

    local interceptors = config.interceptors as {any}
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

    -- Serialize
    local proto = config.protocol as {string:any}
    local ser = proto.serialize as function(any, any, any, any): any, any
    local request: any
    local serialize_err: any
    request, serialize_err = ser(config.protocol, input, service, operation)
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
        request = new_req
    end

    -- Stash original path
    local req_tbl = request as {string:any}
    req_tbl._path = req_tbl.url

    -- Retry loop
    local retryer = config.retry_strategy as any
    local result: any
    local attempt_err: any

    if not retryer then
        result, attempt_err = do_attempt(config, service, operation, input, req_tbl,
            has_interceptors and interceptors or nil, ctx)

        if has_interceptors then
            ctx.output = result
            result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
            attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
        end
    else
        local retry = retryer as {string:any}
        local acquire = retry.acquire_token as function(any): any, any
        local token: any
        token, attempt_err = acquire(retryer)
        if not attempt_err then
            while true do
                result, attempt_err = do_attempt(config, service, operation, input, req_tbl,
                    has_interceptors and interceptors or nil, ctx)

                if has_interceptors then
                    ctx.output = result
                    result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
                    attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
                end

                if not attempt_err then
                    local record_success = retry.record_success as function(any, any)
                    record_success(retryer, token)
                    break
                end

                local retry_token_fn = retry.retry_token as function(any, any, any): any, any
                local delay: any
                delay, attempt_err = retry_token_fn(retryer, token, attempt_err)
                if not delay then
                    break
                end

                local delay_num = delay as number
                if delay_num > 0 then
                    local socket_ok, socket = pcall(require, "socket") as (boolean, any)
                    if socket_ok and (socket as {string:any}).sleep then
                        local sleep_fn = (socket as {string:any}).sleep as function(number)
                        sleep_fn(delay_num)
                    else
                        local target = os.clock() + delay_num
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
    local op = operation as {string:any}
    local trait_fn_op = op.trait as function(any, any): any
    local es = trait_fn_op(operation, traits.EVENT_STREAM)
    if es then
        local protocol = config.protocol
        local proto_tbl = protocol as {string:any}
        local result_tbl = result as {string:any}
        local es_mod = eventstream as {string:any}
        local new_stream_fn = es_mod.new_stream as function(any, any, any, any): any
        local stream_opts: {string:any} = {
            has_initial_message = proto_tbl.has_event_stream_initial_message,
            output_schema = op.output,
            on_close = result_tbl.close,
        }
        local stream = new_stream_fn(
            result_tbl.body,
            es,
            proto_tbl.codec,
            stream_opts
        )

        -- For bidirectional streams, add send capability
        if result_tbl._signing_writer then
            local sw = result_tbl._signing_writer as {string:any}
            local input_es_name = result_tbl._input_event_stream as string
            local input_schema = op.input as {string:any}
            local members_fn = input_schema.members as function(any): {string:any}
            local input_members = members_fn(op.input)
            local es_member = input_members[input_es_name] as {string:any}
            local input_es_schema = es_member._target or es_member

            local stream_tbl = stream as {string:any}
            stream_tbl.send = function(self_stream: any, event: any): any, any
                local serialize_event = es_mod.serialize_event as function(any, any, any): any, string
                local frame, err = serialize_event(event, input_es_schema, proto_tbl.codec)
                if err then return nil, { type = "sdk", message = err } end
                local write_fn = sw.write as function(any, any): any, any
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
