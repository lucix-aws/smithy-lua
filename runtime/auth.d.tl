-- Teal declarations for smithy-lua runtime/auth

local record M

    SIGV4: string

    record Credentials
        access_key: string
        secret_key: string
        session_token: string
        expiration: number
    end

    record AuthScheme
        scheme_id: string
        identity_resolver: function(): Credentials, table
        signer: function(request: table, identity: Credentials, props: table): table, table
    end

    new_credentials: function(access_key: string, secret_key: string, session_token: string, expiration: number): Credentials
    new_auth_scheme: function(scheme_id: string, identity_resolver: function(): Credentials, table, signer: function(request: table, identity: Credentials, props: table): table, table): AuthScheme

end

return M
