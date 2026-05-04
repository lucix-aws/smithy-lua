-- smithy-lua runtime: HMAC-SHA-256
-- RFC 2104 HMAC using SHA-256.

local sha256 = require("smithy.crypto.sha256")

local M = {}

local BLOCK_SIZE = 64

--- Compute HMAC-SHA-256. Returns 32 raw bytes.
function M.digest(key, msg)
    -- keys longer than block size are hashed first
    if #key > BLOCK_SIZE then
        key = sha256.digest(key)
    end
    -- pad key to block size
    if #key < BLOCK_SIZE then
        key = key .. string.rep("\0", BLOCK_SIZE - #key)
    end

    local opad, ipad = {}, {}
    for i = 1, BLOCK_SIZE do
        local b = string.byte(key, i)
        opad[i] = string.char(bit.bxor(b, 0x5c))
        ipad[i] = string.char(bit.bxor(b, 0x36))
    end
    opad = table.concat(opad)
    ipad = table.concat(ipad)

    return sha256.digest(opad .. sha256.digest(ipad .. msg))
end

--- Compute HMAC-SHA-256. Returns 64-char hex string.
function M.hex_digest(key, msg)
    local raw = M.digest(key, msg)
    local out = {}
    for i = 1, #raw do
        out[i] = string.format("%02x", string.byte(raw, i))
    end
    return table.concat(out)
end

return M
