

local bigint = require("smithy.crypto.bigint")

local M = {}
















local LIMBS = 10
local BASE = 0x4000000

M.P = bigint.from_hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")
M.N = bigint.from_hex("FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")

function M.mod_p(a)
   while bigint.cmp(a, M.P) >= 0 do
      a = bigint.sub(a, M.P)
   end
   return a
end

function M.fadd(a, b)
   local r, carry = bigint.add(a, b)
   if carry > 0 then
      r = bigint.sub(r, M.P)
   end
   return M.mod_p(r)
end

function M.fsub(a, b)
   if bigint.cmp(a, b) >= 0 then
      return bigint.sub(a, b)
   else
      local t = bigint.add(a, M.P)
      return bigint.sub(t, b)
   end
end

function M.fmul(a, b)
   local t = {}
   for i = 1, 20 do t[i] = 0 end
   for i = 1, LIMBS do
      local ai = a[i]
      for j = 1, LIMBS do
         t[i + j - 1] = t[i + j - 1] + ai * b[j]
      end
      for k = 1, 19 do
         if t[k] >= 2 ^ 53 * 0.5 then
            local carry = math.floor(t[k] / BASE)
            t[k] = t[k] - carry * BASE
            t[k + 1] = t[k + 1] + carry
         end
      end
   end
   for i = 1, 19 do
      local carry = math.floor(t[i] / BASE)
      t[i] = t[i] % BASE
      t[i + 1] = t[i + 1] + carry
   end
   t[20] = t[20] % BASE
   return M.reduce_wide(t)
end

