local bit = require("bit")
local buffer = require("string.buffer")

local module = {}

local k = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- integer to big-endian byte string
-- FIXME: blows up on i > 255
local function itobig8(i)
    if i <= 0xff then
        return '\x00\x00\x00\x00\x00\x00\x00' .. string.char(i)
    elseif i <= 0xffff then
        error('itobig8 2 byte')
    elseif i <= 0xffffff then
        error('itobig8 3 byte')
    elseif i <= 0xffffffff then
        error('itobig8 4 byte')
    end
end

-- FIXME: this is really bad i think
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

local function hexn(n)
    return string.format("%x", n)

end

local function stoi(str)
    return string.byte(str, 1) * 0x1000000 +
        string.byte(str, 2) * 0x10000 +
        string.byte(str, 3) * 0x100 +
        string.byte(str, 4)
end

local function itos(l)
    local s = ""
    for i = 1, 4 do
        local rem = l % 256
        s = string.char(rem) .. s
        l = (l - rem) / 256
    end
    return s
end

-- https://en.wikipedia.org/wiki/SHA-2
function module.SHA256(str)
    local h0 = 0x6a09e667
    local h1 = 0xbb67ae85
    local h2 = 0x3c6ef372
    local h3 = 0xa54ff53a
    local h4 = 0x510e527f
    local h5 = 0x9b05688c
    local h6 = 0x1f83d9ab
    local h7 = 0x5be0cd19

    local msg = pad512(str)
    for i=1,#msg,64 do
        block = string.sub(msg, i, i+64)

        w = {}
        for j=1,16 do
            local off = 1 + (j - 1) * 4
            w[j] = stoi(string.sub(block, off, off+3))
        end
        for j=17,64 do
            local s0 = bit.bxor(bit.ror(w[j-15], 7), bit.ror(w[j-15], 18), bit.rshift(w[j-15], 3))
            local s1 = bit.bxor(bit.ror(w[j-2], 17), bit.ror(w[j-2], 19), bit.rshift(w[j-2], 10))
            w[j] = w[j-16] + s0 + w[j-7] + s1
        end

        local a = h0
        local b = h1
        local c = h2
        local d = h3
        local e = h4
        local f = h5
        local g = h6
        local h = h7
        for j=1,64 do
            local s1 = bit.bxor(bit.ror(e, 6), bit.ror(e, 11), bit.ror(e, 25))
            local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
            local temp1 = h + s1 + ch + k[j] + w[j]
            local s0 = bit.bxor(bit.ror(a, 2), bit.ror(a, 13), bit.ror(a, 22))
            local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
            local temp2 = s0 + maj

            h = g
            g = f
            f = e
            e = d + temp1
            d = c
            c = b
            b = a
            a = temp1 + temp2


        end

            h0 = (h0 + a)
            h1 = (h1 + b)
            h2 = (h2 + c)
            h3 = (h3 + d)
            h4 = (h4 + e)
            h5 = (h5 + f)
            h6 = (h6 + g)
            h7 = (h7 + h)
    end

    return itos(h0) .. itos(h1) .. itos(h2) .. itos(h3) .. itos(h4) .. itos(h5) .. itos(h6) .. itos(h7)
end

print(hex(module.SHA256('')))

return module
