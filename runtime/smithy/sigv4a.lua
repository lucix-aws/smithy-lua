-- SigV4a signer: AWS Signature Version 4 Asymmetric
-- Derives ECDSA P-256 key from AWS credentials, signs with ECDSA instead of HMAC.

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")
local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")
local p256 = require("smithy.crypto.p256")
local ecdsa = require("smithy.crypto.ecdsa")
local http = require("smithy.http")
local sigv4 = require("smithy.signer")

local M = {}

local ALGORITHM = "AWS4-ECDSA-P256-SHA256"

-- NIST SP 800-108 KDF in Counter Mode using HMAC-SHA256
-- Returns `bit_len/8` bytes of derived key material.
local function hmac_kdf(key, label, context, bit_len)
    local fixed = label .. "\0" .. context ..
        string.char(
            math.floor(bit_len / 16777216) % 256,
            math.floor(bit_len / 65536) % 256,
            math.floor(bit_len / 256) % 256,
            bit_len % 256
        )

    local n = math.ceil((bit_len / 8) / 32) -- 32 = SHA-256 output size
    local output = ""
    for i = 1, n do
        local counter = string.char(0, 0, 0, i)
        output = output .. hmac.digest(key, counter .. fixed)
    end
    return output:sub(1, bit_len / 8)
end

-- Constant-time comparison of two byte strings
local function ct_compare(a, b)
    assert(#a == #b, "ct_compare: length mismatch")
    -- Returns -1 if a < b, 0 if equal, 1 if a > b
    local a_larger, b_larger = 0, 0
    for i = 1, #a do
        local ab, bb = string.byte(a, i), string.byte(b, i)
        local x = math.floor((bb - ab) / 256) % 2  -- 1 if ab > bb
        local y = math.floor((ab - bb) / 256) % 2  -- 1 if bb > ab
        -- Only set if not already determined
        if a_larger == 0 and b_larger == 0 then
            a_larger = x
            b_larger = y
        end
    end
    return a_larger - b_larger
end

-- n - 2 for P-256 curve order, precomputed as raw bytes
local N_MINUS_2_BYTES = bigint.to_bytes(bigint.sub(field.N, bigint.from_int(2)))

-- Derive ECDSA private key from AWS credentials
-- Based on FIPS 186-4 Appendix B.4.2
function M.derive_key(access_key_id, secret_access_key)
    local input_key = "AWS4A" .. secret_access_key
    local counter = 1

    while counter <= 255 do
        local context = access_key_id .. string.char(counter)
        local key_bytes = hmac_kdf(input_key, ALGORITHM, context, 256)

        -- Check if candidate < n-2
        if ct_compare(key_bytes, N_MINUS_2_BYTES) < 0 then
            -- d = candidate + 1
            local d = bigint.add(bigint.from_bytes(key_bytes), bigint.from_int(1))
            -- Compute public key Q = d * G
            local Q = p256.scalar_base_mult(d)
            local qx, qy = p256.to_affine(Q)
            return d, qx, qy
        end
        counter = counter + 1
    end
    error("exhausted single-byte counter in key derivation")
end

-- Key cache: avoid re-deriving for the same AKID
local key_cache = { akid = nil, d = nil }

local function get_or_derive_key(identity)
    if key_cache.akid == identity.access_key then
        return key_cache.d
    end
    local d = M.derive_key(identity.access_key, identity.secret_key)
    key_cache.akid = identity.access_key
    key_cache.d = d
    return d
end

--- Sign an HTTP request with SigV4a.
--- @param request table: HTTP request {method, url, headers, body}
--- @param identity table: {access_key, secret_key, session_token?}
--- @param props table: {signing_name, region_set}
--- @return table, table: signed request, err
function M.sign(request, identity, props)
    local d = get_or_derive_key(identity)

    -- Parse URL (reuse sigv4 helper)
    local host, path, query
    do
        local url = request.url
        local rest = url:match("^https?://(.+)$") or url
        host, path = rest:match("^([^/]+)(/.*)$")
        if not host then host = rest; path = "/" end
        local p, q = path:match("^([^?]+)%?(.+)$")
        if p then path = p; query = q else query = "" end
    end

    -- Read body
    local body = ""
    if request.body then
        local b, err = http.read_all(request.body)
        if err then return nil, { type = "sdk", code = "SigningError", message = err } end
        body = b or ""
    end
    local payload_hash = sha256.hex_digest(body)

    -- Set required headers
    request.headers = request.headers or {}
    request.headers["Host"] = host
    request.headers["X-Amz-Content-Sha256"] = payload_hash

    local amz_date = request.headers["X-Amz-Date"]
    if not amz_date then
        amz_date = os.date("!%Y%m%dT%H%M%SZ")
        request.headers["X-Amz-Date"] = amz_date
    end
    local date_stamp = amz_date:sub(1, 8)

    -- Region set header
    local region_set = props.region_set or { "*" }
    request.headers["X-Amz-Region-Set"] = table.concat(region_set, ",")

    if identity.session_token then
        request.headers["X-Amz-Security-Token"] = identity.session_token
    end

    -- Build signed headers (sorted lowercase)
    local IGNORED = { authorization = true, ["user-agent"] = true }
    local signed = {}
    local lower_map = {}
    for k, v in pairs(request.headers) do
        local lk = k:lower()
        if not IGNORED[lk] then
            signed[#signed + 1] = lk
            lower_map[lk] = v
        end
    end
    table.sort(signed)
    local signed_headers = table.concat(signed, ";")

    -- Canonical headers
    local canon_hdrs = {}
    for i = 1, #signed do
        canon_hdrs[i] = signed[i] .. ":" .. lower_map[signed[i]]:gsub("^%s+", ""):gsub("%s+$", "")
    end
    local canonical_headers_str = table.concat(canon_hdrs, "\n") .. "\n"

    -- Canonical request
    local canonical_request = table.concat({
        request.method,
        sigv4.uri_encode(path, false):gsub("%%2F", "/"),
        "", -- query string handling simplified
        canonical_headers_str,
        signed_headers,
        payload_hash,
    }, "\n")

    -- Credential scope: no region in v4a
    local scope = date_stamp .. "/" .. props.signing_name .. "/aws4_request"

    -- String to sign
    local string_to_sign = table.concat({
        ALGORITHM,
        amz_date,
        scope,
        sha256.hex_digest(canonical_request),
    }, "\n")

    -- Sign with ECDSA
    local hash = sha256.digest(string_to_sign)
    local sig_der = ecdsa.sign(d, hash)

    -- Hex-encode the DER signature
    local sig_hex = {}
    for i = 1, #sig_der do
        sig_hex[i] = string.format("%02x", string.byte(sig_der, i))
    end
    local signature = table.concat(sig_hex)

    -- Authorization header
    request.headers["Authorization"] = string.format(
        "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
        ALGORITHM, identity.access_key, scope, signed_headers, signature)

    -- Re-wrap body
    request.body = http.string_reader(body)

    return request, nil
end

return M
