-- smithy-lua runtime: XML codec
-- Schema-aware XML serialization and deserialization.

local schema_mod = require("smithy.schema")
local stype = schema_mod.type
local t = require("smithy.traits")
local concat = table.concat
local format = string.format
local huge = math.huge

local M = {}
M.__index = M

-- Reuse base64 from JSON codec
local json_codec = require("smithy.codec.json")
local base64_encode = json_codec._base64_encode
local base64_decode = json_codec._base64_decode

function M.new(settings)
    settings = settings or {}
    return setmetatable({
        default_timestamp_format = settings.default_timestamp_format or schema_mod.timestamp.DATE_TIME,
    }, M)
end

-- XML escape
local function xml_escape(s)
    s = tostring(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

-- Get the XML element name for a member
local function xml_name(name, member_schema)
    if member_schema then
        local xn = member_schema:trait(t.XML_NAME)
        if xn then return xn.name end
    end
    return name
end

-- Build namespace attribute string from a namespace trait value
local function ns_attr_str(ns)
    local attr = ns.prefix and ("xmlns:" .. ns.prefix) or "xmlns"
    return " " .. attr .. '="' .. xml_escape(ns.uri) .. '"'
end

-- Format a timestamp value
local function format_timestamp(v, schema, codec)
    local ts_format = codec.default_timestamp_format
    if schema then
        local tf = schema:trait(t.TIMESTAMP_FORMAT)
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

-- Serialize a simple value to its XML text representation
local function simple_value(v, schema, codec)
    local st = schema.type
    if st == stype.BOOLEAN then return v and "true" or "false" end
    if st == stype.BLOB then return base64_encode(v) end
    if st == stype.TIMESTAMP then return format_timestamp(v, schema, codec) end
    if st == stype.FLOAT or st == stype.DOUBLE then
        if v ~= v then return "NaN"
        elseif v == huge then return "Infinity"
        elseif v == -huge then return "-Infinity"
        end
    end
    if st == stype.INTEGER or st == stype.LONG or st == stype.SHORT
        or st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
        return format("%.0f", v)
    end
    return tostring(v)
end

-- Encode a value into XML buffer
local function encode_value(v, name, schema, buf, n, codec)
    if v == nil then return n end
    local st = schema.type

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "<" .. name
        -- XML namespace
        local xns = schema:trait(t.XML_NAMESPACE)
        if xns then
            n = n + 1; buf[n] = ns_attr_str(xns)
        end
        -- Attributes first
        local members = schema:members() or {}
        for mname, ms in pairs(members) do
            if ms:trait(t.XML_ATTRIBUTE) and v[mname] ~= nil then
                local aname = xml_name(mname, ms)
                n = n + 1; buf[n] = " " .. aname .. '="' .. xml_escape(simple_value(v[mname], ms, codec)) .. '"'
            end
        end
        n = n + 1; buf[n] = ">"
        -- Child elements (non-attribute members)
        local keys = {}
        for k in pairs(members) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, mname in ipairs(keys) do
            local ms = members[mname]
            if not ms:trait(t.XML_ATTRIBUTE) and v[mname] ~= nil then
                local ename = xml_name(mname, ms)
                n = encode_value(v[mname], ename, ms, buf, n, codec)
            end
        end
        n = n + 1; buf[n] = "</" .. name .. ">"
        return n

    elseif st == stype.LIST then
        local elem_schema = schema.list_member or { type = stype.STRING }
        local flattened = schema:trait(t.XML_FLATTENED)
        if flattened then
            -- Flattened: each item uses the parent element name
            for i = 1, #v do
                n = encode_value(v[i], name, elem_schema, buf, n, codec)
            end
        else
            -- Wrapped: container element, each item in <member> (or xmlName of member)
            local item_name = xml_name("member", elem_schema)
            n = n + 1; buf[n] = "<" .. name .. ">"
            for i = 1, #v do
                n = encode_value(v[i], item_name, elem_schema, buf, n, codec)
            end
            n = n + 1; buf[n] = "</" .. name .. ">"
        end
        return n

    elseif st == stype.MAP then
        local key_schema = schema.map_key or { type = stype.STRING }
        local val_schema = schema.map_value or { type = stype.STRING }
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
        -- Sort keys for deterministic output
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            n = n + 1; buf[n] = "<" .. entry_name .. ">"
            n = n + 1; buf[n] = "<" .. key_name .. ">" .. xml_escape(k) .. "</" .. key_name .. ">"
            n = encode_value(v[k], val_name, val_schema, buf, n, codec)
            n = n + 1; buf[n] = "</" .. entry_name .. ">"
        end
        if not flattened then
            n = n + 1; buf[n] = "</" .. name .. ">"
        end
        return n

    elseif st == stype.UNION then
        n = n + 1; buf[n] = "<" .. name .. ">"
        local members = schema:members() or {}
        for mname, ms in pairs(members) do
            if v[mname] ~= nil then
                local ename = xml_name(mname, ms)
                n = encode_value(v[mname], ename, ms, buf, n, codec)
                break
            end
        end
        n = n + 1; buf[n] = "</" .. name .. ">"
        return n

    else
        -- Simple type
        local ns_extra = ""
        local xns = schema:trait(t.XML_NAMESPACE)
        if xns then
            ns_extra = ns_attr_str(xns)
        end
        n = n + 1; buf[n] = "<" .. name .. ns_extra .. ">" .. xml_escape(simple_value(v, schema, codec)) .. "</" .. name .. ">"
        return n
    end
end

function M.serialize(self, value, schema, root_name)
    root_name = root_name or schema.id or "root"
    local buf = {}
    local ok, n_or_err = pcall(encode_value, value, root_name, schema, buf, 0, self)
    if not ok then
        return nil, { type = "sdk", message = "xml serialize: " .. tostring(n_or_err) }
    end
    return concat(buf, "", 1, n_or_err), nil
end

-- Minimal XML parser: returns a tree of { tag, attrs, children, text }
-- children is array of child nodes, text is concatenated text content
local function parse_xml(s)
    local pos = 1
    local len = #s

    -- Skip XML declaration
    if s:sub(1, 5) == "<?xml" then
        pos = s:find("?>", 1, true)
        if pos then pos = pos + 2 else pos = 1 end
    end

    local function skip_ws()
        local _, e = s:find("^%s+", pos)
        if e then pos = e + 1 end
    end

    local function parse_node()
        skip_ws()
        if pos > len then return nil end

        -- Text content
        if s:byte(pos) ~= 0x3C then -- '<'
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

        -- Closing tag check
        if s:sub(pos, pos + 1) == "</" then return nil end

        -- Opening tag
        local tag_start = pos
        local tag_end = s:find("[%s/>]", pos + 1)
        if not tag_end then return nil end
        local tag = s:sub(pos + 1, tag_end - 1)

        -- Parse attributes
        pos = tag_end
        local attrs = {}
        while true do
            skip_ws()
            if pos > len then break end
            local c = s:byte(pos)
            if c == 0x2F then -- '/'
                pos = pos + 2 -- skip '/>'
                return { tag = tag, attrs = attrs, children = {}, text = "" }
            elseif c == 0x3E then -- '>'
                pos = pos + 1
                break
            else
                local aname_end = s:find("[=%s]", pos)
                if not aname_end then break end
                local aname = s:sub(pos, aname_end - 1)
                pos = aname_end
                skip_ws()
                if s:byte(pos) == 0x3D then pos = pos + 1 end -- '='
                skip_ws()
                local q = s:byte(pos) -- quote char
                pos = pos + 1
                local val_end = s:find(string.char(q), pos, true)
                if val_end then
                    attrs[aname] = s:sub(pos, val_end - 1)
                    pos = val_end + 1
                end
            end
        end

        -- Parse children and text
        local children = {}
        local texts = {}
        while pos <= len do
            skip_ws()
            if pos > len then break end
            if s:sub(pos, pos + 1) == "</" then
                -- Closing tag
                local close_end = s:find(">", pos, true)
                if close_end then pos = close_end + 1 end
                break
            end
            local child = parse_node()
            if child == nil then break end
            if type(child) == "string" then
                texts[#texts + 1] = child
            else
                children[#children + 1] = child
            end
        end

        return { tag = tag, attrs = attrs, children = children, text = table.concat(texts) }
    end

    return parse_node()
end

-- XML unescape
local xml_entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xml_unescape(s)
    return (s:gsub("&(%w+);", function(e) return xml_entities[e] or ("&" .. e .. ";") end)
             :gsub("&#(%d+);", function(n) return string.char(tonumber(n)) end)
             :gsub("&#x(%x+);", function(n) return string.char(tonumber(n, 16)) end))
end

-- Decode a simple value from text
local function decode_simple(text, schema, codec)
    text = xml_unescape(text)
    local st = schema.type
    if st == stype.BOOLEAN then return text == "true" end
    if st == stype.BLOB then return base64_decode(text) end
    if st == stype.TIMESTAMP then
        local n = tonumber(text)
        if n then return n end
        local ts_format = codec.default_timestamp_format
        if schema.trait then
            local tf = schema:trait(t.TIMESTAMP_FORMAT)
            if tf then ts_format = tf.format end
        end
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

-- Decode an XML node using a schema
local function decode_node(node, schema, codec)
    if not node then return nil end
    local st = schema.type

    if st == stype.STRUCTURE then
        local result = {}
        local members = schema:members() or {}
        -- Build lookup: xml_name -> (member_name, member_schema)
        local by_xml = {}
        for mname, ms in pairs(members) do
            by_xml[xml_name(mname, ms)] = { mname, ms }
        end
        -- Attributes
        if node.attrs then
            for aname, aval in pairs(node.attrs) do
                if not aname:match("^xmlns") then
                    local entry = by_xml[aname]
                    if entry and entry[2]:trait(t.XML_ATTRIBUTE) then
                        result[entry[1]] = decode_simple(aval, entry[2], codec)
                    end
                end
            end
        end
        -- Child elements
        -- Group children by tag for list handling
        local children_by_tag = {}
        for _, child in ipairs(node.children or {}) do
            if not children_by_tag[child.tag] then
                children_by_tag[child.tag] = {}
            end
            local tbl = children_by_tag[child.tag]
            tbl[#tbl + 1] = child
        end
        for ename, children in pairs(children_by_tag) do
            local entry = by_xml[ename]
            if entry then
                local ms = entry[2]
                if ms.type == stype.LIST and ms:trait(t.XML_FLATTENED) then
                    -- Flattened list: multiple elements with same tag
                    local list = {}
                    local elem_schema = ms.list_member or { type = stype.STRING }
                    for _, child in ipairs(children) do
                        list[#list + 1] = decode_node(child, elem_schema, codec)
                    end
                    result[entry[1]] = list
                elseif ms.type == stype.MAP and ms:trait(t.XML_FLATTENED) then
                    -- Flattened map: multiple <entry> elements
                    local map = result[entry[1]] or {}
                    local key_schema = ms.map_key or { type = stype.STRING }
                    local val_schema = ms.map_value or { type = stype.STRING }
                    local kn = xml_name("key", key_schema)
                    local vn = xml_name("value", val_schema)
                    for _, child in ipairs(children) do
                        local k, v
                        for _, gc in ipairs(child.children or {}) do
                            if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
                            if gc.tag == vn then v = decode_node(gc, val_schema, codec) end
                        end
                        if k then map[k] = v end
                    end
                    result[entry[1]] = map
                else
                    result[entry[1]] = decode_node(children[1], ms, codec)
                end
            end
        end
        return result

    elseif st == stype.LIST then
        local elem_schema = schema.list_member or { type = stype.STRING }
        local item_name = xml_name("member", elem_schema)
        local result = {}
        for _, child in ipairs(node.children or {}) do
            if child.tag == item_name then
                result[#result + 1] = decode_node(child, elem_schema, codec)
            end
        end
        return result

    elseif st == stype.MAP then
        local key_schema = schema.map_key or { type = stype.STRING }
        local val_schema = schema.map_value or { type = stype.STRING }
        local kn = xml_name("key", key_schema)
        local vn = xml_name("value", val_schema)
        local result = {}
        for _, child in ipairs(node.children or {}) do
            if child.tag == "entry" then
                local k, v
                for _, gc in ipairs(child.children or {}) do
                    if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
                    if gc.tag == vn then v = decode_node(gc, val_schema, codec) end
                end
                if k then result[k] = v end
            end
        end
        return result

    elseif st == stype.UNION then
        local members = schema:members() or {}
        local by_xml = {}
        for mname, ms in pairs(members) do
            by_xml[xml_name(mname, ms)] = { mname, ms }
        end
        local result = {}
        for _, child in ipairs(node.children or {}) do
            local entry = by_xml[child.tag]
            if entry then
                result[entry[1]] = decode_node(child, entry[2], codec)
                break
            end
        end
        return result

    else
        return decode_simple(node.text or "", schema, codec)
    end
end

function M.deserialize(self, bytes, schema, root_name)
    if not bytes or #bytes == 0 then return {}, nil end
    local ok, node = pcall(parse_xml, bytes)
    if not ok then
        return nil, { type = "sdk", message = "xml parse: " .. tostring(node) }
    end
    if not node then
        return nil, { type = "sdk", message = "xml parse: empty document" }
    end
    return decode_node(node, schema, self), nil
end

-- Expose for use by protocols that need raw XML parsing
M.parse_xml = parse_xml
M.xml_unescape = xml_unescape
M.xml_escape = xml_escape
M.decode_node = decode_node

return M
