-- smithy-lua runtime: restXml protocol
-- REST-style protocol with XML body (S3, CloudFront, Route 53).

local json_codec = require("smithy.codec.json")
local xml_codec = require("smithy.codec.xml")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local stype = schema_mod.type

local M = {}
M.__index = M

-- Sentinel for key-only query params (no value, no equals sign)
local KEY_ONLY = {}

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

-- Format a value for query string (handles special floats)
local function format_query_value(v)
    if type(v) == "number" then
        if v ~= v then return "NaN" end
        if v == math.huge then return "Infinity" end
        if v == -math.huge then return "-Infinity" end
    end
    return tostring(v)
end

-- Build query string from a table of key=value pairs
local function build_query(params)
    local parts = {}
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = params[k]
        if v == KEY_ONLY then
            parts[#parts + 1] = uri_encode(k)
        elseif type(v) == "table" then
            for _, item in ipairs(v) do
                parts[#parts + 1] = uri_encode(k) .. "=" .. uri_encode(format_query_value(item))
            end
        elseif v == "" then
            parts[#parts + 1] = uri_encode(k) .. "="
        else
            parts[#parts + 1] = uri_encode(k) .. "=" .. uri_encode(format_query_value(v))
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

-- Format a header value from a typed schema member
local function format_header_value(v, member_schema)
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then
        if v ~= v then return "NaN" end
        if v == math.huge then return "Infinity" end
        if v == -math.huge then return "-Infinity" end
    end
    if member_schema and member_schema.type == stype.TIMESTAMP then
        local ts_format = "http-date"
        local ts_trait = member_schema:trait(t.TIMESTAMP_FORMAT)
        if ts_trait then
            ts_format = ts_trait.format
        end
        if ts_format == "http-date" then
            return json_codec._format_http_date(v)
        elseif ts_format == "date-time" then
            return json_codec._format_iso8601(v)
        else
            if v % 1 == 0 then return string.format("%.0f", v) end
            return tostring(v)
        end
    end
    if member_schema and member_schema:trait(t.MEDIA_TYPE) then
        return json_codec._base64_encode(tostring(v))
    end
    if type(v) == "table" then
        local items = {}
        local elem = member_schema and member_schema.list_member
        for _, item in ipairs(v) do
            if elem and elem.type == stype.TIMESTAMP then
                local tf = "http-date"
                local tf_trait = elem:trait(t.TIMESTAMP_FORMAT)
                if tf_trait then
                    tf = tf_trait.format
                end
                if tf == "http-date" then
                    items[#items + 1] = json_codec._format_http_date(item)
                elseif tf == "date-time" then
                    items[#items + 1] = json_codec._format_iso8601(item)
                else
                    if item % 1 == 0 then items[#items + 1] = string.format("%.0f", item)
                    else items[#items + 1] = tostring(item) end
                end
            else
                local s = tostring(item)
                if s:find('[,"]') then
                    items[#items + 1] = '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
                else
                    items[#items + 1] = s
                end
            end
        end
        return table.concat(items, ", ")
    end
    return tostring(v)
end

-- Parse a header value into a typed Lua value
local function parse_header_value(v, member_schema)
    if member_schema.type == stype.BOOLEAN then
        return (v == "true")
    elseif member_schema.type == stype.TIMESTAMP then
        local ts_format = "http-date"
        local ts_trait = member_schema:trait(t.TIMESTAMP_FORMAT)
        if ts_trait then
            ts_format = ts_trait.format
        end
        if ts_format == "http-date" then
            local dt = {}
            dt.day, dt.month, dt.year, dt.hour, dt.min, dt.sec = v:match(
                "%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
            if not dt.day then return tonumber(v) end
            local months = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
            dt.month = months[dt.month] or 1
            dt.year = tonumber(dt.year); dt.day = tonumber(dt.day)
            dt.hour = tonumber(dt.hour); dt.min = tonumber(dt.min); dt.sec = tonumber(dt.sec)
            dt.isdst = false
            local epoch = os.time(dt)
            local utc_offset = os.time(os.date("!*t", 0)) - os.time(os.date("*t", 0))
            return epoch - utc_offset
        elseif ts_format == "date-time" then
            return json_codec._parse_iso8601(v)
        else
            return tonumber(v)
        end
    elseif member_schema:trait(t.MEDIA_TYPE) then
        return json_codec._base64_decode(v)
    elseif member_schema.type == stype.INTEGER or member_schema.type == stype.LONG
        or member_schema.type == stype.FLOAT or member_schema.type == stype.DOUBLE
        or member_schema.type == stype.SHORT or member_schema.type == stype.BYTE then
        return tonumber(v)
    elseif member_schema.type == stype.LIST then
        local items = {}
        local i = 1
        while i <= #v do
            while i <= #v and v:sub(i,i) == " " do i = i + 1 end
            if i > #v then break end
            if v:sub(i,i) == '"' then
                i = i + 1
                local s = {}
                while i <= #v and v:sub(i,i) ~= '"' do
                    if v:sub(i,i) == '\\' then i = i + 1 end
                    s[#s+1] = v:sub(i,i)
                    i = i + 1
                end
                i = i + 1
                items[#items+1] = table.concat(s)
            else
                local j = v:find(",", i)
                if j then
                    items[#items+1] = v:sub(i, j-1):match("^%s*(.-)%s*$")
                    i = j
                else
                    items[#items+1] = v:sub(i):match("^%s*(.-)%s*$")
                    i = #v + 1
                end
            end
            while i <= #v and (v:sub(i,i) == "," or v:sub(i,i) == " ") do i = i + 1 end
        end
        local elem = member_schema.list_member
        if elem then
            for idx, item in ipairs(items) do
                if elem.type == stype.INTEGER or elem.type == stype.LONG or elem.type == stype.SHORT
                    or elem.type == stype.BYTE or elem.type == stype.FLOAT or elem.type == stype.DOUBLE then
                    items[idx] = tonumber(item)
                elseif elem.type == stype.BOOLEAN then
                    items[idx] = (item == "true")
                elseif elem.type == stype.TIMESTAMP then
                    local tf = "http-date"
                    local tf_trait = elem:trait(t.TIMESTAMP_FORMAT)
                    if tf_trait then
                        tf = tf_trait.format
                    end
                    if tf == "http-date" then
                        local dt = {}
                        dt.day, dt.month, dt.year, dt.hour, dt.min, dt.sec = item:match(
                            "%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
                        if dt.day then
                            local months = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
                            dt.month = months[dt.month] or 1
                            dt.year = tonumber(dt.year); dt.day = tonumber(dt.day)
                            dt.hour = tonumber(dt.hour); dt.min = tonumber(dt.min); dt.sec = tonumber(dt.sec)
                            dt.isdst = false
                            local epoch = os.time(dt)
                            local utc_offset = os.time(os.date("!*t", 0)) - os.time(os.date("*t", 0))
                            items[idx] = epoch - utc_offset
                        else
                            items[idx] = tonumber(item) or item
                        end
                    elseif tf == "date-time" then
                        items[idx] = json_codec._parse_iso8601(item)
                    else
                        items[idx] = tonumber(item) or item
                    end
                end
            end
        end
        return items
    else
        return v
    end
end

function M.serialize(self, input, operation)
    input = input or {}
    local schema = operation.input_schema
    local members = schema and schema:members() or {}

    -- Auto-fill idempotency tokens
    for name, ms in pairs(members) do
        if ms:trait(t.IDEMPOTENCY_TOKEN) and input[name] == nil then
            input[name] = "00000000-0000-4000-8000-000000000000"
        end
    end

    local labels = {}
    local query = {}
    local headers = {}
    local payload_name, payload_schema
    local body_members = {}

    -- First pass: prefix headers
    for name, ms in pairs(members) do
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS)
        if pfx then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name]) do
                    headers[pfx.prefix .. k] = tostring(v)
                end
            end
        end
    end
    -- Second pass: all other bindings (specific headers override prefix)
    for name, ms in pairs(members) do
        local lbl = ms:trait(t.HTTP_LABEL)
        local qry = ms:trait(t.HTTP_QUERY)
        local qp = ms:trait(t.HTTP_QUERY_PARAMS)
        local hdr = ms:trait(t.HTTP_HEADER)
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS)
        local pld = ms:trait(t.HTTP_PAYLOAD)

        if lbl then
            local lv = input[name]
            if ms.type == stype.TIMESTAMP and type(lv) == "number" then
                local ts_trait = ms:trait(t.TIMESTAMP_FORMAT)
                local tf = ts_trait and ts_trait.format or "date-time"
                if tf == "date-time" then
                    lv = json_codec._format_iso8601(lv)
                elseif tf == "http-date" then
                    lv = json_codec._format_http_date(lv)
                end
            elseif type(lv) == "number" then
                if lv ~= lv then lv = "NaN"
                elseif lv == math.huge then lv = "Infinity"
                elseif lv == -math.huge then lv = "-Infinity"
                end
            end
            labels[name] = lv
        elseif qry then
            if input[name] ~= nil then
                local qv = input[name]
                if ms.type == stype.TIMESTAMP then
                    local ts_trait = ms:trait(t.TIMESTAMP_FORMAT)
                    local tf = ts_trait and ts_trait.format or "date-time"
                    if tf == "date-time" then
                        qv = json_codec._format_iso8601(qv)
                    elseif tf == "http-date" then
                        qv = json_codec._format_http_date(qv)
                    end
                elseif ms.type == stype.LIST and ms.list_member and ms.list_member.type == stype.TIMESTAMP then
                    local tf_trait = ms.list_member:trait(t.TIMESTAMP_FORMAT)
                    local tf = tf_trait and tf_trait.format or "date-time"
                    local formatted = {}
                    for _, item in ipairs(qv) do
                        if tf == "date-time" then
                            formatted[#formatted+1] = json_codec._format_iso8601(item)
                        elseif tf == "http-date" then
                            formatted[#formatted+1] = json_codec._format_http_date(item)
                        else
                            formatted[#formatted+1] = item
                        end
                    end
                    qv = formatted
                end
                query[qry.name] = qv
            end
        elseif qp then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name]) do
                    if not query[k] then query[k] = v end
                end
            end
        elseif hdr then
            if input[name] ~= nil then
                headers[hdr.name] = format_header_value(input[name], ms)
            end
        elseif pfx then
            -- Already handled in first pass
        elseif pld then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    -- Build URL: merge constant query params from path template with dynamic ones
    local path = expand_path(operation.http_path or "/", labels)
    local base_path, existing_qs = path:match("^([^?]*)%??(.*)")
    if existing_qs and #existing_qs > 0 then
        for pair in existing_qs:gmatch("[^&]+") do
            local k, eq, v = pair:match("^([^=]*)(=?)(.*)")
            if k and not query[k] then
                if eq == "=" then
                    query[k] = v
                else
                    query[k] = KEY_ONLY
                end
            end
        end
    end
    local qs = build_query(query)
    local url = base_path .. qs

    -- Build body
    local body_str
    if payload_name then
        local v = input[payload_name]
        if v == nil then
            if payload_schema.type == stype.STRUCTURE then
                -- Serialize as empty XML root element
                local xml_name = payload_schema:trait(t.XML_NAME)
                local root = xml_name and xml_name.name or payload_name
                body_str = "<" .. root .. "/>"
            else
                body_str = ""
            end
        elseif payload_schema.type == stype.STRUCTURE or payload_schema.type == stype.UNION then
            headers["Content-Type"] = "application/xml"
            -- Root element: member XML_NAME > target XML_NAME > target id name > member name
            local target_schema = payload_schema._target or payload_schema
            local xml_name_trait = payload_schema:trait(t.XML_NAME) or target_schema:trait(t.XML_NAME)
            local root = (xml_name_trait and xml_name_trait.name)
                or (target_schema.id and target_schema.id.name)
                or payload_name
            local err
            body_str, err = self.codec:serialize(v, payload_schema, root)
            if err then return nil, err end
        elseif payload_schema.type == stype.DOCUMENT then
            body_str = require("smithy.json.encoder").encode(v)
        elseif payload_schema.type == stype.BLOB then
            body_str = v
            local mt = payload_schema:trait(t.MEDIA_TYPE)
            if mt then
                headers["Content-Type"] = mt.value
            elseif not headers["Content-Type"] then
                headers["Content-Type"] = "application/octet-stream"
            end
        elseif payload_schema.type == stype.STRING or payload_schema.type == stype.ENUM then
            body_str = tostring(v)
            headers["Content-Type"] = "text/plain"
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
            local xml_name = schema:trait(t.XML_NAME)
            local root = xml_name and xml_name.name or (schema.id and schema.id.name) or "root"
            local body_schema = schema_mod.new({ type = stype.STRUCTURE, members = body_members, traits = schema._traits })
            local err
            body_str, err = self.codec:serialize(input, body_schema, root)
            if err then return nil, err end
        elseif next(body_members) then
            -- Body members exist but all nil — send Content-Type + empty body
            headers["Content-Type"] = "application/xml"
            body_str = ""
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
    local members = schema and schema:members() or {}
    local output = {}

    local payload_name, payload_schema
    local body_members = {}

    for name, ms in pairs(members) do
        local rc = ms:trait(t.HTTP_RESPONSE_CODE)
        local hdr = ms:trait(t.HTTP_HEADER)
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS)
        local pld = ms:trait(t.HTTP_PAYLOAD)

        if rc then
            output[name] = response.status_code
        elseif hdr then
            local v = response.headers and (response.headers[hdr.name] or response.headers[hdr.name:lower()])
            if v ~= nil then
                output[name] = parse_header_value(v, ms)
            end
        elseif pfx then
            local prefix = pfx.prefix:lower()
            local map = {}
            if response.headers then
                for k, v in pairs(response.headers) do
                    if k:lower():sub(1, #prefix) == prefix then
                        map[k:sub(#prefix + 1)] = v
                    end
                end
            end
            output[name] = map
        elseif pld then
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
            elseif payload_schema.type == stype.DOCUMENT then
                output[payload_name] = require("smithy.json.decoder").decode(body_str)
            elseif payload_schema.type == stype.BLOB or payload_schema.type == stype.STRING then
                output[payload_name] = body_str
            else
                output[payload_name] = body_str
            end
        end
    elseif body_str and #body_str > 0 then
        local body_schema = schema_mod.new({ type = stype.STRUCTURE, members = body_members })
        local decoded, err = self.codec:deserialize(body_str, body_schema)
        if err then return nil, err end
        for k, v in pairs(decoded) do output[k] = v end
    end

    return output, nil
end

return M
