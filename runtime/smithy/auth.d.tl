-- Teal declarations for smithy-lua runtime/auth (SRA)

local record M

    SIGV4: string
    SIGV4A: string
    NO_AUTH: string

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

    record AuthSchemeOption
        scheme_id: string
        signer_properties: SignerProperties
    end

    record AuthScheme
        scheme_id: string
        identity_type: string
        signer: function(request: table, identity: table, props: SignerProperties): table, table
        identity_resolver: function(self: AuthScheme, identity_resolvers: {string: function(): table, table}): function(): table, table
    end

    record SelectedScheme
        scheme: AuthScheme
        identity_resolver: function(): table, table
        signer_properties: SignerProperties
    end

    anonymous_identity: table
    anonymous_identity_resolver: function(): table, table
    anonymous_signer: function(request: table, identity: table, props: SignerProperties): table, table
    no_auth_scheme: AuthScheme

    new_credentials: function(access_key: string, secret_key: string, session_token: string, expiration: number): Credentials
    new_auth_scheme: function(scheme_id: string, identity_type: string, signer: function(request: table, identity: table, props: SignerProperties): table, table): AuthScheme
    default_auth_scheme_resolver: function(operation: table): {AuthSchemeOption}
    select_scheme: function(options: {AuthSchemeOption}, auth_schemes: {string: AuthScheme}, identity_resolvers: {string: function(): table, table}): SelectedScheme, string
    apply_endpoint_auth_overrides: function(endpoint: table, scheme_id: string, signer_properties: SignerProperties)

end

return M
