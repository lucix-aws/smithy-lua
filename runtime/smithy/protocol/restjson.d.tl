-- Teal declarations for runtime/protocol/restjson.lua

local http = require("http")
local protocol = require("protocol")

local record restjson_protocol

    record Settings
    end

    new: function(settings: Settings): restjson_protocol

    serialize: function(self: restjson_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: restjson_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return restjson_protocol
