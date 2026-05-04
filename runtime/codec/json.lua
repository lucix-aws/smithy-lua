-- smithy-lua runtime: JSON codec
-- Schema-aware JSON serialization and deserialization.

local encoder = require("json.encoder")
local decoder = require("json.decoder")
local schema_mod = require("schema")

local stype = schema_mod.type
local strait = schema_mod.trait
local concat = table.concat
local format = string.format
local huge = math.huge

local M = {}
M.__index = M

local encode_value -- forward declaration
local encode_string = encoder._encode_string

--- Create a new JSON codec.
--- @param settings table|nil: { use_json_name = bool, default_timestamp_format = string }
--- @return table: codec instance
function M.new(settings)
    settings = settings or {}
    return setmetatable({
        use_json_name = settings.use_json_name or false,
        default_timestamp_format = settings.default_timestamp_format or schema_mod.timestamp.EPOCH_SECONDS,
    }, M)
end

-- Get the wire name for a member
local function wire_name(member, use_json_name)
    if use_json_name then
        local jn = member.traits and member.traits[strait.JSON_NAME]
        if jn then return jn end
    end
    return member.name
end

-- Schema-aware encoding into a buffer. Returns new buffer position.
local function encode_schema_value(v, schema, buf, n, codec)
    local st = schema.type

    if v == nil then
        n = n + 1; buf[n] = "null"
        return n
    end

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "{"
        local members = schema.members
        local first = true
        for i = 1, #members do
            local member = members[i]
            local mv = v[member.name]
            if mv ~= nil then
                if not first then n = n + 1; buf[n] = "," end
                first = false
                n = encode_string(wire_name(member, codec.use_json_name), buf, n)
                n = n + 1; buf[n] = ":"
                n = encode_schema_value(mv, member.target, buf, n, codec)
            end
        end
        n = n + 1; buf[n] = "}"
        return n

    elseif st == stype.LIST then
        n = n + 1; buf[n] = "["
        local elem_schema = schema.member
        for i = 1, #v do
            if i > 1 then n = n + 1; buf[n] = "," end
            if v[i] == nil then
                n = n + 1; buf[n] = "null"
            else
                n = encode_schema_value(v[i], elem_schema, buf, n, codec)
            end
        end
        n = n + 1; buf[n] = "]"
        return n

    elseif st == stype.MAP then
        n = n + 1; buf[n] = "{"
        local val_schema = schema.value
        -- Sort keys for deterministic output
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            if i > 1 then n = n + 1; buf[n] = "," end
            n = encode_string(keys[i], buf, n)
            n = n + 1; buf[n] = ":"
            local mv = v[keys[i]]
            if mv == nil then
                n = n + 1; buf[n] = "null"
            else
                n = encode_schema_value(mv, val_schema, buf, n, codec)
            end
        end
        n = n + 1; buf[n] = "}"
        return n

    elseif st == stype.UNION then
        -- Union: exactly one member set. Serialize as single-key object.
        n = n + 1; buf[n] = "{"
        local members = schema.members
        for i = 1, #members do
            local member = members[i]
            local mv = v[member.name]
            if mv ~= nil then
                n = encode_string(wire_name(member, codec.use_json_name), buf, n)
                n = n + 1; buf[n] = ":"
                n = encode_schema_value(mv, member.target, buf, n, codec)
                break
            end
        end
        n = n + 1; buf[n] = "}"
        return n

    elseif st == stype.STRING or st == stype.ENUM then
        return encode_string(v, buf, n)

    elseif st == stype.BOOLEAN then
        n = n + 1; buf[n] = v and "true" or "false"
        return n

    elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE
        or st == stype.LONG or st == stype.INT_ENUM then
        n = n + 1; buf[n] = format("%.0f", v)
        return n

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if v ~= v then
            n = n + 1; buf[n] = '"NaN"'
        elseif v == huge then
            n = n + 1; buf[n] = '"Infinity"'
        elseif v == -huge then
            n = n + 1; buf[n] = '"-Infinity"'
        elseif v % 1 == 0 and v >= -2^53 and v <= 2^53 then
            n = n + 1; buf[n] = format("%.1f", v)
        else
            n = n + 1; buf[n] = format("%.17g", v)
        end
        return n

    elseif st == stype.BLOB then
        -- Base64 encode
        return encode_string(M._base64_encode(v), buf, n)

    elseif st == stype.TIMESTAMP then
        local ts_format = codec.default_timestamp_format
        if schema.traits and schema.traits[strait.TIMESTAMP_FORMAT] then
            ts_format = schema.traits[strait.TIMESTAMP_FORMAT]
        end
        if ts_format == schema_mod.timestamp.EPOCH_SECONDS then
            n = n + 1; buf[n] = format("%.3f", v)
        else
            -- date-time and http-date: encode as string
            return encode_string(tostring(v), buf, n)
        end
        return n

    elseif st == stype.DOCUMENT then
        -- Documents are untyped — fall through to raw encoder
        return encoder._encode_value(v, buf, n)

    else
        -- Fallback
        return encoder._encode_value(v, buf, n)
    end
end

