-- ECDSA signing with P-256 and ASN.1 DER signature encoding

local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")
local p256 = require("smithy.crypto.p256")

local record M
    sign: function(d: bigint.BigInt, hash_bytes: string): string
    der_encode: function(r: bigint.BigInt, s: bigint.BigInt): string
    random_bytes: function(n: number): string
end

function M.random_bytes(n: number): string
    local f = assert(io.open("/dev/urandom", "rb"))
    local data = f:read(n) as string
    f:close()
    assert(data and #data == n, "failed to read random bytes")
    return data
end

local function random_k(): bigint.BigInt
    local n = field.N
    for _ = 1, 256 do
        local bytes = M.random_bytes(32)
        local k = bigint.from_bytes(bytes)
        if not bigint.is_zero(k) and bigint.cmp(k, n) < 0 then
            return k
        end
    end
    error("failed to generate random k")
end

function M.sign(d: bigint.BigInt, hash_bytes: string): string
    assert(#hash_bytes == 32, "hash must be 32 bytes")
    local z = bigint.from_bytes(hash_bytes)
    local n = field.N

    for _ = 1, 256 do
        local k = random_k()
        local R = p256.scalar_base_mult(k)
        local rx, _ = p256.to_affine(R)
        if rx then
            local r = field.mod_n(rx)
            if not bigint.is_zero(r) then
                local k_inv = field.inv_n(k)
                local rd = field.mul_mod_n(r, d)
                local zrd = field.mod_n((bigint.add(z, rd)))
                local s = field.mul_mod_n(k_inv, zrd)
                if not bigint.is_zero(s) then
                    return M.der_encode(r, s)
                end
            end
        end
    end
    error("ECDSA sign failed after 256 attempts")
end

function M.der_encode(r: bigint.BigInt, s: bigint.BigInt): string
    local function encode_integer(v: bigint.BigInt): string
        local bytes = bigint.to_bytes(v)
        local start = 1
        while start < 32 and string.byte(bytes, start) == 0 do
            start = start + 1
        end
        local trimmed = bytes:sub(start)
        if string.byte(trimmed, 1) >= 128 then
            trimmed = "\0" .. trimmed
        end
        return "\x02" .. string.char(#trimmed) .. trimmed
    end

    local r_enc = encode_integer(r)
    local s_enc = encode_integer(s)
    local inner = r_enc .. s_enc
    return "\x30" .. string.char(#inner) .. inner
end

return M
