-- smithy-lua runtime: SigV4 event stream message signer.
-- Each message is signed using the signature of the previous message (chaining).
-- The seed is the signature from the initial HTTP request.

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")

local M = {}

--- Create a new event stream signer.
--- @param identity table: { access_key, secret_key, session_token? }
--- @param props table: { signing_name, signing_region }
--- @param seed string: hex-encoded signature from the initial HTTP request
--- @return table: signer with :sign(headers_bytes, payload, now) method
function M.new(identity, props, seed)
    local signer = {
        _identity = identity,
        _region = props.signing_region,
        _service = props.signing_name,
        _prev = seed, -- hex-encoded previous signature
    }

    --- Sign a message. Returns raw signature bytes (not hex).
    --- @param headers_bytes string: encoded event headers
    --- @param payload string: event payload (the full inner frame for envelope signing)
    --- @param now number|nil: os.time() override for testing
    --- @return string: raw signature bytes
    function signer:sign(headers_bytes, payload, now)
        now = now or os.time()
        local date = os.date("!%Y%m%dT%H%M%SZ", now)
        local short_date = os.date("!%Y%m%d", now)

        local scope = short_date .. "/" .. self._region .. "/" .. self._service .. "/aws4_request"

        local string_to_sign = "AWS4-HMAC-SHA256-PAYLOAD\n"
            .. date .. "\n"
            .. scope .. "\n"
            .. self._prev .. "\n"
            .. sha256.hex_digest(headers_bytes) .. "\n"
            .. sha256.hex_digest(payload)

        -- Derive signing key
        local k_date = hmac.digest("AWS4" .. self._identity.secret_key, short_date)
        local k_region = hmac.digest(k_date, self._region)
        local k_service = hmac.digest(k_region, self._service)
        local k_signing = hmac.digest(k_service, "aws4_request")

        -- Compute signature (raw bytes)
        local sig = hmac.digest(k_signing, string_to_sign)

        -- Update previous signature (hex-encoded for next iteration)
        self._prev = hmac.hex_digest(k_signing, string_to_sign)

        return sig
    end

    return signer
end

return M
