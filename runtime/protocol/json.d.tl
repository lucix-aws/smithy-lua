-- Teal declarations for runtime/protocol/json.lua

local http = require("http")
local client = require("client")

local record aws_json_protocol

    content_type: string
    service_id: string

    record Settings
        version: string
        service_id: string
    end

    new: function(settings: Settings): aws_json_protocol

    serialize: function(self: aws_json_protocol, input: table, operation: client.Operation): http.Request, table
    deserialize: function(self: aws_json_protocol, response: http.Response, operation: client.Operation): table, table

end

return aws_json_protocol
