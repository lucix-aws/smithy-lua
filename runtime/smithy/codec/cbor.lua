



local bit = require("bit")
local ffi = require("ffi")
local schema_mod = require("smithy.schema")
local stype = schema_mod.type

local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local concat = table.concat
local floor = math.floor
local huge = math.huge
local byte = string.byte

local char = string.char


local function ffi_get(cdata, idx)
   return (cdata)[idx]
end
local function ffi_set(cdata, idx, val)
   (cdata)[idx] = val
end

local M = {}




local M_mt = { __index = M }

function M.new(_settings)
   return setmetatable({}, M_mt)
end


local MT_UINT = 0
local MT_NEGINT = 1
local MT_BYTES = 2
local MT_TEXT = 3
local MT_ARRAY = 4
local MT_MAP = 5
local MT_TAG = 6
local MT_SIMPLE = 7

local function encode_uint(mt, n, buf, pos)
   local major = lshift(mt, 5)
   if n < 24 then
      pos = pos + 1; buf[pos] = char(bor(major, n))
   elseif n < 256 then
      pos = pos + 1; buf[pos] = char(bor(major, 24), n)
   elseif n < 65536 then
      pos = pos + 1; buf[pos] = char(bor(major, 25),
      rshift(n, 8), band(n, 0xFF))
   elseif n < 4294967296 then
      pos = pos + 1; buf[pos] = char(bor(major, 26),
      band(rshift(n, 24), 0xFF), band(rshift(n, 16), 0xFF),
      band(rshift(n, 8), 0xFF), band(n, 0xFF))
   else
      local hi = floor(n / 4294967296)
      local lo = n - hi * 4294967296
      pos = pos + 1; buf[pos] = char(bor(major, 27),
      band(rshift(hi, 24), 0xFF), band(rshift(hi, 16), 0xFF),
      band(rshift(hi, 8), 0xFF), band(hi, 0xFF),
      band(rshift(lo, 24), 0xFF), band(rshift(lo, 16), 0xFF),
      band(rshift(lo, 8), 0xFF), band(lo, 0xFF))
   end
   return pos
end

local function encode_int(v, buf, pos)
   if v >= 0 then
      return encode_uint(MT_UINT, v, buf, pos)
   else
      return encode_uint(MT_NEGINT, -1 - v, buf, pos)
   end
end

local dbl_buf = ffi.new("double[1]")
local u64_buf = ffi.cast("uint8_t*", dbl_buf)

local function encode_double(v, buf, pos)
   if v ~= v then
      pos = pos + 1; buf[pos] = char(0xF9, 0x7E, 0x00)
      return pos
   end
   local f32 = ffi.new("float[1]")
   ffi_set(f32, 0, v)
   if ffi_get(f32, 0) == v or (v ~= v) then
      if v == huge then
         pos = pos + 1; buf[pos] = char(0xF9, 0x7C, 0x00)
         return pos
      elseif v == -huge then
         pos = pos + 1; buf[pos] = char(0xF9, 0xFC, 0x00)
         return pos
      end
      local u32 = ffi.cast("uint8_t*", f32)
      pos = pos + 1; buf[pos] = char(0xFA,
      ffi_get(u32, 3), ffi_get(u32, 2), ffi_get(u32, 1), ffi_get(u32, 0))
      return pos
   end
   ffi_set(dbl_buf, 0, v)
   pos = pos + 1; buf[pos] = char(0xFB,
   ffi_get(u64_buf, 7), ffi_get(u64_buf, 6), ffi_get(u64_buf, 5), ffi_get(u64_buf, 4),
   ffi_get(u64_buf, 3), ffi_get(u64_buf, 2), ffi_get(u64_buf, 1), ffi_get(u64_buf, 0))
   return pos
end

