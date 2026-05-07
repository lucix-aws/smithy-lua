

local bigint = require("smithy.crypto.bigint")

local M = {}










local impl

local function resolve()
   if impl then return impl end
   local ok, openssl = pcall(require, "smithy.crypto.ecdsa_openssl")
   if ok and openssl.available() then
      impl = openssl
   else
      impl = require("smithy.crypto.ecdsa_lua")
   end
   return impl
end

function M.sign(d, hash_bytes)
   return resolve().sign(d, hash_bytes)
end

function M.der_encode(r, s)
   local lua_impl = require("smithy.crypto.ecdsa_lua")
   return lua_impl.der_encode(r, s)
end

function M.backend()
   resolve()
   local openssl = require("smithy.crypto.ecdsa_openssl")
   if impl == openssl then
      return "openssl"
   end
   return "lua"
end

return M
