-- ECDSA P-256 signing via OpenSSL FFI (LuaJIT)
-- Implements the same interface as the pure-Lua ecdsa module:
--   sign(d, hash_bytes) -> DER-encoded signature

local ffi = require("ffi")

ffi.cdef[[
    // BIGNUMs
    typedef struct bignum_st BIGNUM;
    BIGNUM *BN_new(void);
    BIGNUM *BN_bin2bn(const unsigned char *s, int len, BIGNUM *ret);
    void BN_free(BIGNUM *a);

    // EC key
    typedef struct ec_key_st EC_KEY;
    typedef struct ec_group_st EC_GROUP;
    EC_KEY *EC_KEY_new_by_curve_name(int nid);
    int EC_KEY_set_private_key(EC_KEY *key, const BIGNUM *prv);
    void EC_KEY_free(EC_KEY *key);

    // ECDSA signing
    int ECDSA_size(const EC_KEY *eckey);
    int ECDSA_sign(int type, const unsigned char *dgst, int dgstlen,
                   unsigned char *sig, unsigned int *siglen, EC_KEY *eckey);
]]

-- NID_X9_62_prime256v1 = 415 (P-256)
local NID_P256 = 415

local M = {}

-- Try to load libcrypto
local lib
local function load_lib()
    if lib then return lib end
    local paths = {
        "/opt/homebrew/lib/libcrypto.dylib",  -- macOS ARM Homebrew
        "/usr/local/lib/libcrypto.dylib",     -- macOS Intel Homebrew
        "libcrypto.so.3",                     -- Linux OpenSSL 3
        "libcrypto.so.1.1",                   -- Linux OpenSSL 1.1
        "libcrypto",                          -- system default (last resort)
    }
    for _, path in ipairs(paths) do
        local ok, l = pcall(ffi.load, path)
        if ok then
            lib = l
            return lib
        end
    end
    return nil
end

--- Check if this backend is available at runtime.
function M.available()
    return load_lib() ~= nil
end

--- Sign a SHA-256 hash with ECDSA P-256.
--- @param d table: bigint private key (10-limb representation)
--- @param hash_bytes string: 32-byte raw SHA-256 hash
--- @return string: DER-encoded ECDSA signature
function M.sign(d, hash_bytes)
    local crypto = load_lib()
    if not crypto then error("OpenSSL libcrypto not available") end

    assert(#hash_bytes == 32, "hash must be 32 bytes")

    -- Convert bigint d to 32-byte big-endian
    local bigint = require("smithy.crypto.bigint")
    local d_bytes = bigint.to_bytes(d)

    -- Create EC_KEY with P-256 curve
    local eckey = crypto.EC_KEY_new_by_curve_name(NID_P256)
    if eckey == nil then error("EC_KEY_new_by_curve_name failed") end

    -- Set private key
    local bn = crypto.BN_bin2bn(d_bytes, 32, nil)
    if bn == nil then
        crypto.EC_KEY_free(eckey)
        error("BN_bin2bn failed")
    end

    if crypto.EC_KEY_set_private_key(eckey, bn) ~= 1 then
        crypto.BN_free(bn)
        crypto.EC_KEY_free(eckey)
        error("EC_KEY_set_private_key failed")
    end
    crypto.BN_free(bn)

    -- Sign
    local sig_len = ffi.new("unsigned int[1]")
    local max_sig = crypto.ECDSA_size(eckey)
    local sig_buf = ffi.new("unsigned char[?]", max_sig)

    local rc = crypto.ECDSA_sign(0, hash_bytes, 32, sig_buf, sig_len, eckey)
    crypto.EC_KEY_free(eckey)

    if rc ~= 1 then error("ECDSA_sign failed") end

    return ffi.string(sig_buf, sig_len[0])
end

return M
