

local bit = require("bit")
local sha256 = require("smithy.crypto.sha256")

local M = {}




local BLOCK_SIZE = 64

function M.digest(key, msg)
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
   local opad_s = table.concat(opad)
   local ipad_s = table.concat(ipad)

   return sha256.digest(opad_s .. sha256.digest(ipad_s .. msg))
end

function M.hex_digest(key, msg)
   local raw = M.digest(key, msg)
   local out = {}
   for i = 1, #raw do
      out[i] = string.format("%02x", string.byte(raw, i))
   end
   return table.concat(out)
end

return M
