-- smithy-lua runtime: Base64 encoding/decoding

local concat = table.concat
local floor = math.floor

local record M
    encode: function(s: string): string
    decode: function(s: string): string
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64lookup: {integer:integer} = {}
for i = 1, 64 do b64lookup[b64chars:byte(i)] = i - 1 end

function M.encode(s: string): string
    local out: {string} = {}
    local n = 0
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local rem = #s - i + 1
        n = n + 1; out[n] = b64chars:sub(floor(v / 262144) % 64 + 1, floor(v / 262144) % 64 + 1)
        n = n + 1; out[n] = b64chars:sub(floor(v / 4096) % 64 + 1, floor(v / 4096) % 64 + 1)
        n = n + 1; out[n] = rem > 1 and b64chars:sub(floor(v / 64) % 64 + 1, floor(v / 64) % 64 + 1) or "="
        n = n + 1; out[n] = rem > 2 and b64chars:sub(v % 64 + 1, v % 64 + 1) or "="
    end
    return concat(out)
end

function M.decode(s: string): string
    s = s:gsub("%s", "")
    local out: {string} = {}
    local n = 0
    for i = 1, #s, 4 do
        local a = b64lookup[s:byte(i)] or 0
        local b = b64lookup[s:byte(i + 1)] or 0
        local c = b64lookup[s:byte(i + 2)] or 0
        local d = b64lookup[s:byte(i + 3)] or 0
        local v = a * 262144 + b * 4096 + c * 64 + d
        n = n + 1; out[n] = string.char(floor(v / 65536) % 256)
        if s:byte(i + 2) ~= 61 then
            n = n + 1; out[n] = string.char(floor(v / 256) % 256)
        end
        if s:byte(i + 3) ~= 61 then
            n = n + 1; out[n] = string.char(v % 256)
        end
    end
    return concat(out)
end

return M
