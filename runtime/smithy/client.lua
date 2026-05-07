

local async = require("smithy.async")
local auth = require("smithy.auth")
local eventstream = require("smithy.eventstream")
local eventstream_signer = require("smithy.eventstream_signer")
local interceptor = require("smithy.interceptor")
local traits = require("smithy.traits")

local M = {}




local function shallow_copy(t)
   local out = {}
   for k, v in pairs(t) do
      out[k] = v
   end
   return out
end

local function find_input_event_stream(operation)
   local op = operation
   local input_schema = op.input
   if not input_schema then return nil, nil end
   local members_fn = (input_schema).members
   if not members_fn then return nil, nil end
   local members = members_fn(input_schema)
   if not members then return nil, nil end
   for name, ms in pairs(members) do
      local schema = ms
      local trait_fn = schema.trait
      if trait_fn and trait_fn(ms, traits.STREAMING) and schema.type == "union" then
         return name, ms
      end
   end
   return nil, nil
end

local function extract_signature(auth_header)
   return auth_header and auth_header:match("Signature=(%x+)")
end

function M.new(config)
   return { config = config, invokeOperation = M.invokeOperation }
end

local function do_attempt(config, service, operation, input, request, interceptors, ctx)
   ctx.request = request
   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_before_attempt", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_req, err = interceptor.run_modify(interceptors, "modify_before_signing", ctx, "request")
      if err then return nil, err end
      request = new_req
   end

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_before_signing", ctx)
      if hook_err then return nil, hook_err end
   end


   local resolver = (config.auth_scheme_resolver or auth.default_auth_scheme_resolver)
   local options = resolver(service, operation, input)

   local selected
   local sel_err
   selected, sel_err = auth.select_scheme(options, config.auth_schemes, config.identity_resolvers)
   if not selected then return nil, { type = "sdk", message = sel_err } end


   local identity
   local id_err
   identity, id_err = selected.identity_resolver()
   if id_err then return nil, id_err end


   local ep_params = {}
   if config.region then ep_params.Region = config.region end
   if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
   if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
   if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
   if config.disable_s3_express_session_auth then
      ep_params.DisableS3ExpressSessionAuth = true
   end

   local op = operation
   local trait_fn = op.trait
   local static_ctx = trait_fn(operation, traits.STATIC_CONTEXT_PARAMS)
   if static_ctx then
      for param_name, param_def in pairs(static_ctx) do
         ep_params[param_name] = param_def.value
      end
   end
   local ctx_params = trait_fn(operation, traits.CONTEXT_PARAMS)
   if ctx_params then
      local inp = input
      for param_name, input_field in pairs(ctx_params) do
         ep_params[param_name] = inp[input_field]
      end
   end


   local ep_fn = config.endpoint_provider
   local endpoint
   local ep_err
   endpoint, ep_err = ep_fn(ep_params)
   if ep_err then return nil, ep_err end


   local signer_props = shallow_copy(selected.signer_properties)
   auth.apply_endpoint_auth_overrides(endpoint, selected.scheme.scheme_id, signer_props)


   local ep_tbl = endpoint
   request.url = (ep_tbl.url) .. (request._path)
   local ep_headers = ep_tbl.headers
   if ep_headers then
      local req_headers = request.headers
      for k, v in pairs(ep_headers) do
         req_headers[k] = v
      end
   end


   local input_es_name = find_input_event_stream(operation)
   if input_es_name then
      local req_headers = request.headers
      req_headers["X-Amz-Content-Sha256"] = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
      req_headers["Transfer-Encoding"] = "chunked"
      req_headers["Content-Type"] = "application/vnd.amazon.eventstream"
   end

   local sign_fn = selected.scheme.signer
   local signed_req
   local sign_err
   signed_req, sign_err = sign_fn(request, identity, signer_props)
   if sign_err then return nil, sign_err end
   request = signed_req


   local signing_writer
   if input_es_name then
      local req_headers = request.headers
      local seed = extract_signature(req_headers["Authorization"])
      if not seed then
         return nil, { type = "sdk", message = "failed to extract signature for event stream signing" }
      end
      local es_signer_mod = eventstream_signer
      local es_new = es_signer_mod.new
      local es_signer = es_new(identity, signer_props, seed)
      local es_mod = eventstream
      local new_sw = es_mod.new_signing_writer
      signing_writer = new_sw(es_signer)
      local sw = signing_writer
      request.body = sw.body_reader
      request.streaming = true
   end

   ctx.request = request

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_after_signing", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_req
      local mod_err
      new_req, mod_err = interceptor.run_modify(interceptors, "modify_before_transmit", ctx, "request")
      if mod_err then return nil, mod_err end
      request = new_req
   end

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_before_transmit", ctx)
      if hook_err then return nil, hook_err end
   end


   local http_client = config.http_client
   local response
   local tx_err
   local r1, r2
   if type(http_client) == "table" and http_client.send then
      r1, r2 = http_client:send(request)
   else
      r1, r2 = http_client(request)
   end
   if type(r1) == "table" and r1.await then
      response, tx_err = r1:await()
   else
      response, tx_err = r1, r2
   end
   if tx_err then return nil, tx_err end
   ctx.response = response

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_after_transmit", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_resp
      local mod_err
      new_resp, mod_err = interceptor.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
      if mod_err then return nil, mod_err end
      response = new_resp
   end

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_before_deserialization", ctx)
      if hook_err then return nil, hook_err end
   end


   local es = trait_fn(operation, traits.EVENT_STREAM)
   if es then
      local resp = response
      local status = resp.status_code
      if status < 200 or status >= 300 then
         local proto = config.protocol
         local deser = proto.deserialize
         return deser(config.protocol, response, operation)
      end
      resp._signing_writer = signing_writer
      resp._input_event_stream = input_es_name
      return response, nil
   end

   local proto = config.protocol
   local deser = proto.deserialize
   local output
   local deser_err
   output, deser_err = deser(config.protocol, response, operation)
   ctx.output = output

   if interceptors then
      local hook_err = interceptor.run_read(interceptors, "read_after_deserialization", ctx)
      if hook_err and not deser_err then deser_err = hook_err end
   end

   return output, deser_err
