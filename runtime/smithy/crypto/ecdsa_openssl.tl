-- ECDSA P-256 signing via OpenSSL FFI (LuaJIT)

local ffi = require("ffi")
local bigint = require("smithy.crypto.bigint")

ffi.cdef[[
    typedef struct bignum_st BIGNUM;
    BIGNUM *BN_new(void);
    BIGNUM *BN_bin2bn(const unsigned char *s, int len, BIGNUM *ret);
    void BN_free(BIGNUM *a);
    typedef struct ec_key_st EC_KEY;
    typedef struct ec_group_st EC_GROUP;
    EC_KEY *EC_KEY_new_by_curve_name(int nid);
    int EC_KEY_set_private_key(EC_KEY *key, const BIGNUM *prv);
    void EC_KEY_free(EC_KEY *key);
    int ECDSA_size(const EC_KEY *eckey);
    int ECDSA_sign(int type, const unsigned char *dgst, int dgstlen,
                   unsigned char *sig, unsigned int *siglen, EC_KEY *eckey);
]]

local NID_P256 = 415

local record OpenSSLLib
    EC_KEY_new_by_curve_name: function(integer): ffi.CData
    EC_KEY_set_private_key: function(ffi.CData, ffi.CData): integer
    EC_KEY_free: function(ffi.CData)
    BN_bin2bn: function(string, integer, ffi.CData): ffi.CData
    BN_free: function(ffi.CData)
    ECDSA_size: function(ffi.CData): number
    ECDSA_sign: function(integer, string, integer, ffi.CData, ffi.CData, ffi.CData): integer
end

local record M
    sign: function(d: bigint.BigInt, hash_bytes: string): string
    available: function(): boolean
end

local lib: OpenSSLLib

local function load_lib(): OpenSSLLib
    if lib then return lib end
    local paths = {
        "/opt/homebrew/lib/libcrypto.dylib",
        "/usr/local/lib/libcrypto.dylib",
        "libcrypto.so.3",
        "libcrypto.so.1.1",
        "libcrypto",
    }
    for _, path in ipairs(paths) do
        local ok, l = pcall(ffi.load, path) as (boolean, OpenSSLLib)
        if ok then
            lib = l
            return lib
        end
    end
    return nil
end

function M.available(): boolean
    return load_lib() ~= nil
end

function M.sign(d: bigint.BigInt, hash_bytes: string): string
    local crypto = load_lib()
    if not crypto then error("OpenSSL libcrypto not available") end
    assert(#hash_bytes == 32, "hash must be 32 bytes")

    local d_bytes = bigint.to_bytes(d)
    local eckey = crypto.EC_KEY_new_by_curve_name(NID_P256)
    if eckey == nil then error("EC_KEY_new_by_curve_name failed") end

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

    local sig_len = ffi.new("unsigned int[1]")
    local max_sig = crypto.ECDSA_size(eckey) as integer
    local sig_buf = ffi.new("unsigned char[?]", max_sig)

    local rc = crypto.ECDSA_sign(0, hash_bytes, 32, sig_buf, sig_len, eckey)
    crypto.EC_KEY_free(eckey)

    if rc ~= 1 then error("ECDSA_sign failed") end
    return ffi.string(sig_buf, (sig_len as {integer})[0])
end

return M
