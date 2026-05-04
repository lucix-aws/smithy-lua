-- Teal declarations for runtime/protocol/awsjson.lua

local http = require("http")
local protocol = require("protocol")

local record aws_json_protocol

    content_type: string
    service_id: string

    record Settings
        version: string
        service_id: string
    end

    new: function(settings: Settings): aws_json_protocol

    serialize: function(self: aws_json_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: aws_json_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return aws_json_protocol
