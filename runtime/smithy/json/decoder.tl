-- smithy-lua runtime: pure Lua JSON decoder
-- Decodes JSON strings to Lua values. No schema awareness — that's the codec's job.

local record M
    decode: function(s: string): any, string
    _decode_value: function(s: string, pos: integer): any, integer, string
end

local byte = string.byte
local sub = string.sub
local find = string.find
local tonumber = tonumber

local CHAR_SPACE = 32
local CHAR_TAB   = 9
local CHAR_LF    = 10
local CHAR_CR    = 13
local CHAR_QUOTE = 34
local CHAR_COMMA = 44
local CHAR_COLON = 58
local CHAR_LBRACKET = 91
local CHAR_RBRACKET = 93
local CHAR_LBRACE = 123
local CHAR_RBRACE = 125
local CHAR_BACKSLASH = 92

-- Unescape map
local unescape_map: {integer:string} = {
    [CHAR_QUOTE]     = '"',
    [CHAR_BACKSLASH] = '\\',
    [byte('/')]      = '/',
    [byte('b')]      = '\b',
    [byte('f')]      = '\f',
    [byte('n')]      = '\n',
    [byte('r')]      = '\r',
    [byte('t')]      = '\t',
}

local decode_value: function(s: string, pos: integer): any, integer, string

local function skip_ws(s: string, pos: integer): integer
    local c = byte(s, pos)
    while c == CHAR_SPACE or c == CHAR_TAB or c == CHAR_LF or c == CHAR_CR do
        pos = pos + 1
        c = byte(s, pos)
    end
    return pos
end

