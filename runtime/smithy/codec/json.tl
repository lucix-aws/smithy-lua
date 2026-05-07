-- smithy-lua runtime: JSON codec
-- Schema-aware JSON serialization and deserialization.

local encoder = require("smithy.json.encoder")
local decoder = require("smithy.json.decoder")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local base64 = require("smithy.base64")

local stype = schema_mod.type
local concat = table.concat
local format = string.format
local huge = math.huge

local record M
    use_json_name: boolean
    use_bignum_strings: boolean
    default_timestamp_format: string

    metamethod __index: M

    _format_iso8601: function(epoch: number): string
    _format_http_date: function(epoch: number): string
    _parse_iso8601: function(s: string): number
    _parse_http_date: function(s: string): number
    _base64_encode: function(s: string): string
    _base64_decode: function(s: string): string
end

local M_mt: metatable<M> = { __index = M }

local encode_string = encoder._encode_string

function M.new(settings: {string:any}): M
    settings = settings or {}
    return setmetatable({
        use_json_name = settings.use_json_name as boolean or false,
        use_bignum_strings = settings.use_bignum_strings as boolean or false,
        default_timestamp_format = settings.default_timestamp_format as string or schema_mod.timestamp.EPOCH_SECONDS,
    } as M, M_mt)
end

local function wire_name(name: string, member_schema: schema_mod.Schema, use_json_name: boolean): string
    if use_json_name then
        local jn = member_schema:trait(t.JSON_NAME) as {string:string}
        if jn then return jn.name end
    end
    return name
end

