-- Teal declarations for runtime/protocol/rpcv2.lua

local http = require("http")
local protocol = require("protocol")

local record rpcv2_protocol

    service_name: string

    record Settings
        service_name: string
    end

    new_cbor: function(settings: Settings): rpcv2_protocol
    new_json: function(settings: Settings): rpcv2_protocol

    serialize: function(self: rpcv2_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: rpcv2_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return rpcv2_protocol
