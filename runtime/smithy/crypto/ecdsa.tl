-- ECDSA P-256 signing — lazy resolver

local bigint = require("smithy.crypto.bigint")

local record M
    sign: function(d: bigint.BigInt, hash_bytes: string): string
    der_encode: function(r: bigint.BigInt, s: bigint.BigInt): string
    backend: function(): string
end

local record Backend
    sign: function(d: bigint.BigInt, hash_bytes: string): string
    available: function(): boolean
end

local impl: Backend

local function resolve(): Backend
    if impl then return impl end
    local ok, openssl = pcall(require, "smithy.crypto.ecdsa_openssl") as (boolean, Backend)
    if ok and openssl.available() then
        impl = openssl
    else
        impl = require("smithy.crypto.ecdsa_lua") as Backend
    end
    return impl
end

function M.sign(d: bigint.BigInt, hash_bytes: string): string
    return resolve().sign(d, hash_bytes)
end

function M.der_encode(r: bigint.BigInt, s: bigint.BigInt): string
    local lua_impl = require("smithy.crypto.ecdsa_lua")
    return lua_impl.der_encode(r, s)
end

function M.backend(): string
    resolve()
    local openssl = require("smithy.crypto.ecdsa_openssl") as Backend
    if impl == openssl then
        return "openssl"
    end
    return "lua"
end

return M
