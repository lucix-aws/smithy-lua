-- smithy-lua runtime: SigV4 event stream message signer.

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")

local record M
    record Identity
        access_key: string
        secret_key: string
        session_token: string
    end

    record Props
        signing_name: string
        signing_region: string
    end

    record Signer
        _identity: Identity
        _region: string
        _service: string
        _prev: string

        sign: function(Signer, string, string, number): string
    end

    new: function(identity: Identity, props: Props, seed: string): Signer
end

function M.new(identity: M.Identity, props: M.Props, seed: string): M.Signer
    local signer: M.Signer = {
        _identity = identity,
        _region = props.signing_region,
        _service = props.signing_name,
        _prev = seed,
    } as M.Signer

    local Signer_mt: metatable<M.Signer> = { __index = {} as M.Signer }

    function signer:sign(headers_bytes: string, payload: string, now: number): string
        now = now or os.time()
        local date = os.date("!%Y%m%dT%H%M%SZ", now) as string
        local short_date = os.date("!%Y%m%d", now) as string

        local scope = short_date .. "/" .. self._region .. "/" .. self._service .. "/aws4_request"

        local string_to_sign = "AWS4-HMAC-SHA256-PAYLOAD\n"
            .. date .. "\n"
            .. scope .. "\n"
            .. self._prev .. "\n"
            .. sha256.hex_digest(headers_bytes) .. "\n"
            .. sha256.hex_digest(payload)

        local k_date = hmac.digest("AWS4" .. self._identity.secret_key, short_date)
        local k_region = hmac.digest(k_date, self._region)
        local k_service = hmac.digest(k_region, self._service)
        local k_signing = hmac.digest(k_service, "aws4_request")

        local sig = hmac.digest(k_signing, string_to_sign)

        self._prev = hmac.hex_digest(k_signing, string_to_sign)

        return sig
    end

    setmetatable(signer, Signer_mt)
    return signer
end

return M
