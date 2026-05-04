-- Teal declarations for runtime/protocol/rpcv2cbor.lua

local http = require("http")
local protocol = require("protocol")

local record rpcv2cbor_protocol

    service_name: string

    record Settings
        service_name: string
    end

    new: function(settings: Settings): rpcv2cbor_protocol

    serialize: function(self: rpcv2cbor_protocol, input: table, operation: protocol.Operation): http.Request, table
    deserialize: function(self: rpcv2cbor_protocol, response: http.Response, operation: protocol.Operation): table, table

end

return rpcv2cbor_protocol
