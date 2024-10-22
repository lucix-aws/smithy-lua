local bit = require("bit")
local buffer = require("string.buffer")

local module = {}

function module.SHA256(str)
end

-- integer to big-endian byte string
-- FIXME: blows up on sizes bigger
local function itobig8(i)
    if i <= 0xff then
        return '\x00\x00\x00\x00\x00\x00\x00' .. string.char(i)
    elseif i <= 0xffff then
    elseif i <= 0xffffff then
    elseif i <= 0xffffffff then
    end
end

-- FIXME: this is really bad
local function pad512(str)
    local buf = buffer.new()
    buf:set(str)
    local topad = 64 - #str % 64
    local topadnosz = topad - 8

    buf:put('\x80')
    for i = 1,topadnosz-1 do
        buf:put('\x00')
    end
    buf:put(itobig8(#str*8))
    return buf:tostring()
end


local function hex(buf)
    local hexbuf = buffer.new(#buf*2)
    for i = 1,#buf do
        hexbuf:put(string.format("%02x", string.byte(buf, i)))
    end
    return hexbuf:tostring()
end

return module
