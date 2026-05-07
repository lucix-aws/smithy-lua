-- SigV4a signer: AWS Signature Version 4 Asymmetric

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")
local bigint = require("smithy.crypto.bigint")
local field = require("smithy.crypto.field")
local p256 = require("smithy.crypto.p256")
local ecdsa = require("smithy.crypto.ecdsa")
local http = require("smithy.http")
local sigv4 = require("smithy.signer")

local record M
    derive_key: function(access_key_id: string, secret_access_key: string): any, any, any
    sign: function(request: any, identity: any, props: {string:any}): any, any
end

local ALGORITHM = "AWS4-ECDSA-P256-SHA256"

local function hmac_kdf(key: string, label: string, context: string, bit_len: integer): string
    local fixed = label .. "\0" .. context ..
        string.char(
            math.floor(bit_len / 16777216) % 256,
            math.floor(bit_len / 65536) % 256,
            math.floor(bit_len / 256) % 256,
            bit_len % 256
        )

    local n = math.ceil((bit_len / 8) / 32)
    local output = ""
    for i = 1, n do
        local counter = string.char(0, 0, 0, i)
        output = output .. hmac.digest(key, counter .. fixed)
    end
    return output:sub(1, bit_len / 8)
end

local function ct_compare(a: string, b: string): integer
    assert(#a == #b, "ct_compare: length mismatch")
    local a_larger, b_larger = 0, 0
    for i = 1, #a do
        local ab, bb = string.byte(a, i), string.byte(b, i)
        local x = math.floor((bb - ab) / 256) % 2
        local y = math.floor((ab - bb) / 256) % 2
        if a_larger == 0 and b_larger == 0 then
            a_larger = x
            b_larger = y
        end
    end
    return a_larger - b_larger
end

local N_MINUS_2_BYTES = bigint.to_bytes(bigint.sub(field.N, bigint.from_int(2)))

function M.derive_key(access_key_id: string, secret_access_key: string): any, any, any
    local input_key = "AWS4A" .. secret_access_key
    local counter = 1

    while counter <= 255 do
        local context = access_key_id .. string.char(counter)
        local key_bytes = hmac_kdf(input_key, ALGORITHM, context, 256)

        if ct_compare(key_bytes, N_MINUS_2_BYTES) < 0 then
            local d = bigint.add(bigint.from_bytes(key_bytes), bigint.from_int(1))
            local Q = p256.scalar_base_mult(d)
            local qx, qy = p256.to_affine(Q)
            return d, qx, qy
        end
        counter = counter + 1
    end
    error("exhausted single-byte counter in key derivation")
end

local key_cache: {string:any} = { akid = nil, d = nil }

local function get_or_derive_key(identity: {string:any}): any
    if key_cache.akid == identity.access_key then
        return key_cache.d
    end
    local d = M.derive_key(identity.access_key as string, identity.secret_key as string)
    key_cache.akid = identity.access_key
    key_cache.d = d
    return d
end

function M.sign(request: any, identity: any, props: {string:any}): any, any
    local req = request as {string:any}
    local id = identity as {string:any}
    local d = get_or_derive_key(id)

    local host: string
    local path: string
    local query: string
    do
        local url = req.url as string
        local rest = url:match("^https?://(.+)$") or url
        local h, pq = rest:match("^([^/]+)(/.*)$")
        if not h then h = rest; pq = "/" end
        host = h
        local p, q = pq:match("^([^?]+)%?(.+)$")
        if p then path = p; query = q else path = pq; query = "" end
    end

    local body = ""
    if req.body then
        local b, err = http.read_all(req.body as http.Reader)
        if err then return nil, { type = "sdk", code = "SigningError", message = err } end
        body = b or ""
    end
    local payload_hash = sha256.hex_digest(body)

    local headers = req.headers as {string:string}
    if not headers then
        headers = {}
        req.headers = headers
    end
    headers["Host"] = host
    headers["X-Amz-Content-Sha256"] = payload_hash

    local amz_date = headers["X-Amz-Date"]
    if not amz_date then
        amz_date = os.date("!%Y%m%dT%H%M%SZ") as string
        headers["X-Amz-Date"] = amz_date
    end
    local date_stamp = amz_date:sub(1, 8)

    local region_set = (props.signing_region_set or props.region_set or { "*" }) as {string}
    headers["X-Amz-Region-Set"] = table.concat(region_set, ",")

    if id.session_token then
        headers["X-Amz-Security-Token"] = id.session_token as string
    end

    local IGNORED: {string:boolean} = { authorization = true, ["user-agent"] = true }
    local signed: {string} = {}
    local lower_map: {string:string} = {}
    for k, v in pairs(headers) do
        local lk = k:lower()
        if not IGNORED[lk] then
            signed[#signed + 1] = lk
            lower_map[lk] = v
        end
    end
    table.sort(signed)
    local signed_headers = table.concat(signed, ";")

    local canon_hdrs: {string} = {}
    for i = 1, #signed do
        canon_hdrs[i] = signed[i] .. ":" .. lower_map[signed[i]]:gsub("^%s+", ""):gsub("%s+$", "")
    end
    local canonical_headers_str = table.concat(canon_hdrs, "\n") .. "\n"

    local canonical_request = table.concat({
        req.method as string,
        sigv4.uri_encode(path, false):gsub("%%2F", "/"),
        "",
        canonical_headers_str,
        signed_headers,
        payload_hash,
    }, "\n")

    local signing_name = props.signing_name as string
    local scope = date_stamp .. "/" .. signing_name .. "/aws4_request"

    local string_to_sign = table.concat({
        ALGORITHM,
        amz_date,
        scope,
        sha256.hex_digest(canonical_request),
    }, "\n")

    local hash = sha256.digest(string_to_sign)
    local sig_der = ecdsa.sign(d, hash)

    local sig_hex: {string} = {}
    for i = 1, #sig_der do
        sig_hex[i] = string.format("%02x", string.byte(sig_der, i))
    end
    local signature = table.concat(sig_hex)

    headers["Authorization"] = string.format(
        "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
        ALGORITHM, id.access_key as string, scope, signed_headers, signature)

    req.body = http.string_reader(body)

    return request, nil
end

return M
