-- Teal declarations for smithy-lua runtime/client (SRA)

local http = require("http")
local auth = require("auth")
local protocol = require("protocol")

local record M

    record Endpoint
        url: string
        headers: {string: string}
        properties: table
    end

    record Options
        plugins: {function(config: Config)}
    end

    record Config
        service_id: string
        protocol: protocol.ClientProtocol
        http_client: function(request: http.Request): http.Response, table
        endpoint_provider: function(params: table): Endpoint, table
        region: string
        use_fips: boolean
        use_dual_stack: boolean
        endpoint_url: string

        -- SRA auth
        auth_schemes: {string: auth.AuthScheme}
        identity_resolvers: {string: function(): table, table}
        auth_scheme_resolver: function(operation: protocol.Operation): {auth.AuthSchemeOption}

        -- Retry
        retry_strategy: table
    end

    record Client
        config: Config
        invokeOperation: function(self: Client, input: table, operation: protocol.Operation, options: Options): table, table
    end

    new: function(config: Config): Client
    invokeOperation: function(self: Client, input: table, operation: protocol.Operation, options: Options): table, table

end

return M
