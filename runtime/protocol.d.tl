-- Teal declarations for smithy-lua runtime/protocol.lua
-- ClientProtocol interface and Operation metadata.

local http = require("http")

local record protocol

    -- Static operation metadata, produced by codegen.
    record Operation
        name: string
        input_schema: table
        output_schema: table
        http_method: string
        http_path: string
        context_params: {string: string}
    end

    -- Protocol interface: serialize input to request, deserialize response to output.
    record ClientProtocol
        serialize: function(self: ClientProtocol, input: table, operation: Operation): http.Request, table
        deserialize: function(self: ClientProtocol, response: http.Response, operation: Operation): table, table
    end

end

return protocol
