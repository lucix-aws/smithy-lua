-- smithy-lua runtime: pure Lua JSON encoder
-- Encodes Lua values to JSON strings. No schema awareness — that's the codec's job.

local record M
    encode: function(v: any): string
    encode_string: function(s: string): string
    encode_object: function(t: {string:any}, keys: {string}): string
    _encode_value: function(v: any, buf: {string}, n: integer): integer
    _encode_string: function(s: string, buf: {string}, n: integer): integer
    _encode_array: function(t: {any}, buf: {string}, n: integer): integer
    _encode_object: function(t: {string:any}, keys: {string}, buf: {string}, n: integer): integer
end

local concat = table.concat
local format = string.format
local huge = math.huge
local type = type
local tostring = tostring

-- Escape map for JSON string encoding
local escape_map: {string:string} = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
}

-- Escape control characters U+0000 through U+001F
for i = 0, 31 do
    local c = string.char(i)
    if not escape_map[c] then
        escape_map[c] = format("\\u%04x", i)
    end
end

local function encode_string(s: string, buf: {string}, n: integer): integer
    n = n + 1; buf[n] = '"'
    n = n + 1; buf[n] = s:gsub('[%z\1-\31"\\]', escape_map)
    n = n + 1; buf[n] = '"'
    return n
end

local encode_value: function(v: any, buf: {string}, n: integer): integer

local function encode_array(t: {any}, buf: {string}, n: integer): integer
    n = n + 1; buf[n] = "["
    for i = 1, #t do
        if i > 1 then n = n + 1; buf[n] = "," end
        n = encode_value(t[i], buf, n)
    end
    n = n + 1; buf[n] = "]"
    return n
end

local function encode_object(t: {string:any}, keys: {string}, buf: {string}, n: integer): integer
    n = n + 1; buf[n] = "{"
    local first = true
    for i = 1, #keys do
        local k = keys[i]
        local v = (t as {string:any})[k]
        if v ~= nil then
            if not first then n = n + 1; buf[n] = "," end
            first = false
            n = encode_string(k, buf, n)
            n = n + 1; buf[n] = ":"
            n = encode_value(v, buf, n)
        end
    end
    n = n + 1; buf[n] = "}"
    return n
end

-- Encode an untyped table (no schema). Detects array vs object by presence of [1].
local function encode_table(t: {any}, buf: {string}, n: integer): integer
    if (t as {any})[1] ~= nil or next(t as {any}) == nil then
        return encode_array(t, buf, n)
    end
    local keys: {string} = {}
    for k in pairs(t as {string:any}) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return encode_object(t as {string:any}, keys, buf, n)
end

encode_value = function(v: any, buf: {string}, n: integer): integer
    local vtype = type(v)
    if vtype == "string" then
        return encode_string(v as string, buf, n)
    elseif vtype == "number" then
        local num = v as number
        if num ~= num then
            n = n + 1; buf[n] = '"NaN"'
        elseif num == huge then
            n = n + 1; buf[n] = '"Infinity"'
        elseif num == -huge then
            n = n + 1; buf[n] = '"-Infinity"'
        elseif num % 1 == 0 and num >= -2^53 and num <= 2^53 then
            n = n + 1; buf[n] = format("%.0f", num)
        else
            n = n + 1; buf[n] = format("%.17g", num)
        end
        return n
    elseif vtype == "boolean" then
        n = n + 1; buf[n] = (v as boolean) and "true" or "false"
        return n
    elseif vtype == "table" then
        return encode_table(v as {any}, buf, n)
    elseif v == nil then
        n = n + 1; buf[n] = "null"
        return n
    else
        error("cannot encode type: " .. vtype)
    end
    return n
end

function M.encode(v: any): string
    local buf: {string} = {}
    local n = encode_value(v, buf, 0)
    return concat(buf, "", 1, n)
end

M.encode_string = function(s: string): string
    local buf: {string} = {}
    local n = encode_string(s, buf, 0)
    return concat(buf, "", 1, n)
end

function M.encode_object(t: {string:any}, keys: {string}): string
    local buf: {string} = {}
    local n = encode_object(t, keys, buf, 0)
    return concat(buf, "", 1, n)
end

M._encode_value = encode_value
M._encode_string = encode_string
M._encode_array = encode_array
M._encode_object = encode_object

return M
