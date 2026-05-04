-- Teal declarations for runtime/codec/json.lua

local schema = require("schema")

local record json_codec

    use_json_name: boolean
    default_timestamp_format: string

    record Settings
        use_json_name: boolean
        default_timestamp_format: string
    end

    new: function(settings: Settings): json_codec

    serialize: function(self: json_codec, value: any, schema: schema.Schema): string, table
    deserialize: function(self: json_codec, bytes: string, schema: schema.Schema): any, table

end

return json_codec
