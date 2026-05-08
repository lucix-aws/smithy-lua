-- smithy-lua runtime: XML codec
-- Schema-aware XML serialization and deserialization.

local schema_mod = require("smithy.schema")
local stype = schema_mod.type
local t = require("smithy.traits")
local concat = table.concat
local format = string.format
local huge = math.huge

local record M
    default_timestamp_format: string

    metamethod __index: M

    record XmlNode
        tag: string
        attrs: {string:string}
        children: {XmlNode}
        text: string
    end

    parse_xml: function(s: string): XmlNode
    xml_unescape: function(s: string): string
    xml_escape: function(s: string): string
    decode_node: function(node: XmlNode, schema: schema_mod.Schema, codec: M): any
end

local M_mt: metatable<M> = { __index = M }

local base64 = require("smithy.base64")
local base64_encode = base64.encode
local base64_decode = base64.decode
local json_codec = require("smithy.codec.json")

function M.new(settings: {string:any}): M
    settings = settings or {}
    return setmetatable({
        default_timestamp_format = settings.default_timestamp_format as string or schema_mod.timestamp.DATE_TIME,
    } as M, M_mt)
end

local function xml_escape(s: string): string
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function xml_name(name: string, member_schema: schema_mod.Schema): string
    if member_schema then
        local xn = member_schema:trait(t.XML_NAME) as {string:string}
        if xn then return xn.name end
    end
    return name
end

local function ns_attr_str(ns: any): string
    local ns_tbl = ns as {string:string}
    local attr = ns_tbl.prefix and ("xmlns:" .. ns_tbl.prefix) or "xmlns"
    return " " .. attr .. '="' .. xml_escape(ns_tbl.uri) .. '"'
end

local function format_timestamp(v: number, schema: schema_mod.Schema, codec: M): string
    local ts_format = codec.default_timestamp_format
    if schema then
        local tf = schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
        if tf then ts_format = tf.format end
    end
    if ts_format == schema_mod.timestamp.EPOCH_SECONDS then
        if v % 1 == 0 then return format("%.0f", v) end
        return tostring(v)
    elseif ts_format == schema_mod.timestamp.HTTP_DATE then
        return json_codec._format_http_date(v)
    end
    return json_codec._format_iso8601(v)
end

local function simple_value(v: any, schema: schema_mod.Schema, codec: M): string
    local st = schema.type
    if st == stype.BOOLEAN then return v and "true" or "false" end
    if st == stype.BLOB then return base64_encode(v as string) end
    if st == stype.TIMESTAMP then return format_timestamp(v as number, schema, codec) end
    if st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
        error("bigInteger/bigDecimal not supported in XML codec")
    end
    if st == stype.FLOAT or st == stype.DOUBLE then
        local num = v as number
        if num ~= num then return "NaN"
        elseif num == huge then return "Infinity"
        elseif num == -huge then return "-Infinity"
        end
    end
    if st == stype.INTEGER or st == stype.LONG or st == stype.SHORT
        or st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
        return format("%.0f", v as number)
    end
    return tostring(v)
end

