-- Teal declarations for runtime/protocol/restxml.lua

local http = require("http")
local protocol = require("protocol")

local record restxml_protocol

    no_error_wrapping: boolean

    record Settings
        no_error_wrapping: boolean
    end

    new: function(settings: Settings): restxml_protocol

    serialize: function(self: restxml_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: restxml_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return restxml_protocol
