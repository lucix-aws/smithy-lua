-- smithy-lua runtime: ClientProtocol interface

local http = require("smithy.http")
local schema = require("smithy.schema")

local record M
    record ClientProtocol
        content_type: string
        has_event_stream_initial_message: boolean
        codec: any

        serialize: function(ClientProtocol, input: {string:any}, service: schema.ServiceSchema, operation: schema.OperationSchema): http.Request, http.Error
        deserialize: function(ClientProtocol, response: http.Response, operation: schema.OperationSchema): {string:any}, http.Error
    end
end

return M