local function encode_bytes(s, buf, pos)
   pos = encode_uint(MT_BYTES, #s, buf, pos)
   if #s > 0 then
      pos = pos + 1; buf[pos] = s
   end
   return pos
end

local function encode_text(s, buf, pos)
   pos = encode_uint(MT_TEXT, #s, buf, pos)
   if #s > 0 then
      pos = pos + 1; buf[pos] = s
   end
   return pos
end

local function encode_float32(v, buf, pos)
   local f32 = ffi.new("float[1]")
   ffi_set(f32, 0, v)
   local u32 = ffi.cast("uint8_t*", f32)
   pos = pos + 1; buf[pos] = char(0xFA,
   ffi_get(u32, 3), ffi_get(u32, 2), ffi_get(u32, 1), ffi_get(u32, 0))
   return pos
end

local function encode_float64(v, buf, pos)
   ffi_set(dbl_buf, 0, v)
   pos = pos + 1; buf[pos] = char(0xFB,
   ffi_get(u64_buf, 7), ffi_get(u64_buf, 6), ffi_get(u64_buf, 5), ffi_get(u64_buf, 4),
   ffi_get(u64_buf, 3), ffi_get(u64_buf, 2), ffi_get(u64_buf, 1), ffi_get(u64_buf, 0))
   return pos
end

local BREAK = char(0xFF)

local function encode_value(v, schema, buf, pos)
   if v == nil then
      pos = pos + 1; buf[pos] = char(0xF6)
      return pos
   end

   local st = schema.type

   if st == stype.STRUCTURE then
      local members = schema:members() or {}
      local keys = {}
      for k in pairs(members) do
         if (v)[k] ~= nil then keys[#keys + 1] = k end
      end
      table.sort(keys)
      pos = pos + 1; buf[pos] = char(0xBF)
      for _, k in ipairs(keys) do
         pos = encode_text(k, buf, pos)
         pos = encode_value((v)[k], members[k], buf, pos)
      end
      pos = pos + 1; buf[pos] = BREAK
      return pos

   elseif st == stype.MAP then
      local val_schema = schema.map_value
      if not val_schema then
         local fallback = { type = stype.STRING }
         val_schema = fallback
      end
      local keys = {}
      local map = v
      for k in pairs(map) do keys[#keys + 1] = k end
      table.sort(keys)
      pos = pos + 1; buf[pos] = char(0xBF)
      for _, k in ipairs(keys) do
         pos = encode_text(k, buf, pos)
         pos = encode_value(map[k], val_schema, buf, pos)
      end
      pos = pos + 1; buf[pos] = BREAK
      return pos

   elseif st == stype.LIST then
      local elem_schema = schema.list_member
      if not elem_schema then
         local fallback = { type = stype.STRING }
         elem_schema = fallback
      end
      local arr = v
      pos = pos + 1; buf[pos] = char(0x9F)
      for i = 1, #arr do
         pos = encode_value(arr[i], elem_schema, buf, pos)
      end
      pos = pos + 1; buf[pos] = BREAK
      return pos

   elseif st == stype.UNION then
      local members = schema:members()
      for k, ms in pairs(members) do
         if (v)[k] ~= nil then
            pos = pos + 1; buf[pos] = char(0xBF)
            pos = encode_text(k, buf, pos)
            pos = encode_value((v)[k], ms, buf, pos)
            pos = pos + 1; buf[pos] = BREAK
            return pos
         end
      end
      pos = pos + 1; buf[pos] = char(0xBF)
      pos = pos + 1; buf[pos] = BREAK
      return pos

   elseif st == stype.STRING or st == stype.ENUM then
      return encode_text(tostring(v), buf, pos)

   elseif st == stype.BOOLEAN then
      pos = pos + 1; buf[pos] = v and char(0xF5) or char(0xF4)
      return pos

   elseif st == stype.BLOB then
      return encode_bytes(v, buf, pos)

   elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE or
      st == stype.LONG or st == stype.INT_ENUM then
      return encode_int(v, buf, pos)

   elseif st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
      error("bigInteger/bigDecimal not supported in CBOR codec")

   elseif st == stype.FLOAT then
      local num = v
      if num ~= num then return encode_float32(num, buf, pos) end
      if num == huge or num == -huge then return encode_float32(num, buf, pos) end
      if num == floor(num) and num >= (-2) ^ 53 and num <= 2 ^ 53 then
         return encode_int(num, buf, pos)
      end
      return encode_float32(num, buf, pos)

   elseif st == stype.DOUBLE then
      local num = v
      if num ~= num then return encode_float64(num, buf, pos) end
      if num == huge or num == -huge then return encode_float64(num, buf, pos) end
      if num == floor(num) and num >= (-2) ^ 53 and num <= 2 ^ 53 then
         return encode_int(num, buf, pos)
      end
      return encode_float64(num, buf, pos)

   elseif st == stype.TIMESTAMP then
      local num = v
      pos = encode_uint(MT_TAG, 1, buf, pos)
      if num == floor(num) then
         return encode_int(num, buf, pos)
      else
         return encode_double(num, buf, pos)
      end

   else
      return encode_text(tostring(v), buf, pos)
   end
end

function M.serialize(_self, value, schema)
   local buf = {}
   local ok, pos_or_err = pcall(encode_value, value, schema, buf, 0)
   if not ok then
      return nil, { type = "sdk", message = "cbor serialize: " .. tostring(pos_or_err) }
   end
   return concat(buf, "", 1, pos_or_err), nil
end



local function read_uint(data, pos, info)
   if info < 24 then
      return info, pos
   elseif info == 24 then
      return byte(data, pos + 1), pos + 1
   elseif info == 25 then
      local b1, b2 = byte(data, pos + 1, pos + 2)
      return b1 * 256 + b2, pos + 2
   elseif info == 26 then
      local b1, b2, b3, b4 = byte(data, pos + 1, pos + 4)
      return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4, pos + 4
   elseif info == 27 then
      local b1, b2, b3, b4 = byte(data, pos + 1, pos + 4)
      local b5, b6, b7, b8 = byte(data, pos + 5, pos + 8)
      local hi = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
      local lo = b5 * 16777216 + b6 * 65536 + b7 * 256 + b8
      return hi * 4294967296 + lo, pos + 8
   end
   return error("cbor: invalid additional info " .. info)
end

local function decode_half(b1, b2)
   local sign = rshift(b1, 7)
   local exp = band(rshift(b1, 2), 0x1F)
   local mant = bor(lshift(band(b1, 0x03), 8), b2)
   if exp == 0 then
      local val = mant * (2 ^ (-24))
      return sign == 1 and -val or val
   elseif exp == 31 then
      if mant == 0 then
         return sign == 1 and -huge or huge
      else
         return 0 / 0
      end
   end
   local val = (1 + mant / 1024) * (2 ^ (exp - 15))
   return sign == 1 and -val or val
end

local f32_buf = ffi.new("uint8_t[4]")
local f32_ptr = ffi.cast("float*", f32_buf)

local function decode_float32(data, pos)
   ffi_set(f32_buf, 3, byte(data, pos + 1))
   ffi_set(f32_buf, 2, byte(data, pos + 2))
   ffi_set(f32_buf, 1, byte(data, pos + 3))
   ffi_set(f32_buf, 0, byte(data, pos + 4))
   return tonumber(ffi_get(f32_ptr, 0)), pos + 4
end

local d64_buf = ffi.new("uint8_t[8]")
local d64_ptr = ffi.cast("double*", d64_buf)

local function decode_float64(data, pos)
   ffi_set(d64_buf, 7, byte(data, pos + 1))
   ffi_set(d64_buf, 6, byte(data, pos + 2))
   ffi_set(d64_buf, 5, byte(data, pos + 3))
   ffi_set(d64_buf, 4, byte(data, pos + 4))
   ffi_set(d64_buf, 3, byte(data, pos + 5))
   ffi_set(d64_buf, 2, byte(data, pos + 6))
   ffi_set(d64_buf, 1, byte(data, pos + 7))
   ffi_set(d64_buf, 0, byte(data, pos + 8))
   return tonumber(ffi_get(d64_ptr, 0)), pos + 8
end

local function decode_item(data, pos)
   local b = byte(data, pos)
   local mt = rshift(b, 5)
   local info = band(b, 0x1F)

   if mt == MT_UINT then
      return read_uint(data, pos, info)

   elseif mt == MT_NEGINT then
      local n, npos = read_uint(data, pos, info)
      return -1 - n, npos

   elseif mt == MT_BYTES then
      if info == 31 then
         local chunks = {}
         local npos = pos
         while byte(data, npos + 1) ~= 0xFF do
            local chunk
            chunk, npos = decode_item(data, npos + 1)
            chunks[#chunks + 1] = chunk
         end
         return concat(chunks), npos + 1
      end
      local len
      local npos
      len, npos = read_uint(data, pos, info)
      return data:sub(npos + 1, npos + len), npos + len

   elseif mt == MT_TEXT then
      if info == 31 then
         local chunks = {}
         local npos = pos
         while byte(data, npos + 1) ~= 0xFF do
            local chunk
            chunk, npos = decode_item(data, npos + 1)
            chunks[#chunks + 1] = chunk
         end
         return concat(chunks), npos + 1
      end
      local len
      local npos
      len, npos = read_uint(data, pos, info)
      return data:sub(npos + 1, npos + len), npos + len

   elseif mt == MT_ARRAY then
      if info == 31 then
         local arr = {}
         local npos = pos
         while byte(data, npos + 1) ~= 0xFF do
            local item
            item, npos = decode_item(data, npos + 1)
            arr[#arr + 1] = item
         end
         return arr, npos + 1
      end
      local len
      local npos
      len, npos = read_uint(data, pos, info)
      local arr = {}
      for i = 1, len do
         arr[i], npos = decode_item(data, npos + 1)
      end
      return arr, npos

   elseif mt == MT_MAP then
      if info == 31 then
         local map = {}
         local npos = pos
         while byte(data, npos + 1) ~= 0xFF do
            local k
            local val
            k, npos = decode_item(data, npos + 1)
            val, npos = decode_item(data, npos + 1)
            map[k] = val
         end
         return map, npos + 1
      end
      local len
      local npos
      len, npos = read_uint(data, pos, info)
      local map = {}
      for _ = 1, len do
         local k
         local val
         k, npos = decode_item(data, npos + 1)
         val, npos = decode_item(data, npos + 1)
         map[k] = val
      end
      return map, npos

   elseif mt == MT_TAG then
      local tag
      local npos
      tag, npos = read_uint(data, pos, info)
      local val
      val, npos = decode_item(data, npos + 1)
      if tag == 1 then return val, npos end
      return val, npos

   elseif mt == MT_SIMPLE then
      if info == 20 then return false, pos end
      if info == 21 then return true, pos end
      if info == 22 then return nil, pos end
      if info == 23 then return nil, pos end
      if info == 25 then
         local b1, b2 = byte(data, pos + 1, pos + 2)
         return decode_half(b1, b2), pos + 2
      end
      if info == 26 then return decode_float32(data, pos) end
      if info == 27 then return decode_float64(data, pos) end
      return error("cbor: unsupported simple value " .. info)
   end

   return error("cbor: unsupported major type " .. mt)
end

local function decode_schema_value(raw, schema)
   if raw == nil then return nil end
   local st = schema.type

   if st == stype.STRUCTURE then
      if type(raw) ~= "table" then return raw end
      local members = schema:members()
      local result = {}
      for k, v in pairs(raw) do
         local ms = members[k]
         if ms then
            result[k] = decode_schema_value(v, ms)
         end
      end
      return result

   elseif st == stype.LIST then
      if type(raw) ~= "table" then return raw end
      local elem_schema = schema.list_member
      if not elem_schema then
         local fallback = { type = stype.STRING }
         elem_schema = fallback
      end
      local result = {}
      local arr = raw
      for i = 1, #arr do
         result[i] = decode_schema_value(arr[i], elem_schema)
      end
      return result

   elseif st == stype.MAP then
      if type(raw) ~= "table" then return raw end
      local val_schema = schema.map_value
      if not val_schema then
         local fallback = { type = stype.STRING }
         val_schema = fallback
      end
      local result = {}
      for k, v in pairs(raw) do
         result[tostring(k)] = decode_schema_value(v, val_schema)
      end
      return result

   elseif st == stype.UNION then
      if type(raw) ~= "table" then return raw end
      local members = schema:members()
      local result = {}
      for k, v in pairs(raw) do
         if k ~= "__type" then
            local ms = members[k]
            if ms then
               result[k] = decode_schema_value(v, ms)
               break
            end
         end
      end
      return result

   elseif st == stype.BOOLEAN then
      return raw and true or false

   elseif st == stype.STRING or st == stype.ENUM then
      return tostring(raw)

   elseif st == stype.BLOB then
      return raw

   elseif st == stype.INTEGER or st == stype.SHORT or st == stype.BYTE or
      st == stype.LONG or st == stype.INT_ENUM or
      st == stype.FLOAT or st == stype.DOUBLE then
      return tonumber(raw)

   elseif st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
      error("bigInteger/bigDecimal not supported in CBOR codec")

   elseif st == stype.TIMESTAMP then
      return tonumber(raw)

   else
      return raw
   end
end

function M.deserialize(_self, bytes, schema)
   if not bytes or #bytes == 0 then return {}, nil end
   local ok, raw, _ = pcall(decode_item, bytes, 1)
   if not ok then
      return nil, { type = "sdk", message = "cbor decode: " .. tostring(raw) }
   end
   if schema then
      local result = decode_schema_value(raw, schema)
      return result, nil
   end
   return raw, nil
end

M.decode_item = decode_item

return M
