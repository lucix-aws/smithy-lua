-- smithy-lua runtime: awsQuery protocol
-- RPC-style protocol with form-urlencoded request, XML response (STS, IAM, etc.).

local xml_codec = require("smithy.codec.xml")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local stype = schema_mod.type

local M = {}
M.__index = M

function M.new(settings)
    settings = settings or {}
    return setmetatable({
        version = settings.version or "",
        xml = xml_codec.new({ default_timestamp_format = schema_mod.timestamp.DATE_TIME }),
        -- ec2 mode: always-flattened lists, capitalize keys, no Result wrapper,
        -- different error format
        ec2 = settings.ec2 or false,
    }, M)
end

-- Percent-encode per RFC 3986
local function pct_encode(s)
    return (tostring(s):gsub("[^A-Za-z0-9_.~-]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- Capitalize first letter of a string
local function capitalize(s)
    if #s == 0 then return s end
    return s:sub(1, 1):upper() .. s:sub(2)
end

-- Get the query key name for a member
local function query_key(name, ms, ec2)
    if ec2 then
        local ec2qn = ms:trait(t.EC2_QUERY_NAME)
        if ec2qn then return ec2qn.name end
        local xn = ms:trait(t.XML_NAME)
        if xn then return capitalize(xn.name) end
        return capitalize(name)
    else
        local xn = ms:trait(t.XML_NAME)
        if xn then return xn.name end
        return name
    end
end

-- Serialize a value into query params. prefix is the key prefix (e.g. "Foo.Bar")
local function serialize_query(v, prefix, schema, params, ec2)
    if v == nil then return end
    local st = schema.type

    if st == stype.STRUCTURE then
        local members = schema:members()
        for mname, ms in pairs(members) do
            if v[mname] ~= nil then
                local key = query_key(mname, ms, ec2)
                serialize_query(v[mname], prefix == "" and key or (prefix .. "." .. key), ms, params, ec2)
            end
        end

    elseif st == stype.LIST then
        local elem_schema = schema.list_member or { type = stype.STRING }
        local flattened = ec2 or schema:trait(t.XML_FLATTENED)
        if flattened then
            for i = 1, #v do
                serialize_query(v[i], prefix .. "." .. i, elem_schema, params, ec2)
            end
        else
            local member_label = "member"
            local xn = elem_schema.trait and elem_schema:trait(t.XML_NAME)
            if xn then
                member_label = xn.name
            end
            for i = 1, #v do
                serialize_query(v[i], prefix .. "." .. member_label .. "." .. i, elem_schema, params, ec2)
            end
        end

    elseif st == stype.MAP then
        local key_schema = schema.map_key or { type = stype.STRING }
        local val_schema = schema.map_value or { type = stype.STRING }
        local flattened = schema:trait(t.XML_FLATTENED)
        local key_xn = key_schema.trait and key_schema:trait(t.XML_NAME)
        local val_xn = val_schema.trait and val_schema:trait(t.XML_NAME)
        local key_label = key_xn and key_xn.name or "key"
        local val_label = val_xn and val_xn.name or "value"
        -- Sort for deterministic output
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        for i, k in ipairs(keys) do
            local entry_prefix
            if flattened then
                entry_prefix = prefix .. "." .. i
            else
                entry_prefix = prefix .. ".entry." .. i
            end
            params[#params + 1] = pct_encode(entry_prefix .. "." .. key_label) .. "=" .. pct_encode(k)
            serialize_query(v[k], entry_prefix .. "." .. val_label, val_schema, params, ec2)
        end
        return -- already added to params

    elseif st == stype.BOOLEAN then
        params[#params + 1] = pct_encode(prefix) .. "=" .. (v and "true" or "false")
        return

    elseif st == stype.BLOB then
        local b64 = require("smithy.codec.json")._base64_encode(v)
        params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(b64)
        return

    elseif st == stype.TIMESTAMP then
        local ts_format = schema_mod.timestamp.DATE_TIME
        local ts_trait = schema:trait(t.TIMESTAMP_FORMAT)
        if ts_trait then
            ts_format = ts_trait.format
        end
        local formatted
        if ts_format == schema_mod.timestamp.EPOCH_SECONDS then
            if v % 1 == 0 then
                formatted = string.format("%.0f", v)
            else
                formatted = tostring(v)
            end
        elseif ts_format == schema_mod.timestamp.HTTP_DATE then
            formatted = require("smithy.codec.json")._format_http_date(v)
        else
            formatted = require("smithy.codec.json")._format_iso8601(v)
        end
        params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(formatted)
        return

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        local s
        if v ~= v then s = "NaN"
        elseif v == math.huge then s = "Infinity"
        elseif v == -math.huge then s = "-Infinity"
        else s = tostring(v) end
        params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(s)
        return

    elseif st == stype.INTEGER or st == stype.LONG or st == stype.SHORT
        or st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
        params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(string.format("%.0f", v))
        return

    else
        params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(tostring(v))
        return
    end
end

function M.serialize(self, input, operation)
    input = input or {}
    local prefix_parts = {
        "Action=" .. pct_encode(operation.name),
        "Version=" .. pct_encode(self.version),
    }

    local params = {}
    local schema = operation.input_schema
    if schema and schema:members() then
        serialize_query(input, "", schema, params, self.ec2)
    end

    -- Sort member params, but keep Action and Version first
    table.sort(params)
    local body
    if #params > 0 then
        body = table.concat(prefix_parts, "&") .. "&" .. table.concat(params, "&")
    else
        body = table.concat(prefix_parts, "&")
    end

    return http.new_request(
        "POST",
        "/",
        {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
        http.string_reader(body)
    ), nil
end

-- Parse error from awsQuery XML response
local function parse_awsquery_error(body_str)
    if not body_str or #body_str == 0 then return "UnknownError", "" end
    local node = xml_codec.parse_xml(body_str)
    if not node then return "UnknownError", "" end

    -- <ErrorResponse><Error><Code>...</Code><Message>...</Message></Error></ErrorResponse>
    local error_node
    for _, child in ipairs(node.children or {}) do
        if child.tag == "Error" then error_node = child; break end
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

-- Parse error from ec2Query XML response
local function parse_ec2query_error(body_str)
    if not body_str or #body_str == 0 then return "UnknownError", "" end
    local node = xml_codec.parse_xml(body_str)
    if not node then return "UnknownError", "" end

    -- <Response><Errors><Error><Code>...</Code><Message>...</Message></Error></Errors></Response>
    local errors_node
    for _, child in ipairs(node.children or {}) do
        if child.tag == "Errors" then errors_node = child; break end
    end
    local error_node
    if errors_node then
        for _, child in ipairs(errors_node.children or {}) do
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
        local code, message
        if self.ec2 then
            code, message = parse_ec2query_error(body_str)
        else
            code, message = parse_awsquery_error(body_str)
        end
        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    -- Success: parse XML response
    if not body_str or #body_str == 0 then return {}, nil end

    local node = xml_codec.parse_xml(body_str)
    if not node then return {}, nil end

    -- Find the result node
    local result_node
    if self.ec2 then
        -- ec2Query: no Result wrapper, members directly in <OpResponse>
        result_node = node
    else
        -- awsQuery: <OpResponse><OpResult>...</OpResult></OpResponse>
        local result_tag = operation.name .. "Result"
        for _, child in ipairs(node.children or {}) do
            if child.tag == result_tag then result_node = child; break end
        end
        if not result_node then result_node = node end
    end

    local output_schema = operation.output_schema
    if not output_schema or not output_schema:members() then return {}, nil end

    return xml_codec.decode_node(result_node, output_schema, self.xml), nil
end

return M