end

local function do_invoke(self, service, operation, input, options)
   local self_tbl = self
   local config = shallow_copy(self_tbl.config)
   if options then
      local opts = options
      local plugins = opts.plugins
      if plugins then
         for _, plugin in ipairs(plugins) do
            plugin(config)
         end
      end
   end

   local interceptors = config.interceptors
   local has_interceptors = interceptors and #interceptors > 0

   local ctx = { input = input, operation = operation }


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


   local proto = config.protocol
   local ser = proto.serialize
   local request
   local serialize_err
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


   local req_tbl = request
   req_tbl._path = req_tbl.url


   local retryer = config.retry_strategy
   local result
   local attempt_err

   if not retryer then
      result, attempt_err = do_attempt(config, service, operation, input, req_tbl,
      has_interceptors and interceptors or nil, ctx)

      if has_interceptors then
         ctx.output = result
         result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
         attempt_err = interceptor.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
      end
   else
      local retry = retryer
      local acquire = retry.acquire_token
      local token
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
               local record_success = retry.record_success
               record_success(retryer, token)
               break
            end

            local retry_token_fn = retry.retry_token
            local delay
            delay, attempt_err = retry_token_fn(retryer, token, attempt_err)
            if not delay then
               break
            end

            local delay_num = delay
            if delay_num > 0 then
               local socket_ok, socket = pcall(require, "socket")
               if socket_ok and (socket).sleep then
                  local sleep_fn = (socket).sleep
                  sleep_fn(delay_num)
               else
                  local target = os.clock() + delay_num
                  while os.clock() < target do end
               end
            end
         end
      end
   end


   if has_interceptors then
      ctx.output = result
      result, attempt_err = interceptor.run_modify_completion(interceptors, "modify_before_completion", ctx, attempt_err)
   end


   if has_interceptors then
      attempt_err = interceptor.run_read_with_error(interceptors, "read_after_execution", ctx, attempt_err)
   end

   if attempt_err then return nil, attempt_err end


   local op = operation
   local trait_fn_op = op.trait
   local es = trait_fn_op(operation, traits.EVENT_STREAM)
   if es then
      local protocol = config.protocol
      local proto_tbl = protocol
      local result_tbl = result
      local es_mod = eventstream
      local new_stream_fn = es_mod.new_stream
      local stream_opts = {
         has_initial_message = proto_tbl.has_event_stream_initial_message,
         output_schema = op.output,
         on_close = result_tbl.close,
      }
      local stream = new_stream_fn(
      result_tbl.body,
      es,
      proto_tbl.codec,
      stream_opts)



      if result_tbl._signing_writer then
         local sw = result_tbl._signing_writer
         local input_es_name = result_tbl._input_event_stream
         local input_schema = op.input
         local members_fn = input_schema.members
         local input_members = members_fn(op.input)
         local es_member = input_members[input_es_name]
         local input_es_schema = es_member._target or es_member

         local stream_tbl = stream
         stream_tbl.send = function(self_stream, event)
            local serialize_event = es_mod.serialize_event
            local frame, err = serialize_event(event, input_es_schema, proto_tbl.codec)
            if err then return nil, { type = "sdk", message = err } end
            local write_fn = sw.write
            return write_fn(sw, frame)
         end

         stream_tbl.close_input = function(_self_stream)
            local close_fn = sw.close
            close_fn(sw)
         end
      end

      return stream, nil
   end

   return result, nil
end

function M.invokeOperation(self, service, operation, input, options)
   -- Event stream operations bypass the Operation wrapper
   local op_schema = operation
   local trait_fn = op_schema.trait
   if trait_fn and trait_fn(operation, traits.EVENT_STREAM) then
      return do_invoke(self, service, operation, input, options)
   end

   local self_tbl = self
   local hc = self_tbl.config.http_client
   local is_async = type(hc) == "table" and hc.is_async and hc:is_async()

   local result_op = async.new_operation()

   if is_async then
      local co = coroutine.create(function()
         local result, err = do_invoke(self, service, operation, input, options)
         result_op:resolve(result, err)
      end)
      coroutine.resume(co)
   else
      local result, err = do_invoke(self, service, operation, input, options)
      result_op:resolve(result, err)
   end

   return result_op
end

return M
