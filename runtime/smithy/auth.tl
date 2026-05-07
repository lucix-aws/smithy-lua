-- smithy-lua runtime: SRA-compliant auth scheme types

local record M
    record Credentials
        access_key: string
        secret_key: string
        session_token: string
        expiration: number
    end

    record AuthScheme
        scheme_id: string
        identity_type: string
        signer: function(request: any, identity: any, props: {string:any}): any, any
        identity_resolver: function(AuthScheme, {string:function}): function
    end

    record AuthSelection
        scheme: AuthScheme
        identity_resolver: function(): any, any
        signer_properties: {string:any}
    end

    record AuthOption
        scheme_id: string
        signer_properties: {string:any}
    end

    SIGV4: string
    SIGV4A: string
    NO_AUTH: string
    anonymous_identity: table
    no_auth_scheme: AuthScheme
end

M.SIGV4 = "aws.auth#sigv4"
M.SIGV4A = "aws.auth#sigv4a"
M.NO_AUTH = "smithy.api#noAuth"

function M.new_credentials(access_key: string, secret_key: string, session_token: string, expiration: number): Credentials
    return {
        access_key = access_key,
        secret_key = secret_key,
        session_token = session_token,
        expiration = expiration,
    }
end

M.anonymous_identity = {}

function M.anonymous_identity_resolver(): table, any
    return M.anonymous_identity, nil
end

function M.anonymous_signer(request: any, _identity: any, _props: {string:any}): any, any
    return request, nil
end

function M.new_auth_scheme(scheme_id: string, identity_type: string, signer: function(any, any, {string:any}): any, any): AuthScheme
    return {
        scheme_id = scheme_id,
        identity_type = identity_type,
        signer = signer,
        identity_resolver = function(self: AuthScheme, identity_resolvers: {string:function}): function
            return identity_resolvers[self.identity_type]
        end,
    }
end

M.no_auth_scheme = {
    scheme_id = M.NO_AUTH,
    identity_type = "anonymous",
    signer = M.anonymous_signer,
    identity_resolver = function(_self: AuthScheme, _identity_resolvers: {string:function}): function
        return M.anonymous_identity_resolver
    end,
}

function M.default_auth_scheme_resolver(service: any, operation: any): {AuthOption}
    local traits = require("smithy.traits")
    local auth_trait = operation:trait(traits.AUTH)
    if not auth_trait then
        auth_trait = service:trait(traits.AUTH)
    end
    return auth_trait or {} as {AuthOption}
end

function M.select_scheme(options: {AuthOption}, auth_schemes: {string:AuthScheme}, identity_resolvers: {string:function}): AuthSelection, string
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
                local sel: AuthSelection = {
                    scheme = scheme,
                    identity_resolver = resolver,
                    signer_properties = option.signer_properties or {},
                }
                return sel
            end
        end
    end
    local ids: {string} = {}
    for _, option in ipairs(options) do
        ids[#ids + 1] = option.scheme_id
    end
    return nil, "no auth scheme could be resolved; options: [" .. table.concat(ids, ", ") .. "]"
end

function M.apply_endpoint_auth_overrides(endpoint: {string:any}, scheme_id: string, signer_properties: {string:any})
    local props = endpoint.properties as {string:any}
    if not props or not props.authSchemes then return end

    for _, ep_scheme in ipairs(props.authSchemes as {any}) do
        local ep = ep_scheme as {string:any}
        if ep.name == scheme_id or ("aws.auth#" .. ((ep.name as string) or "")) == scheme_id then
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