--- Serialize a Lua value to JSON using a schema.
--- @param self table: codec instance
--- @param value any: value to serialize
--- @param schema table: schema describing the value
--- @return string, table|nil: JSON string, error
function M.serialize(self, value, schema)
    local buf = {}
    local ok, n_or_err = pcall(encode_schema_value, value, schema, buf, 0, self)
    if not ok then
        return nil, { type = "sdk", message = "json serialize: " .. tostring(n_or_err) }
    end
    return concat(buf, "", 1, n_or_err), nil
end

-- Schema-aware decoding

local function decode_schema_value(v, schema, codec)
    local st = schema.type

    if v == nil then return nil end

    if st == stype.STRUCTURE then
        if type(v) ~= "table" then
            return nil, "expected object for structure, got " .. type(v)
        end
        -- Build reverse lookup: wire_name -> member
        local members = schema.members
        local by_wire = {}
        for i = 1, #members do
            local member = members[i]
            by_wire[wire_name(member, codec.use_json_name)] = member
        end
        local result = {}
        for k, raw in pairs(v) do
            local member = by_wire[k]
            if member then
                local decoded, err = decode_schema_value(raw, member.target, codec)
                if err then return nil, err end
                result[member.name] = decoded
            end
            -- Unknown members are silently dropped
        end
        return result

    elseif st == stype.LIST then
        if type(v) ~= "table" then
            return nil, "expected array for list, got " .. type(v)
        end
        local elem_schema = schema.member
        local result = {}
        for i = 1, #v do
            local decoded, err = decode_schema_value(v[i], elem_schema, codec)
            if err then return nil, err end
            result[i] = decoded
        end
        return result

    elseif st == stype.MAP then
        if type(v) ~= "table" then
            return nil, "expected object for map, got " .. type(v)
        end
        local val_schema = schema.value
        local result = {}
        for k, raw in pairs(v) do
            local decoded, err = decode_schema_value(raw, val_schema, codec)
            if err then return nil, err end
            result[k] = decoded
        end
        return result

    elseif st == stype.UNION then
        if type(v) ~= "table" then
            return nil, "expected object for union, got " .. type(v)
        end
        local members = schema.members
        local by_wire = {}
        for i = 1, #members do
            local member = members[i]
            by_wire[wire_name(member, codec.use_json_name)] = member
        end
        local result = {}
        for k, raw in pairs(v) do
            local member = by_wire[k]
            if member then
                local decoded, err = decode_schema_value(raw, member.target, codec)
                if err then return nil, err end
                result[member.name] = decoded
                break -- union has exactly one member
            end
        end
        return result

    elseif st == stype.STRING or st == stype.ENUM then
        return tostring(v)

    elseif st == stype.BOOLEAN then
        return v and true or false

    elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE
        or st == stype.LONG or st == stype.INT_ENUM then
        return tonumber(v)

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if type(v) == "string" then
            if v == "NaN" then return 0/0
            elseif v == "Infinity" then return huge
            elseif v == "-Infinity" then return -huge
            end
        end
        return tonumber(v)

    elseif st == stype.BLOB then
        if type(v) == "string" then
            return M._base64_decode(v)
        end
        return v

    elseif st == stype.TIMESTAMP then
        return tonumber(v)

    elseif st == stype.DOCUMENT then
        return v -- documents pass through as-is

    else
        return v
    end
end

--- Deserialize JSON bytes to a Lua value using a schema.
--- @param self table: codec instance
--- @param bytes string: JSON string
--- @param schema table: schema describing the expected value
--- @return any, table|nil: decoded value, error
function M.deserialize(self, bytes, schema)
    local raw, err = decoder.decode(bytes)
    if err then
        return nil, { type = "sdk", message = "json deserialize: " .. err }
    end
    local result, derr = decode_schema_value(raw, schema, self)
    if derr then
        return nil, { type = "sdk", message = "json deserialize: " .. derr }
    end
    return result, nil
end

-- Minimal base64 for blob support
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup = {}
for i = 1, 64 do b64lookup[b64chars:byte(i)] = i - 1 end

function M._base64_encode(s)
    local out = {}
    local n = 0
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local rem = #s - i + 1
        n = n + 1; out[n] = b64chars:sub(math.floor(v / 262144) % 64 + 1, math.floor(v / 262144) % 64 + 1)
        n = n + 1; out[n] = b64chars:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
        n = n + 1; out[n] = rem > 1 and b64chars:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1) or "="
        n = n + 1; out[n] = rem > 2 and b64chars:sub(v % 64 + 1, v % 64 + 1) or "="
    end
    return concat(out)
end

function M._base64_decode(s)
    s = s:gsub("%s", "")
    local out = {}
    local n = 0
    for i = 1, #s, 4 do
        local a = b64lookup[s:byte(i)] or 0
        local b = b64lookup[s:byte(i + 1)] or 0
        local c = b64lookup[s:byte(i + 2)] or 0
        local d = b64lookup[s:byte(i + 3)] or 0
        local v = a * 262144 + b * 4096 + c * 64 + d
        n = n + 1; out[n] = string.char(math.floor(v / 65536) % 256)
        if s:byte(i + 2) ~= 61 then -- '='
            n = n + 1; out[n] = string.char(math.floor(v / 256) % 256)
        end
        if s:byte(i + 3) ~= 61 then
            n = n + 1; out[n] = string.char(v % 256)
        end
    end
    return concat(out)
end

return M
