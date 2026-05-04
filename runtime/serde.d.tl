-- Teal declarations for runtime/serde.lua

local schema = require("schema")

local record serde

    record Codec
        serialize: function(self: Codec, value: any, schema: schema.Schema): string, table
        deserialize: function(self: Codec, bytes: string, schema: schema.Schema): any, table
    end

end

return serde
