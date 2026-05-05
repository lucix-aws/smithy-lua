-- ECDSA P-256 signing — lazy resolver
-- On first call to sign(), probes for OpenSSL FFI backend.
-- If available, uses it for the lifetime of the process.
-- Otherwise falls back to pure-Lua implementation.

local M = {}

local impl -- resolved backend module

local function resolve()
    if impl then return impl end

    -- Try OpenSSL first
    local ok, openssl = pcall(require, "smithy.crypto.ecdsa_openssl")
    if ok and openssl.available() then
        impl = openssl
    else
        impl = require("smithy.crypto.ecdsa_lua")
    end
    return impl
end

--- Sign a SHA-256 hash with ECDSA P-256.
--- @param d table: bigint private key
--- @param hash_bytes string: 32-byte raw SHA-256 hash
--- @return string: DER-encoded ECDSA signature
function M.sign(d, hash_bytes)
    return resolve().sign(d, hash_bytes)
end

--- DER-encode an ECDSA signature (r, s bigints). Only available on pure-Lua backend.
function M.der_encode(r, s)
    local lua_impl = require("smithy.crypto.ecdsa_lua")
    return lua_impl.der_encode(r, s)
end

--- Returns the name of the resolved backend ("openssl" or "lua").
function M.backend()
    resolve()
    if impl == require("smithy.crypto.ecdsa_openssl") then
        return "openssl"
    end
    return "lua"
end

return M
