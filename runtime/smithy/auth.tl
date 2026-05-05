-- smithy-lua runtime: SRA-compliant auth scheme types

local http_mod = require("smithy.http")

local record auth_mod
    record Credentials
        access_key: string
        secret_key: string
        session_token: string
        expiration: number
    end

    record SignerProperties
        signing_name: string
        signing_region: string
        signing_region_set: {string}
        disable_double_encoding: boolean
    end

    type Signer = function(http_mod.Request, any, SignerProperties): http_mod.Request, any
    type IdentityResolver = function(): any, any

    record AuthScheme
        scheme_id: string
        identity_type: string
        signer: Signer
        identity_resolver: function(AuthScheme, {string:IdentityResolver}): IdentityResolver
    end

    record AuthOption
        scheme_id: string
        signer_properties: SignerProperties
    end

    record SelectedScheme
        scheme: AuthScheme
        identity_resolver: IdentityResolver
        signer_properties: SignerProperties
    end

    record EndpointAuthScheme
        name: string
        signingName: string
        signingRegion: string
        signingRegionSet: {string}
        disableDoubleEncoding: boolean
    end

    record EndpointProperties
        authSchemes: {EndpointAuthScheme}
    end

    record Endpoint
        url: string
        headers: {string:{string}}
        properties: EndpointProperties
    end

    SIGV4: string
    SIGV4A: string
    NO_AUTH: string

    anonymous_identity: any
    no_auth_scheme: AuthScheme
end

auth_mod.SIGV4 = "aws.auth#sigv4"
auth_mod.SIGV4A = "aws.auth#sigv4a"
auth_mod.NO_AUTH = "smithy.api#noAuth"

function auth_mod.new_credentials(access_key: string, secret_key: string, session_token: string, expiration: number): auth_mod.Credentials
    return {
        access_key = access_key,
        secret_key = secret_key,
        session_token = session_token,
        expiration = expiration,
    }
end

auth_mod.anonymous_identity = {}

function auth_mod.anonymous_identity_resolver(): any, any
    return auth_mod.anonymous_identity, nil
end

function auth_mod.anonymous_signer(request: http_mod.Request, _identity: any, _props: auth_mod.SignerProperties): http_mod.Request, any
    return request, nil
end

function auth_mod.new_auth_scheme(scheme_id: string, identity_type: string, signer: auth_mod.Signer): auth_mod.AuthScheme
    return {
        scheme_id = scheme_id,
        identity_type = identity_type,
        signer = signer,
        identity_resolver = function(self: auth_mod.AuthScheme, identity_resolvers: {string:auth_mod.IdentityResolver}): auth_mod.IdentityResolver
            return identity_resolvers[self.identity_type]
        end,
    }
end

auth_mod.no_auth_scheme = {
    scheme_id = "smithy.api#noAuth",
    identity_type = "anonymous",
    signer = auth_mod.anonymous_signer as auth_mod.Signer,
    identity_resolver = function(_self: auth_mod.AuthScheme, _identity_resolvers: {string:auth_mod.IdentityResolver}): auth_mod.IdentityResolver
        return auth_mod.anonymous_identity_resolver
    end,
}

function auth_mod.default_auth_scheme_resolver(operation: {string:any}): {auth_mod.AuthOption}
    return (operation.auth_schemes as {auth_mod.AuthOption}) or {}
end

function auth_mod.select_scheme(options: {auth_mod.AuthOption}, auth_schemes: {string:auth_mod.AuthScheme}, identity_resolvers: {string:auth_mod.IdentityResolver}): auth_mod.SelectedScheme, string
    for _, option in ipairs(options) do
        if option.scheme_id == auth_mod.NO_AUTH then
            return {
                scheme = auth_mod.no_auth_scheme,
                identity_resolver = auth_mod.anonymous_identity_resolver,
                signer_properties = option.signer_properties or {} as auth_mod.SignerProperties,
            }
        end

        local scheme = auth_schemes[option.scheme_id]
        if scheme then
            local resolver = scheme:identity_resolver(identity_resolvers)
            if resolver then
                return {
                    scheme = scheme,
                    identity_resolver = resolver,
                    signer_properties = option.signer_properties or {} as auth_mod.SignerProperties,
                }
            end
        end
    end
    local ids: {string} = {}
    for _, option in ipairs(options) do
        ids[#ids + 1] = option.scheme_id
    end
    return nil, "no auth scheme could be resolved; options: [" .. table.concat(ids, ", ") .. "]"
end

function auth_mod.apply_endpoint_auth_overrides(endpoint: auth_mod.Endpoint, scheme_id: string, signer_properties: auth_mod.SignerProperties)
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
