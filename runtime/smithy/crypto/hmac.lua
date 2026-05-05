

local sha256 = require("smithy.crypto.sha256")
local bit = require("bit")

local hmac_mod = {}


local BLOCK_SIZE = 64

function hmac_mod.digest(key, msg)
   if #key > BLOCK_SIZE then
      key = sha256.digest(key)
   end
   if #key < BLOCK_SIZE then
      key = key .. string.rep("\0", BLOCK_SIZE - #key)
   end

   local opad = {}
   local ipad = {}
   for i = 1, BLOCK_SIZE do
      local b = string.byte(key, i)
      opad[i] = string.char(bit.bxor(b, 0x5c))
      ipad[i] = string.char(bit.bxor(b, 0x36))
   end

   return sha256.digest(table.concat(opad) .. sha256.digest(table.concat(ipad) .. msg))
end

function hmac_mod.hex_digest(key, msg)
   local raw = hmac_mod.digest(key, msg)
   local out = {}
   for i = 1, #raw do
      out[i] = string.format("%02x", string.byte(raw, i))
   end
   return table.concat(out)
end

return hmac_mod