local function encode_schema_value(v: any, schema: schema_mod.Schema, buf: {string}, n: integer, codec: M, apply_defaults: boolean): integer
    local st = schema.type

    if v == nil then
        n = n + 1; buf[n] = "null"
        return n
    end

    if st == stype.STRUCTURE then
        n = n + 1; buf[n] = "{"
        local members = schema:members()
        if members then
            local keys: {string} = {}
            for k in pairs(members) do keys[#keys + 1] = k end
            table.sort(keys)
            local first = true
            for i = 1, #keys do
                local name = keys[i]
                local ms = members[name]
                local mv = (v as {string:any})[name]
                if mv == nil and apply_defaults then
                    local def = ms:trait(t.DEFAULT) as {string:any}
                    if def then
                        mv = def.value
                        if mv ~= nil and ms.type == stype.BLOB then
                            mv = base64.decode(mv as string)
                        end
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
        local elem_schema = schema.list_member
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
        local val_schema = schema.map_value
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
        local members = schema:members()
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
        n = n + 1; buf[n] = v and "true" or "false"
        return n

    elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE
        or st == stype.LONG or st == stype.INT_ENUM then
        n = n + 1; buf[n] = format("%.0f", v as number)
        return n

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if type(v) == "string" then
            return encode_string(v as string, buf, n)
        elseif (v as number) ~= (v as number) then
            n = n + 1; buf[n] = '"NaN"'
        elseif v as number == huge then
            n = n + 1; buf[n] = '"Infinity"'
        elseif v as number == -huge then
            n = n + 1; buf[n] = '"-Infinity"'
        elseif (v as number) % 1 == 0 and (v as number) >= -2^53 and (v as number) <= 2^53 then
            n = n + 1; buf[n] = format("%.1f", v as number)
        else
            n = n + 1; buf[n] = format("%.17g", v as number)
        end
        return n

    elseif st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
        if not codec.use_bignum_strings then
            error("bigInteger/bigDecimal requires use_bignum_strings to be enabled")
        end
        return encode_string(tostring(v), buf, n)

    elseif st == stype.BLOB then
        return encode_string(base64.encode(v as string), buf, n)

    elseif st == stype.TIMESTAMP then
        local ts_format = codec.default_timestamp_format
        local tf = schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
        if tf then
            ts_format = tf.format
        end
        if ts_format == schema_mod.timestamp.DATE_TIME then
            return encode_string(M._format_iso8601(v as number), buf, n)
        elseif ts_format == schema_mod.timestamp.HTTP_DATE then
            return encode_string(M._format_http_date(v as number), buf, n)
        else
            local num = v as number
            if num % 1 == 0 then
                n = n + 1; buf[n] = format("%.0f", num)
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

function M.serialize(self: M, value: any, schema: schema_mod.Schema): string, {string:string}
    local buf: {string} = {}
    local ok, n_or_err = pcall(encode_schema_value, value, schema, buf, 0, self, false)
    if not ok then
        return nil, { type = "sdk", message = "json serialize: " .. tostring(n_or_err) }
    end
    return concat(buf, "", 1, n_or_err as integer), nil
end

local function decode_schema_value(v: any, schema: schema_mod.Schema, codec: M): any, string
    local st = schema.type

    if v == nil then return nil end

    if st == stype.STRUCTURE then
        if type(v) ~= "table" then
            return nil, "expected object for structure, got " .. type(v)
        end
        local members = schema:members()
        if not members then return {} end
        local by_wire: {string:{any}} = {}
        for name, member_schema in pairs(members) do
            local wn = wire_name(name, member_schema, codec.use_json_name)
            local entry: {any} = { name, member_schema }
            by_wire[wn] = entry
        end
        local result: {string:any} = {}
        for k, raw in pairs(v as {string:any}) do
            local entry = by_wire[k]
            if entry then
                local decoded, err = decode_schema_value(raw, entry[2] as schema_mod.Schema, codec)
                if err then return nil, err end
                result[entry[1] as string] = decoded
            end
        end
        for name, ms in pairs(members) do
            if result[name] == nil then
                local def = ms:trait(t.DEFAULT) as {string:any}
                if def then
                    local dv: any = def.value
                    if ms.type == stype.BLOB then dv = base64.decode(dv as string) end
                    result[name] = dv
                elseif ms:trait(t.REQUIRED) then
                    local mt = ms.type
                    if mt == stype.STRING or mt == stype.ENUM then result[name] = ""
                    elseif mt == stype.BOOLEAN then result[name] = false
                    elseif mt == stype.BYTE or mt == stype.SHORT or mt == stype.INTEGER
                        or mt == stype.LONG or mt == stype.FLOAT or mt == stype.DOUBLE
                        or mt == stype.INT_ENUM or mt == stype.TIMESTAMP then result[name] = 0
                    elseif mt == stype.BIG_INTEGER or mt == stype.BIG_DECIMAL then result[name] = "0"
                    elseif mt == stype.BLOB then result[name] = ""
                    elseif mt == stype.LIST or mt == stype.MAP then result[name] = {}
                    end
                end
            end
        end
        return result

    elseif st == stype.LIST then
        if type(v) ~= "table" then
            return nil, "expected array for list, got " .. type(v)
        end
        local elem_schema = schema.list_member
        local result: {any} = {}
        local arr = v as {any}
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
        local val_schema = schema.map_value
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
        local members = schema:members()
        if not members then return {} end
        local by_wire: {string:{any}} = {}
        for name, member_schema in pairs(members) do
            local wn = wire_name(name, member_schema, codec.use_json_name)
            local entry: {any} = { name, member_schema }
            by_wire[wn] = entry
        end
        local result: {string:any} = {}
        for k, raw in pairs(v as {string:any}) do
            local entry = by_wire[k]
            if entry then
                local decoded, err = decode_schema_value(raw, entry[2] as schema_mod.Schema, codec)
                if err then return nil, err end
                result[entry[1] as string] = decoded
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
        return tonumber(v as number)

    elseif st == stype.FLOAT or st == stype.DOUBLE then
        if type(v) == "string" then
            local s = v as string
            if s == "NaN" then return 0/0
            elseif s == "Infinity" then return huge
            elseif s == "-Infinity" then return -huge
            end
        end
        return tonumber(v as number)

    elseif st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
        if not codec.use_bignum_strings then
            return nil, "bigInteger/bigDecimal requires use_bignum_strings to be enabled"
        end
        return tostring(v)

    elseif st == stype.BLOB then
        if type(v) == "string" then
            return base64.decode(v as string)
        end
        return v

    elseif st == stype.TIMESTAMP then
        if type(v) == "string" then
            local ts_format = codec.default_timestamp_format
            local tf = schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
            if tf then
                ts_format = tf.format
            end
            if ts_format == "http-date" then
                return M._parse_http_date(v as string)
            end
            return M._parse_iso8601(v as string)
        end
        return tonumber(v as number)

    elseif st == stype.DOCUMENT then
        return v

    else
        return v
    end
end

function M.deserialize(self: M, bytes: string, schema: schema_mod.Schema): any, {string:string}
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

local floor = math.floor

function M._format_iso8601(epoch: number): string
    local frac = epoch - floor(epoch)
    local dt = os.date("!*t", floor(epoch)) as {string:integer}
    local s = format("%04d-%02d-%02dT%02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.min, dt.sec)
    if frac > 0 then
        local ms = format("%.3f", frac):sub(2):gsub("0+$", "")
        s = s .. ms
    end
    return s .. "Z"
end

function M._format_http_date(epoch: number): string
    return os.date("!%a, %d %b %Y %H:%M:%S GMT", floor(epoch)) as string
end

function M._parse_iso8601(s: string): number
    local y, mo, d, h, mi, sec, frac_str, tz = s:match(
        "^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):(%d%d)(%.?%d*)(.*)$")
    if not y then return tonumber(s) as number end
    local frac = tonumber(frac_str or "") or 0
    local time_tbl = {year=tonumber(y) as integer, month=tonumber(mo) as integer, day=tonumber(d) as integer,
                        hour=tonumber(h) as integer, min=tonumber(mi) as integer, sec=tonumber(sec) as integer, isdst=false}
    local tt = os.time(time_tbl as os.DateTable)
    local utc_dt = os.date("!*t", 0) as os.DateTable
    local local_dt = os.date("*t", 0) as os.DateTable
    local utc_offset = os.time(utc_dt) - os.time(local_dt)
    tt = tt - utc_offset
    if tz and tz ~= "" and tz ~= "Z" then
        local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d%d)$")
        if sign then
            local off = (tonumber(oh) as integer) * 3600 + (tonumber(om) as integer) * 60
            if sign == "+" then tt = tt - off else tt = tt + off end
        end
    end
    return tt + frac
end

function M._parse_http_date(s: string): number
    local months: {string:integer} = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
    local day, mon, year, h, mi, sec = s:match("%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
    if not day then return tonumber(s) as number end
    local tt_tbl = {year=tonumber(year) as integer, month=months[mon] or 1, day=tonumber(day) as integer,
               hour=tonumber(h) as integer, min=tonumber(mi) as integer, sec=tonumber(sec) as integer, isdst=false}
    local epoch = os.time(tt_tbl as os.DateTable)
    local utc_dt = os.date("!*t", 0) as os.DateTable
    local local_dt = os.date("*t", 0) as os.DateTable
    local utc_offset = os.time(utc_dt) - os.time(local_dt)
    return epoch - utc_offset
end

M._base64_encode = base64.encode
M._base64_decode = base64.decode

return M
