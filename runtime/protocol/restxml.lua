-- smithy-lua runtime: restXml protocol
-- REST-style protocol with XML body (S3, CloudFront, Route 53).

local xml_codec = require("codec.xml")
local http = require("http")
local schema_mod = require("schema")
local strait = schema_mod.trait
local stype = schema_mod.type

local M = {}
M.__index = M

function M.new(settings)
    settings = settings or {}
    return setmetatable({
        codec = xml_codec.new({
            default_timestamp_format = schema_mod.timestamp.DATE_TIME,
        }),
        no_error_wrapping = settings.no_error_wrapping or false,
    }, M)
end

-- URI-encode a value. greedy labels ({Key+}) skip '/'
local function uri_encode(s, greedy)
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)
            or (c >= 0x30 and c <= 0x39) or c == 0x2D or c == 0x5F
            or c == 0x2E or c == 0x7E then
            out[#out + 1] = string.char(c)
        elseif c == 0x2F and greedy then
            out[#out + 1] = "/"
        else
            out[#out + 1] = string.format("%%%02X", c)
        end
    end
    return table.concat(out)
end

local function expand_path(template, labels)
    return (template:gsub("{([^}]+)}", function(label)
        local greedy = label:sub(-1) == "+"
        local name = greedy and label:sub(1, -2) or label
        local v = labels[name]
        if v == nil then return "" end
        return uri_encode(v, greedy)
    end))
end

local function build_query(params)
    local parts = {}
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = params[k]
        if type(v) == "table" then
            for _, item in ipairs(v) do
                parts[#parts + 1] = uri_encode(k) .. "=" .. uri_encode(tostring(item))
            end
        else
            parts[#parts + 1] = uri_encode(k) .. "=" .. uri_encode(tostring(v))
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

local function format_header_value(v, member_schema)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "table" then
        local items = {}
        for _, item in ipairs(v) do items[#items + 1] = tostring(item) end
        return table.concat(items, ", ")
    end
    return tostring(v)
end

function M.serialize(self, input, operation)
    input = input or {}
    local schema = operation.input_schema
    local members = schema and schema.members or {}

    local labels = {}
    local query = {}
    local headers = {}
    local payload_name, payload_schema
    local body_members = {}

    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_LABEL] then
            labels[name] = input[name]
        elseif t and t[strait.HTTP_QUERY] then
            if input[name] ~= nil then query[t[strait.HTTP_QUERY]] = input[name] end
        elseif t and t[strait.HTTP_QUERY_PARAMS] then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name]) do query[k] = v end
            end
        elseif t and t[strait.HTTP_HEADER] then
            if input[name] ~= nil then
                headers[t[strait.HTTP_HEADER]] = format_header_value(input[name], ms)
            end
        elseif t and t[strait.HTTP_PREFIX_HEADERS] then
            if type(input[name]) == "table" then
                local prefix = t[strait.HTTP_PREFIX_HEADERS]
                for k, v in pairs(input[name]) do headers[prefix .. k] = tostring(v) end
            end
        elseif t and t[strait.HTTP_PAYLOAD] then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    local path = expand_path(operation.http_path or "/", labels)
    local qs = build_query(query)
    local url = path .. qs

    local body_str
    if payload_name then
        local v = input[payload_name]
        if v == nil then
            body_str = ""
        elseif payload_schema.type == stype.STRUCTURE or payload_schema.type == stype.UNION then
            headers["Content-Type"] = "application/xml"
            local root = payload_schema.traits and payload_schema.traits[strait.XML_NAME] or payload_name
            local err
            body_str, err = self.codec:serialize(v, payload_schema, root)
            if err then return nil, err end
        elseif payload_schema.type == stype.BLOB then
            body_str = v
            headers["Content-Type"] = headers["Content-Type"] or "application/octet-stream"
        else
            body_str = tostring(v)
        end
    else
        local has_body = false
        for name in pairs(body_members) do
            if input[name] ~= nil then has_body = true; break end
        end
        if has_body then
            headers["Content-Type"] = "application/xml"
            local body_schema = { type = stype.STRUCTURE, members = body_members, traits = schema.traits }
            local root = schema.traits and schema.traits[strait.XML_NAME] or schema.id or "root"
            local err
            body_str, err = self.codec:serialize(input, body_schema, root)
            if err then return nil, err end
        else
            body_str = ""
        end
    end

    return http.new_request(
        operation.http_method or "POST",
        url,
        headers,
        http.string_reader(body_str)
    ), nil
end

-- Parse error from XML response
local function parse_xml_error(body_str, no_error_wrapping)
    if not body_str or #body_str == 0 then return "UnknownError", "" end
    local node = xml_codec.parse_xml(body_str)
    if not node then return "UnknownError", "" end

    local error_node
    if no_error_wrapping then
        -- <Error> is root
        error_node = node
    else
        -- <ErrorResponse><Error>...</Error></ErrorResponse>
        for _, child in ipairs(node.children or {}) do
            if child.tag == "Error" then error_node = child; break end
        end
    end

    local code, message = "UnknownError", ""
    if error_node then
        for _, child in ipairs(error_node.children or {}) do
            if child.tag == "Code" then code = child.text or code end
            if child.tag == "Message" or child.tag == "message" then message = child.text or message end
        end
    end
    return code, message
end

function M.deserialize(self, response, operation)
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local code, message = parse_xml_error(body_str, self.no_error_wrapping)
        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    local schema = operation.output_schema
    local members = schema and schema.members or {}
    local output = {}

    local payload_name, payload_schema
    local body_members = {}

    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_RESPONSE_CODE] then
            output[name] = response.status_code
        elseif t and t[strait.HTTP_HEADER] then
            local hdr = t[strait.HTTP_HEADER]
            local v = response.headers and (response.headers[hdr] or response.headers[hdr:lower()])
            if v ~= nil then
                if ms.type == stype.BOOLEAN then output[name] = (v == "true")
                elseif ms.type == stype.INTEGER or ms.type == stype.LONG or ms.type == stype.FLOAT
                    or ms.type == stype.DOUBLE or ms.type == stype.SHORT or ms.type == stype.BYTE then
                    output[name] = tonumber(v)
                else output[name] = v end
            end
        elseif t and t[strait.HTTP_PREFIX_HEADERS] then
            local prefix = t[strait.HTTP_PREFIX_HEADERS]:lower()
            local map = {}
            if response.headers then
                for k, v in pairs(response.headers) do
                    if k:lower():sub(1, #prefix) == prefix then map[k:sub(#prefix + 1)] = v end
                end
            end
            if next(map) then output[name] = map end
        elseif t and t[strait.HTTP_PAYLOAD] then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    if payload_name then
        if body_str and #body_str > 0 then
            if payload_schema.type == stype.STRUCTURE or payload_schema.type == stype.UNION then
                local v, err = self.codec:deserialize(body_str, payload_schema)
                if err then return nil, err end
                output[payload_name] = v
            elseif payload_schema.type == stype.BLOB or payload_schema.type == stype.STRING then
                output[payload_name] = body_str
            else
                output[payload_name] = body_str
            end
        end
    elseif body_str and #body_str > 0 then
        local body_schema = { type = stype.STRUCTURE, members = body_members }
        local decoded, err = self.codec:deserialize(body_str, body_schema)
        if err then return nil, err end
        for k, v in pairs(decoded) do output[k] = v end
    end

    return output, nil
end

return M
