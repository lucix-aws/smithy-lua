

local auth_mod = require("smithy.auth")
local interceptor_mod = require("smithy.interceptor")
local http_mod = require("smithy.http")

local client_mod = { Config = {}, Client = {}, Operation = {}, Options = {} }




































local function shallow_copy(t)
   local out = {}
   for k, v in pairs(t) do out[k] = v end
   return out
end

function client_mod.new(config)
   local c = { config = config };
   (c).invokeOperation = client_mod.invokeOperation
   return c
end

local function do_attempt(config, input, request, operation, interceptors, ctx)
   ctx.request = request
   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_before_attempt", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_req, err = interceptor_mod.run_modify(interceptors, "modify_before_signing", ctx, "request")
      if err then return nil, err end
      request = new_req
   end

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_before_signing", ctx)
      if hook_err then return nil, hook_err end
   end


   local resolver = (config.auth_scheme_resolver) or auth_mod.default_auth_scheme_resolver
   local options = resolver(operation)

   local selected, sel_err = auth_mod.select_scheme(options, config.auth_schemes, config.identity_resolvers)
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
   if operation.context_params then
      for param_name, input_field in pairs(operation.context_params) do
         ep_params[param_name] = (input)[input_field]
      end
   end


   local ep_provider = config.endpoint_provider
   local endpoint
   local ep_err
   endpoint, ep_err = ep_provider(ep_params)
   if ep_err then return nil, ep_err end


   local signer_props = shallow_copy(selected.signer_properties)
   auth_mod.apply_endpoint_auth_overrides(endpoint, selected.scheme.scheme_id, signer_props)


   request.url = endpoint.url .. request._path
   if endpoint.headers then
      for k, v in pairs(endpoint.headers) do
         request.headers[k] = v[1]
      end
   end


   local sign_err
   request, sign_err = selected.scheme.signer(request, identity, signer_props)
   if sign_err then return nil, sign_err end
   ctx.request = request

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_after_signing", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_req
      local err
      new_req, err = interceptor_mod.run_modify(interceptors, "modify_before_transmit", ctx, "request")
      if err then return nil, err end
      request = new_req
   end

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_before_transmit", ctx)
      if hook_err then return nil, hook_err end
   end


   local http_client = config.http_client
   local response
   local tx_err
   response, tx_err = http_client(request)
   if tx_err then return nil, tx_err end
   ctx.response = response

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_after_transmit", ctx)
      if hook_err then return nil, hook_err end
   end

   if interceptors then
      local new_resp
      local err
      new_resp, err = interceptor_mod.run_modify(interceptors, "modify_before_deserialization", ctx, "response")
      if err then return nil, err end
      response = new_resp
   end

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_before_deserialization", ctx)
      if hook_err then return nil, hook_err end
   end


   local protocol = config.protocol
   local deser_fn = protocol.deserialize
   local output
   local deser_err
   output, deser_err = deser_fn(protocol, response, operation)
   ctx.output = output

   if interceptors then
      local hook_err = interceptor_mod.run_read(interceptors, "read_after_deserialization", ctx)
      if hook_err and not deser_err then deser_err = hook_err end
   end

   return output, deser_err
end

function client_mod.invokeOperation(self, input, operation, options)
   local config = shallow_copy(self.config)
   if options and options.plugins then
      for _, plugin in ipairs(options.plugins) do
         plugin(config)
      end
   end

   local interceptors = config.interceptors
   local has_interceptors = interceptors and #interceptors > 0

   local ctx = { input = input, operation = operation }

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


   local protocol = config.protocol
   local ser_fn = protocol.serialize
   local request
   local serialize_err
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
      request = new_req
   end

   request._path = request.url


   local retryer = config.retry_strategy
   local result
   local attempt_err

   if not retryer then
      result, attempt_err = do_attempt(config, input, request, operation, has_interceptors and interceptors or nil, ctx)
      if has_interceptors then
         ctx.output = result
         result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
         attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
      end
   else
      local acquire_fn = retryer.acquire_token
      local token
      token, attempt_err = acquire_fn(retryer)
      if not attempt_err then
         while true do
            result, attempt_err = do_attempt(config, input, request, operation, has_interceptors and interceptors or nil, ctx)

            if has_interceptors then
               ctx.output = result
               result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_attempt_completion", ctx, attempt_err)
               attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_attempt", ctx, attempt_err)
            end

            if not attempt_err then
               local success_fn = retryer.record_success
               success_fn(retryer, token)
               break
            end

            local retry_fn = retryer.retry_token
            local delay
            delay, attempt_err = retry_fn(retryer, token, attempt_err)
            if not delay then break end

            if delay > 0 then
               local socket_ok, socket = pcall(require, "socket")
               if socket_ok and (socket).sleep then
                  local sleep_fn = (socket).sleep
                  sleep_fn(delay)
               else
                  local target = os.clock() + delay
                  while os.clock() < target do end
               end
            end
         end
      end
   end


   if has_interceptors then
      ctx.output = result
      result, attempt_err = interceptor_mod.run_modify_completion(interceptors, "modify_before_completion", ctx, attempt_err)
   end


   if has_interceptors then
      attempt_err = interceptor_mod.run_read_with_error(interceptors, "read_after_execution", ctx, attempt_err)
   end

   if attempt_err then return nil, attempt_err end
   return result, nil
end

return client_mod