local function decode_string(s: string, pos: integer): string, integer, string
    -- pos points to opening quote
    pos = pos + 1
    local start = pos
    local chunks: {string}
    while true do
        local c = byte(s, pos)
        if not c then
            return nil, pos, "unterminated string"
        end
        if c == CHAR_QUOTE then
            if chunks then
                chunks[#chunks + 1] = sub(s, start, pos - 1)
                return table.concat(chunks), pos + 1, nil
            end
            return sub(s, start, pos - 1), pos + 1, nil
        end
        if c == CHAR_BACKSLASH then
            if not chunks then chunks = {} end
            chunks[#chunks + 1] = sub(s, start, pos - 1)
            pos = pos + 1
            c = byte(s, pos)
            local esc = unescape_map[c]
            if esc then
                chunks[#chunks + 1] = esc
                pos = pos + 1
            elseif c == byte('u') then
                local hex = sub(s, pos + 1, pos + 4)
                local cp = tonumber(hex, 16)
                if not cp then
                    return nil, pos, "invalid unicode escape"
                end
                -- Handle surrogate pairs
                if cp >= 0xD800 and cp <= 0xDBFF then
                    if sub(s, pos + 5, pos + 6) == "\\u" then
                        local hex2 = sub(s, pos + 7, pos + 10)
                        local cp2 = tonumber(hex2, 16)
                        if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                            pos = pos + 11
                        else
                            return nil, pos, "invalid surrogate pair"
                        end
                    else
                        return nil, pos, "missing low surrogate"
                    end
                else
                    pos = pos + 5
                end
                -- UTF-8 encode
                if cp < 0x80 then
                    chunks[#chunks + 1] = string.char(cp)
                elseif cp < 0x800 then
                    chunks[#chunks + 1] = string.char(
                        0xC0 + math.floor(cp / 64),
                        0x80 + cp % 64)
                elseif cp < 0x10000 then
                    chunks[#chunks + 1] = string.char(
                        0xE0 + math.floor(cp / 4096),
                        0x80 + math.floor(cp / 64) % 64,
                        0x80 + cp % 64)
                else
                    chunks[#chunks + 1] = string.char(
                        0xF0 + math.floor(cp / 262144),
                        0x80 + math.floor(cp / 4096) % 64,
                        0x80 + math.floor(cp / 64) % 64,
                        0x80 + cp % 64)
                end
            else
                return nil, pos, "invalid escape"
            end
            start = pos
        else
            pos = pos + 1
        end
    end
end

local function decode_number(s: string, pos: integer): number, integer, string
    local start = pos
    local p = find(s, "[^%d%.eE%+%-]", pos)
    if not p then p = #s + 1 end
    local str = sub(s, start, p - 1)
    local n = tonumber(str)
    if not n then
        return nil, pos, "invalid number: " .. str
    end
    return n, p, nil
end

local function decode_array(s: string, pos: integer): {any}, integer, string
    pos = pos + 1 -- skip '['
    pos = skip_ws(s, pos)
    local arr: {any} = {}
    if byte(s, pos) == CHAR_RBRACKET then
        return arr, pos + 1, nil
    end
    local n = 0
    while true do
        local val: any
        local err: string
        val, pos, err = decode_value(s, pos)
        if err then return nil, pos, err end
        n = n + 1
        arr[n] = val
        pos = skip_ws(s, pos)
        local c = byte(s, pos)
        if c == CHAR_RBRACKET then
            return arr, pos + 1, nil
        elseif c == CHAR_COMMA then
            pos = skip_ws(s, pos + 1)
        else
            return nil, pos, "expected ',' or ']'"
        end
    end
end

local function decode_object(s: string, pos: integer): {string:any}, integer, string
    pos = pos + 1 -- skip '{'
    pos = skip_ws(s, pos)
    local obj: {string:any} = {}
    if byte(s, pos) == CHAR_RBRACE then
        return obj, pos + 1, nil
    end
    while true do
        if byte(s, pos) ~= CHAR_QUOTE then
            return nil, pos, "expected string key"
        end
        local key: string
        local err: string
        key, pos, err = decode_string(s, pos)
        if err then return nil, pos, err end
        pos = skip_ws(s, pos)
        if byte(s, pos) ~= CHAR_COLON then
            return nil, pos, "expected ':'"
        end
        pos = skip_ws(s, pos + 1)
        local val: any
        val, pos, err = decode_value(s, pos)
        if err then return nil, pos, err end
        obj[key] = val
        pos = skip_ws(s, pos)
        local c = byte(s, pos)
        if c == CHAR_RBRACE then
            return obj, pos + 1, nil
        elseif c == CHAR_COMMA then
            pos = skip_ws(s, pos + 1)
        else
            return nil, pos, "expected ',' or '}'"
        end
    end
end

decode_value = function(s: string, pos: integer): any, integer, string
    pos = skip_ws(s, pos)
    local c = byte(s, pos)
    if not c then
        return nil, pos, "unexpected end of input"
    end
    if c == CHAR_QUOTE then
        return decode_string(s, pos)
    elseif c == CHAR_LBRACE then
        return decode_object(s, pos)
    elseif c == CHAR_LBRACKET then
        return decode_array(s, pos)
    elseif c == byte('t') then
        if sub(s, pos, pos + 3) == "true" then
            return true, pos + 4, nil
        end
        return nil, pos, "invalid literal"
    elseif c == byte('f') then
        if sub(s, pos, pos + 4) == "false" then
            return false, pos + 5, nil
        end
        return nil, pos, "invalid literal"
    elseif c == byte('n') then
        if sub(s, pos, pos + 3) == "null" then
            return nil, pos + 4, nil
        end
        return nil, pos, "invalid literal"
    elseif c == byte('-') or (c >= byte('0') and c <= byte('9')) then
        return decode_number(s, pos)
    else
        return nil, pos, "unexpected character: " .. string.char(c)
    end
end

function M.decode(s: string): any, string
    if type(s) ~= "string" then
        return nil, "expected string, got " .. type(s)
    end
    local val, pos, err = decode_value(s, 1)
    if err then
        return nil, err .. " at position " .. tostring(pos)
    end
    return val, nil
end

M._decode_value = decode_value

return M
