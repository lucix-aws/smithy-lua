-- Teal declarations for runtime/codec/xml.lua

local schema = require("schema")

local record xml_codec

    default_timestamp_format: string

    record Settings
        default_timestamp_format: string
    end

    record XmlNode
        tag: string
        attrs: {string: string}
        children: {XmlNode}
        text: string
    end

    new: function(settings: Settings): xml_codec

    serialize: function(self: xml_codec, value: any, schema: schema.Schema, root_name: string): string, table
    deserialize: function(self: xml_codec, bytes: string, schema: schema.Schema, root_name: string): any, table

    parse_xml: function(s: string): XmlNode
    xml_unescape: function(s: string): string
    xml_escape: function(s: string): string

end

return xml_codec
