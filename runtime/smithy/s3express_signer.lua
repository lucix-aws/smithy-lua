

local signer = require("smithy.signer")

local M = {}



function M.sign(request, identity, props)
   local req = request
   local id = identity
   local headers = req.headers
   if not headers then
      headers = {}
      req.headers = headers
   end
   headers["x-amz-s3session-token"] = id.session_token

   local signing_identity = {
      access_key = id.access_key,
      secret_key = id.secret_key,
   }
   return signer.sign(request, signing_identity, props)
end

return M
