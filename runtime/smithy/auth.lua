

local M = { Credentials = {}, AuthScheme = {}, AuthSelection = {}, AuthOption = {} }
































M.SIGV4 = "aws.auth#sigv4"
M.SIGV4A = "aws.auth#sigv4a"
M.NO_AUTH = "smithy.api#noAuth"

function M.new_credentials(access_key, secret_key, session_token, expiration)
   return {
      access_key = access_key,
      secret_key = secret_key,
      session_token = session_token,
      expiration = expiration,
   }
end

M.anonymous_identity = {}

function M.anonymous_identity_resolver()
   return M.anonymous_identity, nil
end

function M.anonymous_signer(request, _identity, _props)
   return request, nil
end

function M.new_auth_scheme(scheme_id, identity_type, signer)
   return {
      scheme_id = scheme_id,
      identity_type = identity_type,
      signer = signer,
      identity_resolver = function(self, identity_resolvers)
         return identity_resolvers[self.identity_type]
      end,
   }
end

M.no_auth_scheme = {
   scheme_id = M.NO_AUTH,
   identity_type = "anonymous",
   signer = M.anonymous_signer,
   identity_resolver = function(_self, _identity_resolvers)
      return M.anonymous_identity_resolver
   end,
}

function M.default_auth_scheme_resolver(service, operation)
   local traits = require("smithy.traits")
   local auth_trait = operation:trait(traits.AUTH)
   if not auth_trait then
      auth_trait = service:trait(traits.AUTH)
   end
   return auth_trait or {}
end

function M.select_scheme(options, auth_schemes, identity_resolvers)
   for _, option in ipairs(options) do
      if option.scheme_id == M.NO_AUTH then
         return {
            scheme = M.no_auth_scheme,
            identity_resolver = M.anonymous_identity_resolver,
            signer_properties = option.signer_properties or {},
         }
      end
      local scheme = auth_schemes[option.scheme_id]
      if scheme then
         local resolver = scheme:identity_resolver(identity_resolvers)
         if resolver then
            local sel = {
               scheme = scheme,
               identity_resolver = resolver,
               signer_properties = option.signer_properties or {},
            }
            return sel
         end
      end
   end
   local ids = {}
   for _, option in ipairs(options) do
      ids[#ids + 1] = option.scheme_id
   end
   return nil, "no auth scheme could be resolved; options: [" .. table.concat(ids, ", ") .. "]"
end

function M.apply_endpoint_auth_overrides(endpoint, scheme_id, signer_properties)
   local props = endpoint.properties
   if not props or not props.authSchemes then return end

   for _, ep_scheme in ipairs(props.authSchemes) do
      local ep = ep_scheme
      if ep.name == scheme_id or ("aws.auth#" .. ((ep.name) or "")) == scheme_id then
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
         return
      end
   end
end

return M