local function encode_value(v: any, name: string, schema: schema_mod.Schema, buf: {string}, n: integer, codec: M): integer
    if v == nil then return n end
    local st = schema.type

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "<" .. name
        local xns = schema:trait(t.XML_NAMESPACE)
        if xns then
            n = n + 1; buf[n] = ns_attr_str(xns)
        end
        local members = schema:members() or {} as {string:schema_mod.Schema}
        for mname, ms in pairs(members) do
            if ms:trait(t.XML_ATTRIBUTE) and (v as {string:any})[mname] ~= nil then
                local aname = xml_name(mname, ms)
                n = n + 1; buf[n] = " " .. aname .. '="' .. xml_escape(simple_value((v as {string:any})[mname], ms, codec)) .. '"'
            end
        end
        n = n + 1; buf[n] = ">"
        local keys: {string} = {}
        for k in pairs(members) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, mname in ipairs(keys) do
            local ms = members[mname]
            if not ms:trait(t.XML_ATTRIBUTE) and (v as {string:any})[mname] ~= nil then
                local ename = xml_name(mname, ms)
                n = encode_value((v as {string:any})[mname], ename, ms, buf, n, codec)
            end
        end
        n = n + 1; buf[n] = "</" .. name .. ">"
        return n

    elseif st == stype.LIST then
        local elem_schema = schema.list_member
        if not elem_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            elem_schema = fallback
        end
        local flattened = schema:trait(t.XML_FLATTENED)
        local arr = v as {any}
        if flattened then
            for i = 1, #arr do
                n = encode_value(arr[i], name, elem_schema, buf, n, codec)
            end
        else
            local item_name = xml_name("member", elem_schema)
            local xns = schema:trait(t.XML_NAMESPACE)
            if xns then
                n = n + 1; buf[n] = "<" .. name .. ns_attr_str(xns) .. ">"
            else
                n = n + 1; buf[n] = "<" .. name .. ">"
            end
            for i = 1, #arr do
                n = encode_value(arr[i], item_name, elem_schema, buf, n, codec)
            end
            n = n + 1; buf[n] = "</" .. name .. ">"
        end
        return n

    elseif st == stype.MAP then
        local key_schema = schema.map_key
        if not key_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            key_schema = fallback
        end
        local val_schema = schema.map_value
        if not val_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            val_schema = fallback
        end
        local key_name = xml_name("key", key_schema)
        local val_name = xml_name("value", val_schema)
        local flattened = schema:trait(t.XML_FLATTENED)
        local entry_name = flattened and name or "entry"
        if not flattened then
            local ns_extra = ""
            local xns = schema:trait(t.XML_NAMESPACE)
            if xns then
                ns_extra = ns_attr_str(xns)
            end
            n = n + 1; buf[n] = "<" .. name .. ns_extra .. ">"
        end
        local keys: {string} = {}
        local map = v as {string:any}
        for k in pairs(map) do keys[#keys + 1] = k end
        table.sort(keys)
        local key_ns = key_schema:trait(t.XML_NAMESPACE)
        local key_ns_str = key_ns and ns_attr_str(key_ns) or ""
        for _, k in ipairs(keys) do
            n = n + 1; buf[n] = "<" .. entry_name .. ">"
            n = n + 1; buf[n] = "<" .. key_name .. key_ns_str .. ">" .. xml_escape(k) .. "</" .. key_name .. ">"
            n = encode_value(map[k], val_name, val_schema, buf, n, codec)
            n = n + 1; buf[n] = "</" .. entry_name .. ">"
        end
        if not flattened then
            n = n + 1; buf[n] = "</" .. name .. ">"
        end
        return n

    elseif st == stype.UNION then
        n = n + 1; buf[n] = "<" .. name .. ">"
        local members = schema:members() or {} as {string:schema_mod.Schema}
        for mname, ms in pairs(members) do
            if (v as {string:any})[mname] ~= nil then
                local ename = xml_name(mname, ms)
                n = encode_value((v as {string:any})[mname], ename, ms, buf, n, codec)
                break
            end
        end
        n = n + 1; buf[n] = "</" .. name .. ">"
        return n

    else
        local ns_extra = ""
        local xns = schema:trait(t.XML_NAMESPACE)
        if xns then
            ns_extra = ns_attr_str(xns)
        end
        n = n + 1; buf[n] = "<" .. name .. ns_extra .. ">" .. xml_escape(simple_value(v, schema, codec)) .. "</" .. name .. ">"
        return n
    end
end

function M.serialize(self: M, value: any, schema: schema_mod.Schema, root_name: string): string, {string:string}
    root_name = root_name or (schema.id as string) or "root"
    local buf: {string} = {}
    local ok, n_or_err = pcall(encode_value, value, root_name, schema, buf, 0, self)
    if not ok then
        return nil, { type = "sdk", message = "xml serialize: " .. tostring(n_or_err) }
    end
    local schema_any: any = schema
    local target = (schema_any as {string:schema_mod.Schema})._target
    if target and (n_or_err as integer) > 0 then
        local root_ns = target:trait(t.XML_NAMESPACE)
        if root_ns then
            local ns_str = ns_attr_str(root_ns)
            buf[1] = buf[1]:gsub("^(<" .. root_name .. ")", "%1" .. ns_str, 1)
        end
    end
    return concat(buf, "", 1, n_or_err as integer), nil
end

-- Minimal XML parser
local function parse_xml(s: string): M.XmlNode
    local pos = 1
    local len = #s

    if s:sub(1, 5) == "<?xml" then
        local found = s:find("?>", 1, true)
        if found then pos = found + 2 end
    end

    local function skip_ws()
        local _, e = s:find("^%s+", pos)
        if e then pos = e + 1 end
    end

    local function parse_node(): any
        if pos > len then return nil end

        if s:byte(pos) ~= 0x3C then
            local text_end = s:find("<", pos, true)
            if not text_end then
                local txt = s:sub(pos)
                pos = len + 1
                return txt
            end
            local txt = s:sub(pos, text_end - 1)
            pos = text_end
            return txt
        end

        if s:sub(pos, pos + 1) == "</" then return nil end

        local tag_end = s:find("[%s/>]", pos + 1)
        if not tag_end then return nil end
        local tag = s:sub(pos + 1, tag_end - 1)

        pos = tag_end
        local attrs: {string:string} = {}
        while true do
            skip_ws()
            if pos > len then break end
            local c = s:byte(pos)
            if c == 0x2F then
                pos = pos + 2
                local node: M.XmlNode = { tag = tag, attrs = attrs, children = {}, text = "" }
                return node
            elseif c == 0x3E then
                pos = pos + 1
                break
            else
                local aname_end = s:find("[=%s]", pos)
                if not aname_end then break end
                local aname = s:sub(pos, aname_end - 1)
                pos = aname_end
                skip_ws()
                if s:byte(pos) == 0x3D then pos = pos + 1 end
                skip_ws()
                local q = s:byte(pos)
                pos = pos + 1
                local val_end = s:find(string.char(q), pos, true)
                if val_end then
                    attrs[aname] = s:sub(pos, val_end - 1)
                    pos = val_end + 1
                end
            end
        end

        local children: {M.XmlNode} = {}
        local texts: {string} = {}
        while pos <= len do
            local ws_end = s:find("%S", pos)
            if ws_end and s:byte(ws_end) == 0x3C and s:sub(ws_end, ws_end + 1) ~= "</" then
                pos = ws_end
            end
            if pos > len then break end
            if s:sub(pos, pos + 1) == "</" then
                local close_end = s:find(">", pos, true)
                if close_end then pos = close_end + 1 end
                break
            end
            if s:sub(pos, pos + 8) == "<![CDATA[" then
                pos = pos + 9
                local cdata_end = s:find("]]>", pos, true)
                if cdata_end then
                    texts[#texts + 1] = s:sub(pos, cdata_end - 1)
                    pos = cdata_end + 3
                end
            elseif s:sub(pos, pos + 3) == "<!--" then
                local comment_end = s:find("-->", pos, true)
                if comment_end then pos = comment_end + 3 end
            else
                local child = parse_node()
                if child == nil then break end
                if type(child) == "string" then
                    texts[#texts + 1] = child as string
                else
                    children[#children + 1] = child as M.XmlNode
                end
            end
        end

        local node: M.XmlNode = { tag = tag, attrs = attrs, children = children, text = table.concat(texts) }
        return node
    end

    skip_ws()
    return parse_node() as M.XmlNode
end

local xml_entities: {string:string} = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xml_unescape(s: string): string
    return (s:gsub("&(%w+);", function(e: string): string return xml_entities[e] or ("&" .. e .. ";") end)
             :gsub("&#(%d+);", function(n_str: string): string return string.char(tonumber(n_str) as integer) end)
             :gsub("&#x(%x+);", function(n_str: string): string return string.char(tonumber(n_str, 16) as integer) end))
end

local function decode_simple(text: string, schema: schema_mod.Schema, codec: M): any
    text = xml_unescape(text)
    local st = schema.type
    if st == stype.BOOLEAN then return text == "true" end
    if st == stype.BLOB then return base64_decode(text) end
    if st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
        error("bigInteger/bigDecimal not supported in XML codec")
    end
    if st == stype.TIMESTAMP then
        local n = tonumber(text)
        if n then return n end
        local ts_format = codec.default_timestamp_format
        local tf = schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
        if tf then ts_format = tf.format end
        if ts_format == schema_mod.timestamp.HTTP_DATE then
            return json_codec._parse_http_date(text)
        end
        return json_codec._parse_iso8601(text)
    end
    if st == stype.INTEGER or st == stype.LONG or st == stype.SHORT
        or st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
        return tonumber(text)
    end
    if st == stype.FLOAT or st == stype.DOUBLE then
        if text == "NaN" then return 0/0
        elseif text == "Infinity" then return huge
        elseif text == "-Infinity" then return -huge
        end
        return tonumber(text)
    end
    return text
end

local function decode_node(node: M.XmlNode, schema: schema_mod.Schema, codec: M): any
    if not node then return nil end
    local st = schema.type

    if st == stype.STRUCTURE then
        local result: {string:any} = {}
        local members = schema:members() or {} as {string:schema_mod.Schema}
        local by_xml: {string:{any}} = {}
        for mname, ms in pairs(members) do
            local xn = xml_name(mname, ms)
            local entry: {any} = { mname, ms }
            by_xml[xn] = entry
        end
        if node.attrs then
            for aname, aval in pairs(node.attrs) do
                if not aname:match("^xmlns") then
                    local entry = by_xml[aname]
                    if entry and (entry[2] as schema_mod.Schema):trait(t.XML_ATTRIBUTE) then
                        result[entry[1] as string] = decode_simple(aval, entry[2] as schema_mod.Schema, codec)
                    end
                end
            end
        end
        local children_by_tag: {string:{M.XmlNode}} = {}
        for _, child in ipairs(node.children or {} as {M.XmlNode}) do
            if not children_by_tag[child.tag] then
                children_by_tag[child.tag] = {}
            end
            local tbl = children_by_tag[child.tag]
            tbl[#tbl + 1] = child
        end
        for ename, children in pairs(children_by_tag) do
            local entry = by_xml[ename]
            if entry then
                local ms = entry[2] as schema_mod.Schema
                if ms.type == stype.LIST and ms:trait(t.XML_FLATTENED) then
                    local list: {any} = {}
                    local elem_schema = ms.list_member
                    if not elem_schema then
                        local fallback = { type = stype.STRING } as schema_mod.Schema
                        elem_schema = fallback
                    end
                    for _, child in ipairs(children) do
                        list[#list + 1] = decode_node(child, elem_schema, codec)
                    end
                    result[entry[1] as string] = list
                elseif ms.type == stype.MAP and ms:trait(t.XML_FLATTENED) then
                    local map: {string:any} = (result[entry[1] as string] as {string:any}) or {}
                    local key_schema = ms.map_key
                    if not key_schema then
                        local fallback = { type = stype.STRING } as schema_mod.Schema
                        key_schema = fallback
                    end
                    local val_schema = ms.map_value
                    if not val_schema then
                        local fallback = { type = stype.STRING } as schema_mod.Schema
                        val_schema = fallback
                    end
                    local kn = xml_name("key", key_schema)
                    local vn = xml_name("value", val_schema)
                    for _, child in ipairs(children) do
                        local k: any
                        local val: any
                        for _, gc in ipairs(child.children or {} as {M.XmlNode}) do
                            if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
                            if gc.tag == vn then val = decode_node(gc, val_schema, codec) end
                        end
                        if k then map[k as string] = val end
                    end
                    result[entry[1] as string] = map
                else
                    result[entry[1] as string] = decode_node(children[1], ms, codec)
                end
            end
        end
        return result

    elseif st == stype.LIST then
        local elem_schema = schema.list_member
        if not elem_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            elem_schema = fallback
        end
        local item_name = xml_name("member", elem_schema)
        local result: {any} = {}
        for _, child in ipairs(node.children or {} as {M.XmlNode}) do
            if child.tag == item_name then
                result[#result + 1] = decode_node(child, elem_schema, codec)
            end
        end
        return result

    elseif st == stype.MAP then
        local key_schema = schema.map_key
        if not key_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            key_schema = fallback
        end
        local val_schema = schema.map_value
        if not val_schema then
            local fallback = { type = stype.STRING } as schema_mod.Schema
            val_schema = fallback
        end
        local kn = xml_name("key", key_schema)
        local vn = xml_name("value", val_schema)
        local result: {string:any} = {}
        for _, child in ipairs(node.children or {} as {M.XmlNode}) do
            if child.tag == "entry" then
                local k: any
                local val: any
                for _, gc in ipairs(child.children or {} as {M.XmlNode}) do
                    if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
                    if gc.tag == vn then val = decode_node(gc, val_schema, codec) end
                end
                if k then result[k as string] = val end
            end
        end
        return result

    elseif st == stype.UNION then
        local members = schema:members() or {} as {string:schema_mod.Schema}
        local by_xml: {string:{any}} = {}
        for mname, ms in pairs(members) do
            local xn = xml_name(mname, ms)
            local entry: {any} = { mname, ms }
            by_xml[xn] = entry
        end
        local result: {string:any} = {}
        for _, child in ipairs(node.children or {} as {M.XmlNode}) do
            local entry = by_xml[child.tag]
            if entry then
                result[entry[1] as string] = decode_node(child, entry[2] as schema_mod.Schema, codec)
                break
            end
        end
        return result

    else
        return decode_simple(node.text or "", schema, codec)
    end
end

function M.deserialize(self: M, bytes: string, schema: schema_mod.Schema, _root_name?: string): any, {string:string}
    if not bytes or #bytes == 0 then return {}, nil end
    local ok, node = pcall(parse_xml, bytes)
    if not ok then
        return nil, { type = "sdk", message = "xml parse: " .. tostring(node) }
    end
    if not node then
        return nil, { type = "sdk", message = "xml parse: empty document" }
    end
    return decode_node(node as M.XmlNode, schema, self), nil
end

M.parse_xml = parse_xml
M.xml_unescape = xml_unescape
M.xml_escape = xml_escape
M.decode_node = decode_node

return M
