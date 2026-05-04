-- Teal declarations for runtime/protocol/awsquery.lua

local http = require("http")
local protocol = require("protocol")

local record awsquery_protocol

    version: string
    ec2: boolean

    record Settings
        version: string
        ec2: boolean
    end

    new: function(settings: Settings): awsquery_protocol

    serialize: function(self: awsquery_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: awsquery_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return awsquery_protocol
