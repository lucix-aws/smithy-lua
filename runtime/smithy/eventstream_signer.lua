

local sha256 = require("smithy.crypto.sha256")
local hmac = require("smithy.crypto.hmac")

local M = { Identity = {}, Props = {}, Signer = {} }























function M.new(identity, props, seed)
   local signer = {
      _identity = identity,
      _region = props.signing_region,
      _service = props.signing_name,
      _prev = seed,
   }

   local Signer_mt = { __index = {} }

   function signer:sign(headers_bytes, payload, now)
      now = now or os.time()
      local date = os.date("!%Y%m%dT%H%M%SZ", now)
      local short_date = os.date("!%Y%m%d", now)

      local scope = short_date .. "/" .. self._region .. "/" .. self._service .. "/aws4_request"

      local string_to_sign = "AWS4-HMAC-SHA256-PAYLOAD\n" ..
      date .. "\n" ..
      scope .. "\n" ..
      self._prev .. "\n" ..
      sha256.hex_digest(headers_bytes) .. "\n" ..
      sha256.hex_digest(payload)

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
