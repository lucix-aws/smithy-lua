

local M = {}



local SCHEME_MAP = {
   sigv4 = "aws.auth#sigv4",
   sigv4a = "aws.auth#sigv4a",
   ["sigv4-s3express"] = "com.amazonaws.s3#sigv4express",
}

function M.new(config)
   local traits = require("smithy.traits")
   return function(service, operation, input)
      local ep_params = {}
      if config.region then ep_params.Region = config.region end
      if config.use_fips ~= nil then ep_params.UseFIPS = config.use_fips end
      if config.use_dual_stack ~= nil then ep_params.UseDualStack = config.use_dual_stack end
      if config.endpoint_url then ep_params.Endpoint = config.endpoint_url end
      if config.disable_s3_express_session_auth then
         ep_params.DisableS3ExpressSessionAuth = true
      end
      local static_ctx = operation:trait(traits.STATIC_CONTEXT_PARAMS)
      if static_ctx then
         for param_name, param_def in pairs(static_ctx) do
            ep_params[param_name] = param_def.value
         end
      end
      local ctx_params = operation:trait(traits.CONTEXT_PARAMS)
      if ctx_params and input then
         for param_name, input_field in pairs(ctx_params) do
            ep_params[param_name] = input[input_field]
         end
      end

      local endpoint_provider = config.endpoint_provider
      local endpoint, err = endpoint_provider(ep_params)
      if err then
         local auth_trait = operation:trait(traits.AUTH) or service:trait(traits.AUTH)
         return auth_trait or {}
      end

      local props = endpoint.properties
      if not props or not props.authSchemes then
         local auth_trait = operation:trait(traits.AUTH) or service:trait(traits.AUTH)
         return auth_trait or {}
      end

      local options = {}
      for _, ep_scheme in ipairs(props.authSchemes) do
         local ep = ep_scheme
         local scheme_id = SCHEME_MAP[ep.name] or ("aws.auth#" .. (ep.name))
         local signer_properties = {}
         if ep.signingName then
            signer_properties.signing_name = ep.signingName
         end
         if ep.signingRegion then
            signer_properties.signing_region = ep.signingRegion
         end
         if ep.signingRegionSet then
            signer_properties.signing_region_set = ep.signingRegionSet
         end
         if ep.disableDoubleEncoding ~= nil then
            signer_properties.disable_double_encoding = ep.disableDoubleEncoding
         end
         options[#options + 1] = {
            scheme_id = scheme_id,
            signer_properties = signer_properties,
         }
      end

      if ep_params.Bucket then
         config._s3express_bucket = ep_params.Bucket
      end

      return options
   end
end

return M
