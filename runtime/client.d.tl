-- Teal declarations for smithy-lua runtime/client
-- See INVOKE_OPERATION.md for the full contract.

local http = require("http")
local auth = require("auth")

local record M

    -- Resolved endpoint.
    record Endpoint
        url: string
        headers: {string: string}
    end

    -- Signing properties passed to the signer.
    record SigningProperties
        signing_name: string
        region: string
    end

    -- Endpoint parameters passed to endpoint_provider.
    record EndpointParameters
        region: string
    end

    -- Protocol interface: serialize input to request, deserialize response to output.
    record ClientProtocol
        serialize: function(input: table, operation: Operation): http.Request, table
        deserialize: function(response: http.Response, operation: Operation): table, table
    end

    -- Static operation metadata, produced by codegen.
    record Operation
        name: string
        input_schema: table
        output_schema: table
        http_method: string
        http_path: string
        -- error_schemas: {table}
        -- auth_schemes: {string}
    end

    -- Per-operation override options.
    record Options
        plugins: {function(config: Config)}
    end

    -- Client configuration. Plugins receive and mutate a copy of this.
    record Config
        service_id: string
        protocol: ClientProtocol
        http_client: function(request: http.Request): http.Response, table
        endpoint_provider: function(params: EndpointParameters): Endpoint, table
        identity_resolver: function(): auth.Credentials, table
        signer: function(request: http.Request, identity: auth.Credentials, props: SigningProperties): http.Request, table
        signing_name: string
        region: string
        -- retry_strategy: RetryStrategy
        -- auth_schemes: {string: auth.AuthScheme}
        -- auth_scheme_resolver: function(config: Config, operation: Operation): {string}
        -- interceptors: {Interceptor}
    end

    -- The client table.
    record Client
        config: Config
        invokeOperation: function(self: Client, input: table, operation: Operation, options: Options): table, table
    end

    new: function(config: Config): Client
    invokeOperation: function(self: Client, input: table, operation: Operation, options: Options): table, table

end

return M
