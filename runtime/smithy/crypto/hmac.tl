-- smithy-lua runtime: HMAC-SHA-256

local sha256 = require("smithy.crypto.sha256")
local bit = require("bit")

local record hmac_mod
end

local BLOCK_SIZE = 64

function hmac_mod.digest(key: string, msg: string): string
    if #key > BLOCK_SIZE then
        key = sha256.digest(key)
    end
    if #key < BLOCK_SIZE then
        key = key .. string.rep("\0", BLOCK_SIZE - #key)
    end

    local opad: {string} = {}
    local ipad: {string} = {}
    for i = 1, BLOCK_SIZE do
        local b = string.byte(key, i)
        opad[i] = string.char(bit.bxor(b, 0x5c))
        ipad[i] = string.char(bit.bxor(b, 0x36))
    end

    return sha256.digest(table.concat(opad) .. sha256.digest(table.concat(ipad) .. msg))
end

function hmac_mod.hex_digest(key: string, msg: string): string
    local raw = hmac_mod.digest(key, msg)
    local out: {string} = {}
    for i = 1, #raw do
        out[i] = string.format("%02x", string.byte(raw, i))
    end
    return table.concat(out)
end

return hmac_mod
