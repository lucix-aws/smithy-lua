-- smithy-lua runtime: JSON codec
-- Schema-aware JSON serialization and deserialization.

local encoder = require("smithy.json.encoder")
local decoder = require("smithy.json.decoder")
local schema_mod = require("smithy.schema")

local stype = schema_mod.type
local strait = schema_mod.trait
local concat = table.concat
local format = string.format
local huge = math.huge

local M = {}
M.__index = M

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
local function wire_name(name, member_schema, use_json_name)
    if use_json_name and member_schema.traits then
        local jn = member_schema.traits[strait.JSON_NAME]
        if jn then return jn end
    end
    return name
end

-- Schema-aware encoding into a buffer. Returns new buffer position.
local function encode_schema_value(v, schema, buf, n, codec, apply_defaults)
    local st = schema.type

    if v == nil then
        n = n + 1; buf[n] = "null"
        return n
    end

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "{"
        local members = schema.members
        if members then
            local keys = {}
            for k in pairs(members) do keys[#keys + 1] = k end
            table.sort(keys)
            local first = true
            for i = 1, #keys do
                local name = keys[i]
                local ms = members[name]
                local mv = v[name]
                if mv == nil and apply_defaults and ms.traits then
                    mv = ms.traits[strait.DEFAULT]
                    -- Blob defaults are base64-encoded in the model; decode so codec re-encodes
                    if mv ~= nil and ms.type == stype.BLOB then
                        mv = M._base64_decode(mv)
                    end
                end
                if mv ~= nil then
                    if not first then n = n + 1; buf[n] = "," end
                    first = false
                    n = encode_string(wire_name(name, ms, codec.use_json_name), buf, n)
                    n = n + 1; buf[n] = ":"
                    n = encode_schema_value(mv, ms, buf, n, codec, true)
                end
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
            elseif elem_schema then
                n = encode_schema_value(v[i], elem_schema, buf, n, codec, true)
            else
                n = encoder._encode_value(v[i], buf, n)
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
            elseif val_schema then
                n = encode_schema_value(mv, val_schema, buf, n, codec, true)
            else
                n = encoder._encode_value(mv, buf, n)
            end
        end
        n = n + 1; buf[n] = "}"
        return n

    elseif st == stype.UNION then
        -- Union: exactly one member set. Serialize as single-key object.
        n = n + 1; buf[n] = "{"
        local members = schema.members
        if members then
            for name, member_schema in pairs(members) do
                local mv = v[name]
                if mv ~= nil then
                    n = encode_string(wire_name(name, member_schema, codec.use_json_name), buf, n)
                    n = n + 1; buf[n] = ":"
                    n = encode_schema_value(mv, member_schema, buf, n, codec, true)
                    break
                end
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
        if type(v) == "string" then
            -- Handle string representations of special float values
            return encode_string(v, buf, n)
        elseif v ~= v then
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
        return encode_string(M._base64_encode(v), buf, n)

    elseif st == stype.TIMESTAMP then
        local ts_format = codec.default_timestamp_format
        if schema.traits and schema.traits[strait.TIMESTAMP_FORMAT] then
            ts_format = schema.traits[strait.TIMESTAMP_FORMAT]
        end
        if ts_format == schema_mod.timestamp.DATE_TIME then
            return encode_string(M._format_iso8601(v), buf, n)
        elseif ts_format == schema_mod.timestamp.HTTP_DATE then
            return encode_string(M._format_http_date(v), buf, n)
        else
            -- epoch-seconds: strip trailing zeros but keep numeric
            if v % 1 == 0 then
                n = n + 1; buf[n] = format("%.0f", v)
            else
                n = n + 1; buf[n] = format("%s", tostring(v))
            end
        end
        return n

    elseif st == stype.DOCUMENT then
        return encoder._encode_value(v, buf, n)

    else
        return encoder._encode_value(v, buf, n)
    end
end

--- Serialize a Lua value to JSON using a schema.
function M.serialize(self, value, schema)
    local buf = {}
    local ok, n_or_err = pcall(encode_schema_value, value, schema, buf, 0, self, false)
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
        local members = schema.members
        if not members then return {} end
        -- Build reverse lookup: wire_name -> (member_name, member_schema)
        local by_wire = {}
        for name, member_schema in pairs(members) do
            by_wire[wire_name(name, member_schema, codec.use_json_name)] = { name, member_schema }
        end
        local result = {}
        for k, raw in pairs(v) do
            local entry = by_wire[k]
            if entry then
                local decoded, err = decode_schema_value(raw, entry[2], codec)
                if err then return nil, err end
                result[entry[1]] = decoded
            end
        end
        -- Apply defaults and zero-values for required members
        for name, ms in pairs(members) do
            if result[name] == nil and ms.traits then
                local def = ms.traits[strait.DEFAULT]
                if def ~= nil then
                    -- Blob defaults are base64-encoded in the model; decode for deserialization
                    if ms.type == stype.BLOB then def = M._base64_decode(def) end
                    result[name] = def
                elseif ms.traits[strait.REQUIRED] then
                    -- Error correction: fill zero-value for required members
                    local t = ms.type
                    if t == stype.STRING or t == stype.ENUM then result[name] = ""
                    elseif t == stype.BOOLEAN then result[name] = false
                    elseif t == stype.BYTE or t == stype.SHORT or t == stype.INTEGER
                        or t == stype.LONG or t == stype.FLOAT or t == stype.DOUBLE
                        or t == stype.INT_ENUM or t == stype.TIMESTAMP then result[name] = 0
                    elseif t == stype.BLOB then result[name] = ""
                    elseif t == stype.LIST or t == stype.MAP then result[name] = {}
                    end
                end
            end
        end
        return result

    elseif st == stype.LIST then
        if type(v) ~= "table" then
            return nil, "expected array for list, got " .. type(v)
        end
        local elem_schema = schema.member
        local result = {}
        for i = 1, #v do
            if elem_schema then
                local decoded, err = decode_schema_value(v[i], elem_schema, codec)
                if err then return nil, err end
                result[i] = decoded
            else
                result[i] = v[i]
            end
        end
        return result

    elseif st == stype.MAP then
        if type(v) ~= "table" then
            return nil, "expected object for map, got " .. type(v)
        end
        local val_schema = schema.value
        local result = {}
        for k, raw in pairs(v) do
            if val_schema then
                local decoded, err = decode_schema_value(raw, val_schema, codec)
                if err then return nil, err end
                result[k] = decoded
            else
                result[k] = raw
            end
        end
        return result

    elseif st == stype.UNION then
        if type(v) ~= "table" then
            return nil, "expected object for union, got " .. type(v)
        end
        local members = schema.members
        if not members then return {} end
        local by_wire = {}
        for name, member_schema in pairs(members) do
            by_wire[wire_name(name, member_schema, codec.use_json_name)] = { name, member_schema }
        end
        local result = {}
        for k, raw in pairs(v) do
            local entry = by_wire[k]
            if entry then
                local decoded, err = decode_schema_value(raw, entry[2], codec)
                if err then return nil, err end
                result[entry[1]] = decoded
                break
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
        if type(v) == "string" then
            local ts_format = codec.default_timestamp_format
            if schema.traits and schema.traits[strait.TIMESTAMP_FORMAT] then
                ts_format = schema.traits[strait.TIMESTAMP_FORMAT]
            end
            if ts_format == "http-date" then
                return M._parse_http_date(v)
            end
            return M._parse_iso8601(v)
        end
        return tonumber(v)

    elseif st == stype.DOCUMENT then
        return v

    else
        return v
    end
end

--- Deserialize JSON bytes to a Lua value using a schema.
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

-- Timestamp formatting/parsing helpers

local floor = math.floor

--- Format epoch seconds as ISO 8601 date-time string (UTC).
function M._format_iso8601(epoch)
    local frac = epoch - floor(epoch)
    local t = os.date("!*t", floor(epoch))
    local s = format("%04d-%02d-%02dT%02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
    if frac > 0 then
        -- up to 3 decimal places, strip trailing zeros
        local ms = format("%.3f", frac):sub(2):gsub("0+$", "")
        s = s .. ms
    end
    return s .. "Z"
end

--- Format epoch seconds as HTTP-date (RFC 7231).
function M._format_http_date(epoch)
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", floor(epoch))
end

--- Parse ISO 8601 date-time string to epoch seconds.
function M._parse_iso8601(s)
    local y, mo, d, h, mi, sec, frac, tz = s:match(
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
    if not y then return tonumber(s) end
    frac = tonumber(frac or "") or 0
    -- Compute epoch via os.time in UTC
    local t = os.time({year=tonumber(y), month=tonumber(mo), day=tonumber(d),
                        hour=tonumber(h), min=tonumber(mi), sec=tonumber(sec), isdst=false})
    -- os.time returns local time, adjust to UTC
    local utc_offset = os.time(os.date("!*t", 0)) - os.time(os.date("*t", 0))
    t = t - utc_offset
    -- Apply timezone offset from the string
    if tz and tz ~= "" and tz ~= "Z" then
        local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d%d)$")
        if sign then
            local off = tonumber(oh) * 3600 + tonumber(om) * 60
            if sign == "+" then t = t - off else t = t + off end
        end
    end
    return t + frac
end

--- Parse HTTP-date (RFC 7231) string to epoch seconds.
function M._parse_http_date(s)
    local months = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
    local day, mon, year, h, mi, sec = s:match("%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
    if not day then return tonumber(s) end
    local t = {year=tonumber(year), month=months[mon] or 1, day=tonumber(day),
               hour=tonumber(h), min=tonumber(mi), sec=tonumber(sec), isdst=false}
    local epoch = os.time(t)
    local utc_offset = os.time(os.date("!*t", 0)) - os.time(os.date("*t", 0))
    return epoch - utc_offset
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
        if s:byte(i + 2) ~= 61 then
            n = n + 1; out[n] = string.char(math.floor(v / 256) % 256)
        end
        if s:byte(i + 3) ~= 61 then
            n = n + 1; out[n] = string.char(v % 256)
        end
    end
    return concat(out)
end

return M
