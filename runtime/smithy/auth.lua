

local http_mod = require("smithy.http")

local auth_mod = { Credentials = {}, SignerProperties = {}, AuthScheme = {}, AuthOption = {}, SelectedScheme = {}, EndpointAuthScheme = {}, EndpointProperties = {}, Endpoint = {} }





























































auth_mod.SIGV4 = "aws.auth#sigv4"
auth_mod.SIGV4A = "aws.auth#sigv4a"
auth_mod.NO_AUTH = "smithy.api#noAuth"

function auth_mod.new_credentials(access_key, secret_key, session_token, expiration)
   return {
      access_key = access_key,
      secret_key = secret_key,
      session_token = session_token,
      expiration = expiration,
   }
end

auth_mod.anonymous_identity = {}

function auth_mod.anonymous_identity_resolver()
   return auth_mod.anonymous_identity, nil
end

function auth_mod.anonymous_signer(request, _identity, _props)
   return request, nil
end

function auth_mod.new_auth_scheme(scheme_id, identity_type, signer)
   return {
      scheme_id = scheme_id,
      identity_type = identity_type,
      signer = signer,
      identity_resolver = function(self, identity_resolvers)
         return identity_resolvers[self.identity_type]
      end,
   }
end

auth_mod.no_auth_scheme = {
   scheme_id = "smithy.api#noAuth",
   identity_type = "anonymous",
   signer = auth_mod.anonymous_signer,
   identity_resolver = function(_self, _identity_resolvers)
      return auth_mod.anonymous_identity_resolver
   end,
}

function auth_mod.default_auth_scheme_resolver(operation)
   return (operation.auth_schemes) or {}
end

function auth_mod.select_scheme(options, auth_schemes, identity_resolvers)
   for _, option in ipairs(options) do
      if option.scheme_id == auth_mod.NO_AUTH then
         return {
            scheme = auth_mod.no_auth_scheme,
            identity_resolver = auth_mod.anonymous_identity_resolver,
            signer_properties = option.signer_properties or {},
         }
      end

      local scheme = auth_schemes[option.scheme_id]
      if scheme then
         local resolver = scheme:identity_resolver(identity_resolvers)
         if resolver then
            return {
               scheme = scheme,
               identity_resolver = resolver,
               signer_properties = option.signer_properties or {},
            }
         end
      end
   end
   local ids = {}
   for _, option in ipairs(options) do
      ids[#ids + 1] = option.scheme_id
   end
   return nil, "no auth scheme could be resolved; options: [" .. table.concat(ids, ", ") .. "]"
end

function auth_mod.apply_endpoint_auth_overrides(endpoint, scheme_id, signer_properties)
   local props = endpoint.properties
   if not props or not props.authSchemes then return end

   for _, ep_scheme in ipairs(props.authSchemes) do
      if ep_scheme.name == scheme_id or
         ("aws.auth#" .. (ep_scheme.name or "")) == scheme_id then
         if ep_scheme.signingName then
            signer_properties.signing_name = ep_scheme.signingName
         end
         if ep_scheme.signingRegion then
            signer_properties.signing_region = ep_scheme.signingRegion
         end
         if ep_scheme.signingRegionSet then
            signer_properties.signing_region_set = ep_scheme.signingRegionSet
         end
         if ep_scheme.disableDoubleEncoding ~= nil then
            signer_properties.disable_double_encoding = ep_scheme.disableDoubleEncoding
         end
         return
      end
   end
end

return auth_mod
