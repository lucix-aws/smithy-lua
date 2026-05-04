-- smithy-lua runtime: pure Lua JSON encoder
-- Encodes Lua values to JSON strings. No schema awareness — that's the codec's job.

local M = {}

local concat = table.concat
local format = string.format
local huge = math.huge
local type = type
local tostring = tostring

-- Escape map for JSON string encoding
local escape_map = {
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

local function encode_string(s, buf, n)
    n = n + 1; buf[n] = '"'
    n = n + 1; buf[n] = s:gsub('[%z\1-\31"\\]', escape_map)
    n = n + 1; buf[n] = '"'
    return n
end

local encode_value -- forward declaration

local function encode_array(t, buf, n)
    n = n + 1; buf[n] = "["
    for i = 1, #t do
        if i > 1 then n = n + 1; buf[n] = "," end
        n = encode_value(t[i], buf, n)
    end
    n = n + 1; buf[n] = "]"
    return n
end

local function encode_object(t, keys, buf, n)
    n = n + 1; buf[n] = "{"
    local first = true
    for i = 1, #keys do
        local k = keys[i]
        local v = t[k]
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
local function encode_table(t, buf, n)
    if t[1] ~= nil or next(t) == nil then
        -- Treat as array (empty table also becomes [])
        return encode_array(t, buf, n)
    end
    -- Object: collect and sort keys for deterministic output
    local keys = {}
    for k in pairs(t) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return encode_object(t, keys, buf, n)
end

function encode_value(v, buf, n)
    local vtype = type(v)
    if vtype == "string" then
        return encode_string(v, buf, n)
    elseif vtype == "number" then
        if v ~= v then
            -- NaN
            n = n + 1; buf[n] = '"NaN"'
        elseif v == huge then
            n = n + 1; buf[n] = '"Infinity"'
        elseif v == -huge then
            n = n + 1; buf[n] = '"-Infinity"'
        elseif v % 1 == 0 and v >= -2^53 and v <= 2^53 then
            n = n + 1; buf[n] = format("%.0f", v)
        else
            n = n + 1; buf[n] = format("%.17g", v)
        end
        return n
    elseif vtype == "boolean" then
        n = n + 1; buf[n] = v and "true" or "false"
        return n
    elseif vtype == "table" then
        return encode_table(v, buf, n)
    elseif v == nil then
        n = n + 1; buf[n] = "null"
        return n
    else
        error("cannot encode type: " .. vtype)
    end
end

--- Encode a Lua value to a JSON string.
--- @param v any: value to encode
--- @return string: JSON string
function M.encode(v)
    local buf = {}
    local n = encode_value(v, buf, 0)
    return concat(buf, "", 1, n)
end

--- Encode a string value (exposed for codec use in headers, etc.)
M.encode_string = function(s)
    local buf = {}
    local n = encode_string(s, buf, 0)
    return concat(buf, "", 1, n)
end

--- Encode an object with ordered keys (for codec use with schemas).
--- @param t table: the object
--- @param keys table: ordered array of string keys
--- @return string: JSON string
function M.encode_object(t, keys)
    local buf = {}
    local n = encode_object(t, keys, buf, 0)
    return concat(buf, "", 1, n)
end

-- Expose internals for codec to build custom encoding
M._encode_value = encode_value
M._encode_string = encode_string
M._encode_array = encode_array
M._encode_object = encode_object

return M
