-- Teal declarations for runtime/codec/cbor.lua

local schema = require("schema")

local record cbor_codec

    record Settings
    end

    new: function(settings: Settings): cbor_codec

    serialize: function(self: cbor_codec, value: any, schema: schema.Schema): string, table
    deserialize: function(self: cbor_codec, bytes: string, schema: schema.Schema): any, table

    decode_item: function(data: string, pos: number): any, number

end

return cbor_codec