function M.reduce_wide(t)
   for i = 1, 19 do
      local carry = math.floor(t[i] / BASE)
      t[i] = t[i] % BASE
      t[i + 1] = t[i + 1] + carry
   end
   t[20] = t[20] % BASE

   local function get_bit(bit_pos)
      local limb_idx = math.floor(bit_pos / 26) + 1
      local bit_in_limb = bit_pos % 26
      if limb_idx > 20 then return 0 end
      return math.floor(t[limb_idx] / (2 ^ bit_in_limb)) % 2
   end

   local function get_byte(byte_pos)
      local b = 0
      for j = 7, 0, -1 do
         b = b * 2 + get_bit(byte_pos * 8 + j)
      end
      return b
   end

   local c = {}
   for i = 0, 15 do
      c[i] = get_byte(i * 4) + get_byte(i * 4 + 1) * 256 + get_byte(i * 4 + 2) * 65536 + get_byte(i * 4 + 3) * 16777216
   end

   local function make(w7, w6, w5, w4, w3, w2, w1, w0)
      local b = {}
      local words = { w0, w1, w2, w3, w4, w5, w6, w7 }
      for i = 1, 8 do
         local w = words[i]
         b[#b + 1] = string.char(w % 256)
         w = math.floor(w / 256)
         b[#b + 1] = string.char(w % 256)
         w = math.floor(w / 256)
         b[#b + 1] = string.char(w % 256)
         w = math.floor(w / 256)
         b[#b + 1] = string.char(w % 256)
      end
      local be = {}
      for i = 32, 1, -1 do be[#be + 1] = b[i] end
      return bigint.from_bytes(table.concat(be))
   end

   local s1 = make(c[7], c[6], c[5], c[4], c[3], c[2], c[1], c[0])
   local s2 = make(c[15], c[14], c[13], c[12], c[11], 0, 0, 0)
   local s3 = make(0, c[15], c[14], c[13], c[12], 0, 0, 0)
   local s4 = make(c[15], c[14], 0, 0, 0, c[10], c[9], c[8])
   local s5 = make(c[8], c[13], c[15], c[14], c[13], c[11], c[10], c[9])
   local s6 = make(c[10], c[8], 0, 0, 0, c[13], c[12], c[11])
   local s7 = make(c[11], c[9], 0, 0, c[15], c[14], c[13], c[12])
   local s8 = make(c[12], 0, c[10], c[9], c[8], c[15], c[14], c[13])
   local s9 = make(c[13], 0, c[11], c[10], c[9], 0, c[15], c[14])

   local r = s1
   r = M.fadd(r, s2); r = M.fadd(r, s2)
   r = M.fadd(r, s3); r = M.fadd(r, s3)
   r = M.fadd(r, s4); r = M.fadd(r, s5)
   r = M.fsub(r, s6); r = M.fsub(r, s7)
   r = M.fsub(r, s8); r = M.fsub(r, s9)
   return M.mod_p(r)
end

function M.fsqr(a)
   return M.fmul(a, a)
end

function M.finv(a)
   local pm2 = bigint.from_hex("FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFD")
   return M.fpow(a, pm2)
end

function M.fpow(a, e)
   local result = bigint.from_int(1)
   local base = bigint.copy(a)
   local e_bytes = bigint.to_bytes(e)
   for i = 32, 1, -1 do
      local byte = string.byte(e_bytes, i)
      for _ = 0, 7 do
         if byte % 2 == 1 then
            result = M.fmul(result, base)
         end
         base = M.fsqr(base)
         byte = math.floor(byte / 2)
      end
   end
   return result
end

function M.mod_n(a)
   while bigint.cmp(a, M.N) >= 0 do
      a = bigint.sub(a, M.N)
   end
   return a
end

function M.inv_n(a)
   local nm2 = bigint.sub(M.N, bigint.from_int(2))
   local result = bigint.from_int(1)
   local base = bigint.copy(a)
   local e_bytes = bigint.to_bytes(nm2)
   for i = 32, 1, -1 do
      local byte = string.byte(e_bytes, i)
      for _ = 0, 7 do
         if byte % 2 == 1 then
            result = M.mul_mod_n(result, base)
         end
         base = M.mul_mod_n(base, base)
         byte = math.floor(byte / 2)
      end
   end
   return result
end

function M.mul_mod_n(a, b)
   local t = {}
   for i = 1, 20 do t[i] = 0 end
   for i = 1, LIMBS do
      local ai = a[i]
      for j = 1, LIMBS do
         t[i + j - 1] = t[i + j - 1] + ai * b[j]
      end
      for k = 1, 19 do
         if t[k] >= 2 ^ 50 then
            local carry = math.floor(t[k] / BASE)
            t[k] = t[k] - carry * BASE
            t[k + 1] = t[k + 1] + carry
         end
      end
   end
   for i = 1, 19 do
      local carry = math.floor(t[i] / BASE)
      t[i] = t[i] % BASE
      t[i + 1] = t[i + 1] + carry
   end
   t[20] = t[20] % BASE

   local function get_bit(bp)
      local li = math.floor(bp / 26) + 1
      local bi = bp % 26
      if li > 20 then return 0 end
      return math.floor(t[li] / (2 ^ bi)) % 2
   end

   local bytes_le = {}
   for i = 0, 63 do
      local v = 0
      for j = 7, 0, -1 do
         v = v * 2 + get_bit(i * 8 + j)
      end
      bytes_le[i + 1] = v
   end

   local lo_be = {}
   local hi_be = {}
   for i = 32, 1, -1 do lo_be[#lo_be + 1] = string.char(bytes_le[i]) end
   for i = 64, 33, -1 do hi_be[#hi_be + 1] = string.char(bytes_le[i]) end

   local lo = bigint.from_bytes(table.concat(lo_be))
   local hi = bigint.from_bytes(table.concat(hi_be))

   if bigint.is_zero(hi) then
      return M.mod_n_simple(lo)
   end

   local R256 = bigint.from_hex("00000000FFFFFFFF00000000000000004319055258E8617B0C46353D039CDAAF")
   local hi_r = M.mul_mod_n(hi, R256)
   local result = bigint.add(hi_r, lo)
   return M.mod_n_simple(result)
end

function M.mod_n_simple(a)
   while bigint.cmp(a, M.N) >= 0 do
      a = bigint.sub(a, M.N)
   end
   return a
end

return M
