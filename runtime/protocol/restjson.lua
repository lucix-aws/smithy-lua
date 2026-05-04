-- smithy-lua runtime: restJson1 protocol
-- Implements the ClientProtocol interface with full HTTP binding support.

local json_codec = require("codec.json")
local http = require("http")
local schema_mod = require("schema")
local strait = schema_mod.trait

local M = {}
M.__index = M

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

-- Build query string from a table of key=value pairs
local function build_query(params)
    local parts = {}
    -- Sort for deterministic output
    local keys = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = params[k]
        if type(v) == "table" then
            -- list-valued query param
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

-- Format a header value from a typed schema member
local function format_header_value(v, member_schema)
    if type(v) == "boolean" then return v and "true" or "false" end
    if member_schema and member_schema.type == "timestamp" then
        -- Default header timestamp format is RFC 7231 (http-date)
        -- For now, just use the numeric epoch value as a string
        return tostring(v)
    end
    if type(v) == "table" then
        -- list header: comma-separated
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
    local headers = {
        ["Content-Type"] = "application/json",
    }
    local payload_name, payload_schema
    local body_members = {}

    -- Partition members by HTTP binding
    for name, ms in pairs(members) do
        local t = ms.traits
        if t and t[strait.HTTP_LABEL] then
            labels[name] = input[name]
        elseif t and t[strait.HTTP_QUERY] then
            if input[name] ~= nil then
                query[t[strait.HTTP_QUERY]] = input[name]
            end
        elseif t and t[strait.HTTP_QUERY_PARAMS] then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name]) do
                    query[k] = v
                end
            end
        elseif t and t[strait.HTTP_HEADER] then
            if input[name] ~= nil then
                headers[t[strait.HTTP_HEADER]] = format_header_value(input[name], ms)
            end
        elseif t and t[strait.HTTP_PREFIX_HEADERS] then
            if type(input[name]) == "table" then
                local prefix = t[strait.HTTP_PREFIX_HEADERS]
                for k, v in pairs(input[name]) do
                    headers[prefix .. k] = tostring(v)
                end
            end
        elseif t and t[strait.HTTP_PAYLOAD] then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    -- Build URL
    local path = expand_path(operation.http_path or "/", labels)
    local qs = build_query(query)
    local url = path .. qs

    -- Build body
    local body_str
    if payload_name then
        local v = input[payload_name]
        if v == nil then
            body_str = ""
        elseif payload_schema.type == "structure" or payload_schema.type == "union" then
            local err
            body_str, err = self.codec:serialize(v, payload_schema)
            if err then return nil, err end
        elseif payload_schema.type == "blob" then
            body_str = v
            if not headers["Content-Type"] or headers["Content-Type"] == "application/json" then
                headers["Content-Type"] = "application/octet-stream"
            end
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
            local raw = require("json.decoder").decode(body_str)
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
                if ms.type == "boolean" then
                    output[name] = (v == "true")
                elseif ms.type == "number" or ms.type == "integer" or ms.type == "long"
                    or ms.type == "float" or ms.type == "double"
                    or ms.type == "short" or ms.type == "byte" then
                    output[name] = tonumber(v)
                else
                    output[name] = v
                end
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
