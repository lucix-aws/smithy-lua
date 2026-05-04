-- smithy-lua runtime: restJson1 protocol
-- Implements the ClientProtocol interface with full HTTP binding support.

local json_codec = require("smithy.codec.json")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local strait = schema_mod.trait

local M = {}
M.__index = M

-- Sentinel for key-only query params (no value, no equals sign)
local KEY_ONLY = {}

function M.new(settings)
    return setmetatable({
        codec = json_codec.new({
            use_json_name = true,
            default_timestamp_format = schema_mod.timestamp.EPOCH_SECONDS,
        }),
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

-- Expand a URI path template with label values
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
        if type(v) == "table" then
            for _, item in ipairs(v) do
                parts[#parts + 1] = uri_encode(k) .. "=" .. uri_encode(format_query_value(item))
            end
        elseif v == "" then
            parts[#parts + 1] = uri_encode(k) .. "="
        elseif v == KEY_ONLY then
            parts[#parts + 1] = uri_encode(k)
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
    if member_schema and member_schema.type == "timestamp" then
        -- Default header timestamp format is http-date (RFC 7231)
        local ts_format = "http-date"
        if member_schema.traits and member_schema.traits[strait.TIMESTAMP_FORMAT] then
            ts_format = member_schema.traits[strait.TIMESTAMP_FORMAT]
        end
        if ts_format == "http-date" then
            return json_codec._format_http_date(v)
        elseif ts_format == "date-time" then
            return json_codec._format_iso8601(v)
        else
            -- epoch-seconds
            if v % 1 == 0 then return string.format("%.0f", v) end
            return tostring(v)
        end
    end
    if member_schema and member_schema.traits and member_schema.traits[strait.MEDIA_TYPE] then
        -- @mediaType: base64-encode the value for header transport
        return json_codec._base64_encode(tostring(v))
    end
    if type(v) == "table" then
        -- list header: comma-separated, quote items containing commas or quotes
        local items = {}
        local elem = member_schema and member_schema.member
        for _, item in ipairs(v) do
            if elem and elem.type == "timestamp" then
                -- Format each timestamp in the list
                local tf = "http-date"
                if elem.traits and elem.traits[strait.TIMESTAMP_FORMAT] then
                    tf = elem.traits[strait.TIMESTAMP_FORMAT]
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
    if member_schema.type == "boolean" then
        return (v == "true")
    elseif member_schema.type == "timestamp" then
        local ts_format = "http-date"
        if member_schema.traits and member_schema.traits[strait.TIMESTAMP_FORMAT] then
            ts_format = member_schema.traits[strait.TIMESTAMP_FORMAT]
        end
        if ts_format == "http-date" then
            -- Parse RFC 7231 date
            local t = {}
            t.day, t.month, t.year, t.hour, t.min, t.sec = v:match(
                "%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
            if not t.day then return tonumber(v) end
            local months = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
            t.month = months[t.month] or 1
            t.year = tonumber(t.year); t.day = tonumber(t.day)
            t.hour = tonumber(t.hour); t.min = tonumber(t.min); t.sec = tonumber(t.sec)
            t.isdst = false
            local epoch = os.time(t)
            local utc_offset = os.time(os.date("!*t", 0)) - os.time(os.date("*t", 0))
            return epoch - utc_offset
        elseif ts_format == "date-time" then
            return json_codec._parse_iso8601(v)
        else
            return tonumber(v)
        end
    elseif member_schema.traits and member_schema.traits[strait.MEDIA_TYPE] then
        return json_codec._base64_decode(v)
    elseif member_schema.type == "number" or member_schema.type == "integer"
        or member_schema.type == "long" or member_schema.type == "float"
        or member_schema.type == "double" or member_schema.type == "short"
        or member_schema.type == "byte" then
        return tonumber(v)
    elseif member_schema.type == "list" then
        -- Parse comma-separated header list, respecting quoted strings
        local items = {}
        local i = 1
        while i <= #v do
            -- skip whitespace
            while i <= #v and v:sub(i,i) == " " do i = i + 1 end
            if i > #v then break end
            if v:sub(i,i) == '"' then
                -- quoted string
                i = i + 1
                local s = {}
                while i <= #v and v:sub(i,i) ~= '"' do
                    if v:sub(i,i) == '\\' then i = i + 1 end
                    s[#s+1] = v:sub(i,i)
                    i = i + 1
                end
                i = i + 1 -- skip closing quote
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
            -- skip comma
            while i <= #v and (v:sub(i,i) == "," or v:sub(i,i) == " ") do i = i + 1 end
        end
        -- Convert items based on member element type
        local elem = member_schema.member
        if elem then
            for idx, item in ipairs(items) do
                if elem.type == "integer" or elem.type == "long" or elem.type == "short"
                    or elem.type == "byte" or elem.type == "float" or elem.type == "double" then
                    items[idx] = tonumber(item)
                elseif elem.type == "boolean" then
                    items[idx] = (item == "true")
                elseif elem.type == "timestamp" then
                    local tf = "http-date"
                    if elem.traits and elem.traits[strait.TIMESTAMP_FORMAT] then
                        tf = elem.traits[strait.TIMESTAMP_FORMAT]
                    end
                    if tf == "http-date" then
                        -- individual items in a list header are not full http-date
                        items[idx] = tonumber(item) or item
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
    local members = schema and schema.members or {}

    local labels = {}
    local query = {}
    local headers = {
        ["Content-Type"] = "application/json",
    }
    local payload_name, payload_schema
    local body_members = {}

    -- Partition members by HTTP binding (two passes: prefix headers first, then specific headers)
    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_PREFIX_HEADERS] then
            if type(input[name]) == "table" then
                local prefix = t[strait.HTTP_PREFIX_HEADERS]
                for k, v in pairs(input[name]) do
                    headers[prefix .. k] = tostring(v)
                end
            end
        end
    end
    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_LABEL] then
            local lv = input[name]
            -- Format timestamps in labels
            if ms.type == "timestamp" and type(lv) == "number" then
                local tf = (t[strait.TIMESTAMP_FORMAT]) or "date-time"
                if tf == "date-time" then
                    lv = json_codec._format_iso8601(lv)
                elseif tf == "http-date" then
                    lv = json_codec._format_http_date(lv)
                end
            elseif type(lv) == "number" then
                -- Handle special float values
                if lv ~= lv then lv = "NaN"
                elseif lv == math.huge then lv = "Infinity"
                elseif lv == -math.huge then lv = "-Infinity"
                end
            end
            labels[name] = lv
        elseif t and t[strait.HTTP_QUERY] then
            if input[name] ~= nil then
                local qv = input[name]
                -- Format timestamps as ISO 8601 for query strings
                if ms.type == "timestamp" then
                    local tf = t[strait.TIMESTAMP_FORMAT] or "date-time"
                    if tf == "date-time" then
                        qv = json_codec._format_iso8601(qv)
                    elseif tf == "http-date" then
                        qv = json_codec._format_http_date(qv)
                    end
                elseif ms.type == "list" and ms.member and ms.member.type == "timestamp" then
                    local tf = (ms.member.traits and ms.member.traits[strait.TIMESTAMP_FORMAT]) or "date-time"
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
                query[t[strait.HTTP_QUERY]] = qv
            end
        elseif t and t[strait.HTTP_QUERY_PARAMS] then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name]) do
                    if not query[k] then query[k] = v end
                end
            end
        elseif t and t[strait.HTTP_HEADER] then
            if input[name] ~= nil then
                headers[t[strait.HTTP_HEADER]] = format_header_value(input[name], ms)
            end
        elseif t and t[strait.HTTP_PREFIX_HEADERS] then
            -- Already handled in first pass
        elseif t and t[strait.HTTP_PAYLOAD] then
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
        -- Constant query params from URI template always present
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
            if payload_schema.type == "structure" then
                body_str = "{}"
            else
                body_str = ""
            end
        elseif payload_schema.type == "structure" or payload_schema.type == "union" then
            local err
            body_str, err = self.codec:serialize(v, payload_schema)
            if err then return nil, err end
        elseif payload_schema.type == "document" then
            body_str = require("smithy.json.encoder").encode(v)
        elseif payload_schema.type == "blob" then
            body_str = v
            -- Use @mediaType if present, then check if header member already set it
            local mt = payload_schema.traits and payload_schema.traits[strait.MEDIA_TYPE]
            if mt then
                headers["Content-Type"] = mt
            elseif headers["Content-Type"] == "application/json" then
                headers["Content-Type"] = "application/octet-stream"
            end
        elseif payload_schema.type == "string" or payload_schema.type == "enum" then
            body_str = tostring(v)
            headers["Content-Type"] = "text/plain"
        else
            body_str = tostring(v)
        end
    else
        -- Check if there are any body members with values
        local has_body = false
        for name in pairs(body_members) do
            if input[name] ~= nil then has_body = true; break end
        end
        if has_body then
            local body_schema = { type = schema_mod.type.STRUCTURE, members = body_members }
            local err
            body_str, err = self.codec:serialize(input, body_schema)
            if err then return nil, err end
        elseif next(body_members) then
            -- Body members exist but all nil — send empty JSON object
            body_str = "{}"
        else
            body_str = ""
            headers["Content-Type"] = nil
        end
    end

    return http.new_request(
        operation.http_method or "POST",
        url,
        headers,
        http.string_reader(body_str)
    ), nil
end

--- Extract error code from response (same pattern as awsJson).
local function parse_error_code(response, body_table)
    local header = response.headers and (
        response.headers["x-amzn-errortype"] or
        response.headers["X-Amzn-Errortype"]
    )
    if header then
        return header:match("^([^:]+)") or header
    end
    if body_table then
        local code = body_table["__type"] or body_table["code"] or body_table["Code"]
        if code then
            return code:match("#(.+)$") or code
        end
    end
    return "UnknownError"
end

function M.deserialize(self, response, operation)
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    -- Error response
    if response.status_code < 200 or response.status_code >= 300 then
        local body_table
        if body_str and #body_str > 0 then
            local raw = require("smithy.json.decoder").decode(body_str)
            if type(raw) == "table" then body_table = raw end
        end
        local code = parse_error_code(response, body_table)
        local message = ""
        if body_table then
            message = body_table["message"] or body_table["Message"]
                or body_table["errorMessage"] or ""
        end
        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    -- Success: deserialize output
    local schema = operation.output_schema
    local members = schema and schema.members or {}
    local output = {}

    local payload_name, payload_schema
    local body_members = {}

    -- Partition output members by binding
    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_RESPONSE_CODE] then
            output[name] = response.status_code
        elseif t and t[strait.HTTP_HEADER] then
            local hdr = t[strait.HTTP_HEADER]
            local v = response.headers and (response.headers[hdr] or response.headers[hdr:lower()])
            if v ~= nil then
                output[name] = parse_header_value(v, ms)
            end
        elseif t and t[strait.HTTP_PREFIX_HEADERS] then
            local prefix = t[strait.HTTP_PREFIX_HEADERS]:lower()
            local map = {}
            if response.headers then
                for k, v in pairs(response.headers) do
                    if k:lower():sub(1, #prefix) == prefix then
                        map[k:sub(#prefix + 1)] = v
                    end
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

    -- Deserialize body
    if payload_name then
        if body_str and #body_str > 0 then
            if payload_schema.type == "structure" or payload_schema.type == "union" then
                local v, err = self.codec:deserialize(body_str, payload_schema)
                if err then return nil, err end
                output[payload_name] = v
            elseif payload_schema.type == "document" then
                output[payload_name] = require("smithy.json.decoder").decode(body_str)
            elseif payload_schema.type == "blob" or payload_schema.type == "string" then
                output[payload_name] = body_str
            else
                output[payload_name] = body_str
            end
        end
    elseif body_str and #body_str > 0 then
        local body_schema = { type = schema_mod.type.STRUCTURE, members = body_members }
        local decoded, err = self.codec:deserialize(body_str, body_schema)
        if err then return nil, err end
        for k, v in pairs(decoded) do
            output[k] = v
        end
    end

    return output, nil
end

return M
