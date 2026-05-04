-- Teal declarations for runtime/protocol/ec2query.lua

local http = require("http")
local protocol = require("protocol")

local record ec2query_protocol

    record Settings
        version: string
    end

    new: function(settings: Settings): ec2query_protocol

    serialize: function(self: ec2query_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: ec2query_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return ec2query_protocol
