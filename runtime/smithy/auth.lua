-- smithy-lua runtime: SRA-compliant auth scheme types
-- See SmithyReferenceArchitectureDocumentation/smithy_reference_arch/auth.tex

local M = {}

--- Auth scheme IDs
M.SIGV4 = "aws.auth#sigv4"
M.SIGV4A = "aws.auth#sigv4a"
M.NO_AUTH = "smithy.api#noAuth"

--- Create a credentials identity (SigV4).
function M.new_credentials(access_key, secret_key, session_token, expiration)
    return {
        access_key = access_key,
        secret_key = secret_key,
        session_token = session_token,
        expiration = expiration,
    }
end

--- Anonymous identity (for noAuth).
M.anonymous_identity = {}

--- Anonymous identity resolver: always returns anonymous identity.
function M.anonymous_identity_resolver()
    return M.anonymous_identity, nil
end

--- No-op signer: returns request unchanged.
function M.anonymous_signer(request, identity, props)
    return request, nil
end

--- Create an AuthScheme.
--- An AuthScheme binds a scheme ID to a signer and knows how to find its
--- identity resolver from the client's identity_resolvers table.
--- @param scheme_id string: e.g. "aws.auth#sigv4"
--- @param identity_type string: key into identity_resolvers, e.g. "aws_credentials"
--- @param signer function: fn(request, identity, props) -> request, err
function M.new_auth_scheme(scheme_id, identity_type, signer)
    return {
        scheme_id = scheme_id,
        identity_type = identity_type,
        signer = signer,
        --- Look up the identity resolver for this scheme from the config.
        identity_resolver = function(self, identity_resolvers)
            return identity_resolvers[self.identity_type]
        end,
    }
end

--- Built-in noAuth auth scheme.
M.no_auth_scheme = {
    scheme_id = M.NO_AUTH,
    identity_type = "anonymous",
    signer = M.anonymous_signer,
    identity_resolver = function(self, identity_resolvers)
        return M.anonymous_identity_resolver
    end,
}

--- Default auth scheme resolver: returns operation.auth_schemes as-is.
function M.default_auth_scheme_resolver(operation)
    return operation.auth_schemes or {}
end

--- Select the auth scheme to use for a request.
--- Iterates the resolved options, finds the first supported scheme with an
--- available identity resolver.
--- @param options table: list of { scheme_id, signer_properties? }
--- @param auth_schemes table: map of scheme_id -> AuthScheme
--- @param identity_resolvers table: map of identity_type -> resolver fn
--- @return table|nil: { scheme, identity_resolver, signer_properties }
--- @return string|nil: error message
function M.select_scheme(options, auth_schemes, identity_resolvers)
    for _, option in ipairs(options) do
        -- noAuth is always available
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
                return {
                    scheme = scheme,
                    identity_resolver = resolver,
                    signer_properties = option.signer_properties or {},
                }
            end
        end
    end
    -- Build error message
    local ids = {}
    for _, option in ipairs(options) do
        ids[#ids + 1] = option.scheme_id
    end
    return nil, "no auth scheme could be resolved; options: [" .. table.concat(ids, ", ") .. "]"
end

--- Apply endpoint authSchemes overrides to signer properties.
--- The endpoint may return properties.authSchemes which override signing_name
--- and signing_region for the selected scheme.
--- @param endpoint table: resolved endpoint with optional properties.authSchemes
--- @param scheme_id string: the selected auth scheme ID
--- @param signer_properties table: current signer properties (mutated in place)
function M.apply_endpoint_auth_overrides(endpoint, scheme_id, signer_properties)
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

return M
