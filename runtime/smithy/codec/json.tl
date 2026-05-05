-- smithy-lua runtime: JSON codec (schema-aware serialization/deserialization)

local encoder = require("smithy.json.encoder")
local decoder = require("smithy.json.decoder")
local schema_mod = require("smithy.schema")

local stype = schema_mod.type
local strait = schema_mod.trait
local concat = table.concat
local format = string.format
local huge = math.huge

local record json_codec
    use_json_name: boolean
    default_timestamp_format: string

    _format_iso8601: function(epoch: number): string
    _format_http_date: function(epoch: number): string
    _parse_iso8601: function(s: string): number
    _parse_http_date: function(s: string): number
    _base64_encode: function(s: string): string
    _base64_decode: function(s: string): string
end

local json_codec_mt: metatable<json_codec> = { __index = json_codec }

local encode_string = encoder._encode_string

local function wire_name(name: string, member_schema: schema_mod.Schema, use_json_name: boolean): string
    if use_json_name and member_schema.traits then
        local jn = member_schema.traits[strait.JSON_NAME] as string
        if jn then return jn end
    end
    return name
end

local encode_schema_value: function(v: any, schema: schema_mod.Schema, buf: {string}, n: integer, codec: json_codec, apply_defaults: boolean): integer

encode_schema_value = function(v: any, schema: schema_mod.Schema, buf: {string}, n: integer, codec: json_codec, apply_defaults: boolean): integer
    local st = schema.type

    if v == nil then
        n = n + 1; buf[n] = "null"
        return n
    end

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "{"
        local members = schema.members
        if members then
            local keys: {string} = {}
            for k in pairs(members) do keys[#keys + 1] = k end
            table.sort(keys)
            local first = true
            for i = 1, #keys do
                local name = keys[i]
                local ms = members[name]
                local mv = (v as {string:any})[name]
                if mv == nil and apply_defaults and ms.traits then
                    mv = ms.traits[strait.DEFAULT]
                    if mv ~= nil and ms.type == stype.BLOB then
                        mv = json_codec._base64_decode(mv as string)
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
        local arr = v as {any}
        for i = 1, #arr do
            if i > 1 then n = n + 1; buf[n] = "," end
            if arr[i] == nil then
                n = n + 1; buf[n] = "null"
            elseif elem_schema then
                n = encode_schema_value(arr[i], elem_schema, buf, n, codec, true)
            else
                n = encoder._encode_value(arr[i], buf, n)
            end
        end
        n = n + 1; buf[n] = "]"
        return n

    elseif st == stype.MAP then
        n = n + 1; buf[n] = "{"
        local val_schema = schema.value
        local map = v as {string:any}
        local keys: {string} = {}
        for k in pairs(map) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            if i > 1 then n = n + 1; buf[n] = "," end
            n = encode_string(keys[i], buf, n)
            n = n + 1; buf[n] = ":"
            local mv = map[keys[i]]
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
        n = n + 1; buf[n] = "{"
        local members = schema.members
        if members then
            for name, member_schema in pairs(members) do
                local mv = (v as {string:any})[name]
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
        return encode_string(v as string, buf, n)

    elseif st == stype.BOOLEAN then
        n = n + 1; buf[n] = (v as boolean) and "true" or "false"
        return n

    elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE
        or st == stype.LONG or st == stype.INT_ENUM then
        n = n + 1; buf[n] = format("%.0f", v as number)
        return n

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if type(v) == "string" then
            return encode_string(v as string, buf, n)
        end
        local num = v as number
        if num ~= num then
            n = n + 1; buf[n] = '"NaN"'
        elseif num == huge then
            n = n + 1; buf[n] = '"Infinity"'
        elseif num == -huge then
            n = n + 1; buf[n] = '"-Infinity"'
        elseif num % 1 == 0 and num >= -2^53 and num <= 2^53 then
            n = n + 1; buf[n] = format("%.1f", num)
        else
            n = n + 1; buf[n] = format("%.17g", num)
        end
        return n

    elseif st == stype.BLOB then
        return encode_string(json_codec._base64_encode(v as string), buf, n)

    elseif st == stype.TIMESTAMP then
        local ts_format = codec.default_timestamp_format
        if schema.traits and schema.traits[strait.TIMESTAMP_FORMAT] then
            ts_format = schema.traits[strait.TIMESTAMP_FORMAT] as string
        end
        local num = v as number
        if ts_format == schema_mod.timestamp.DATE_TIME then
            return encode_string(json_codec._format_iso8601(num), buf, n)
        elseif ts_format == schema_mod.timestamp.HTTP_DATE then
            return encode_string(json_codec._format_http_date(num), buf, n)
        else
            if num % 1 == 0 then
                n = n + 1; buf[n] = format("%.0f", num)
            else
                n = n + 1; buf[n] = tostring(num)
            end
        end
        return n

    elseif st == stype.DOCUMENT then
        return encoder._encode_value(v, buf, n)

    else
        return encoder._encode_value(v, buf, n)
    end
end

function json_codec:serialize(value: any, schema: schema_mod.Schema): string, any
    local buf: {string} = {}
    local ok, n_or_err = pcall(encode_schema_value, value, schema, buf, 0, self, false) as (boolean, any)
    if not ok then
        return nil, { type = "sdk", message = "json serialize: " .. tostring(n_or_err) }
    end
    return concat(buf, "", 1, n_or_err as integer), nil
end

-- Schema-aware decoding

local decode_schema_value: function(v: any, schema: schema_mod.Schema, codec: json_codec): any, string

decode_schema_value = function(v: any, schema: schema_mod.Schema, codec: json_codec): any, string
    local st = schema.type

    if v == nil then return nil end

    if st == stype.STRUCTURE then
        if type(v) ~= "table" then
            return nil, "expected object for structure, got " .. type(v)
        end
        local members = schema.members
        if not members then return {} end
        local by_wire: {string:{string, schema_mod.Schema}} = {}
        for name, member_schema in pairs(members) do
            by_wire[wire_name(name, member_schema, codec.use_json_name)] = { name, member_schema }
        end
        local result: {string:any} = {}
        for k, raw in pairs(v as {string:any}) do
            local entry = by_wire[k]
            if entry then
                local decoded, err = decode_schema_value(raw, entry[2], codec)
                if err then return nil, err end
                result[entry[1]] = decoded
            end
        end
        for name, ms in pairs(members) do
            if result[name] == nil and ms.traits then
                local def = ms.traits[strait.DEFAULT]
                if def ~= nil then
                    if ms.type == stype.BLOB then def = json_codec._base64_decode(def as string) end
                    result[name] = def
                elseif ms.traits[strait.REQUIRED] then
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
        local arr = v as {any}
        local result: {any} = {}
        for i = 1, #arr do
            if elem_schema then
                local decoded, err = decode_schema_value(arr[i], elem_schema, codec)
                if err then return nil, err end
                result[i] = decoded
            else
                result[i] = arr[i]
            end
        end
        return result

    elseif st == stype.MAP then
        if type(v) ~= "table" then
            return nil, "expected object for map, got " .. type(v)
        end
        local val_schema = schema.value
        local result: {string:any} = {}
        for k, raw in pairs(v as {string:any}) do
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
        local by_wire: {string:{string, schema_mod.Schema}} = {}
        for name, member_schema in pairs(members) do
            by_wire[wire_name(name, member_schema, codec.use_json_name)] = { name, member_schema }
        end
        local result: {string:any} = {}
        for k, raw in pairs(v as {string:any}) do
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
        return (v as boolean) and true or false

    elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE
        or st == stype.LONG or st == stype.INT_ENUM then
        return tonumber(v as string)

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if type(v) == "string" then
            local s = v as string
            if s == "NaN" then return 0/0
            elseif s == "Infinity" then return huge
            elseif s == "-Infinity" then return -huge
            end
        end
        return tonumber(v as string)

    elseif st == stype.BLOB then
        if type(v) == "string" then
            return json_codec._base64_decode(v as string)
        end
        return v

    elseif st == stype.TIMESTAMP then
        if type(v) == "string" then
            local ts_format = codec.default_timestamp_format
            if schema.traits and schema.traits[strait.TIMESTAMP_FORMAT] then
                ts_format = schema.traits[strait.TIMESTAMP_FORMAT] as string
            end
            if ts_format == "http-date" then
                return json_codec._parse_http_date(v as string)
            end
            return json_codec._parse_iso8601(v as string)
        end
        return tonumber(v as string)

    elseif st == stype.DOCUMENT then
        return v

    else
        return v
    end
end

function json_codec:deserialize(bytes: string, schema: schema_mod.Schema): any, any
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

-- Timestamp helpers

local floor = math.floor

function json_codec._format_iso8601(epoch: number): string
    local frac = epoch - floor(epoch)
    local t = os.date("!*t", floor(epoch)) as {string:integer}
    local s = format("%04d-%02d-%02dT%02d:%02d:%02d", t.year, t.month, t.day, t.hour, t.min, t.sec)
    if frac > 0 then
        local ms = format("%.3f", frac):sub(2):gsub("0+$", "")
        s = s .. ms
    end
    return s .. "Z"
end

function json_codec._format_http_date(epoch: number): string
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", floor(epoch)) as string
end

function json_codec._parse_iso8601(s: string): number
    local y, mo, d, h, mi, sec, frac_str, tz = s:match(
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
    if not y then return tonumber(s) end
    local frac = tonumber(frac_str or "") or 0
    local t_tbl = {year=tonumber(y), month=tonumber(mo), day=tonumber(d),
                   hour=tonumber(h), min=tonumber(mi), sec=tonumber(sec), isdst=false}
    local t_val: number = os.time(t_tbl as os.DateTable)
    local utc_offset: number = os.time(os.date("!*t", 0) as os.DateTable) - os.time(os.date("*t", 0) as os.DateTable)
    t_val = t_val - utc_offset
    if tz and tz ~= "" and tz ~= "Z" then
        local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d%d)$")
        if sign then
            local off: number = (tonumber(oh) or 0) * 3600 + (tonumber(om) or 0) * 60
            if sign == "+" then t_val = t_val - off else t_val = t_val + off end
        end
    end
    return t_val + frac
end

function json_codec._parse_http_date(s: string): number
    local months: {string:integer} = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
    local day, mon, year, h, mi, sec = s:match("%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
    if not day then return tonumber(s) end
    local t_tbl = {year=tonumber(year), month=months[mon] or 1, day=tonumber(day),
                   hour=tonumber(h), min=tonumber(mi), sec=tonumber(sec), isdst=false}
    local epoch = os.time(t_tbl as os.DateTable)
    local utc_offset = os.time(os.date("!*t", 0) as os.DateTable) - os.time(os.date("*t", 0) as os.DateTable)
    return epoch - utc_offset
end

-- Base64
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup: {integer:integer} = {}
for i = 1, 64 do b64lookup[b64chars:byte(i)] = i - 1 end

function json_codec._base64_encode(s: string): string
    local out: {string} = {}
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

function json_codec._base64_decode(s: string): string
    s = s:gsub("%s", "")
    local out: {string} = {}
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

function json_codec.new(settings: {string:any}): json_codec
    settings = settings or {}
    return setmetatable({
        use_json_name = (settings.use_json_name as boolean) or false,
        default_timestamp_format = (settings.default_timestamp_format as string) or schema_mod.timestamp.EPOCH_SECONDS,
    } as json_codec, json_codec_mt)
end

return json_codec
