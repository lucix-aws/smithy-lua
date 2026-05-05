

local M = {}









local concat = table.concat
local format = string.format
local huge = math.huge

local escape_map = {
   ['"'] = '\\"',
   ['\\'] = '\\\\',
   ['\b'] = '\\b',
   ['\f'] = '\\f',
   ['\n'] = '\\n',
   ['\r'] = '\\r',
   ['\t'] = '\\t',
}

for i = 0, 31 do
   local c = string.char(i)
   if not escape_map[c] then
      escape_map[c] = format("\\u%04x", i)
   end
end

local function encode_string(s, buf, n)
   n = n + 1; buf[n] = '"'
   n = n + 1; buf[n] = s:gsub('[%z\1-\31"\\]', escape_map)
   n = n + 1; buf[n] = '"'
   return n
end

local encode_value

local function encode_array(t, buf, n)
   n = n + 1; buf[n] = "["
   for i = 1, #t do
      if i > 1 then n = n + 1; buf[n] = "," end
      n = encode_value(t[i], buf, n)
   end
   n = n + 1; buf[n] = "]"
   return n
end

local function encode_object(t, keys, buf, n)
   n = n + 1; buf[n] = "{"
   local first = true
   for i = 1, #keys do
      local k = keys[i]
      local v = t[k]
      if v ~= nil then
         if not first then n = n + 1; buf[n] = "," end
         first = false
         n = encode_string(k, buf, n)
         n = n + 1; buf[n] = ":"
         n = encode_value(v, buf, n)
      end
   end
   n = n + 1; buf[n] = "}"
   return n
end

local function encode_table(t, buf, n)
   if t[1] ~= nil or next(t) == nil then
      return encode_array(t, buf, n)
   end
   local keys = {}
   for k in pairs(t) do
      keys[#keys + 1] = k
   end
   table.sort(keys)
   return encode_object(t, keys, buf, n)
end

encode_value = function(v, buf, n)
   local vtype = type(v)
   if vtype == "string" then
      return encode_string(v, buf, n)
   elseif vtype == "number" then
      local num = v
      if num ~= num then
         n = n + 1; buf[n] = '"NaN"'
      elseif num == huge then
         n = n + 1; buf[n] = '"Infinity"'
      elseif num == -huge then
         n = n + 1; buf[n] = '"-Infinity"'
      elseif num % 1 == 0 and num >= (-2) ^ 53 and num <= 2 ^ 53 then
         n = n + 1; buf[n] = format("%.0f", num)
      else
         n = n + 1; buf[n] = format("%.17g", num)
      end
      return n
   elseif vtype == "boolean" then
      n = n + 1; buf[n] = (v) and "true" or "false"
      return n
   elseif vtype == "table" then
      return encode_table(v, buf, n)
   elseif v == nil then
      n = n + 1; buf[n] = "null"
      return n
   else
      error("cannot encode type: " .. vtype)
   end
end

function M.encode(v)
   local buf = {}
   local n = encode_value(v, buf, 0)
   return concat(buf, "", 1, n)
end

M.encode_string = function(s)
   local buf = {}
   local n = encode_string(s, buf, 0)
   return concat(buf, "", 1, n)
end

function M.encode_object(t, keys)
   local buf = {}
   local n = encode_object(t, keys, buf, 0)
   return concat(buf, "", 1, n)
end

M._encode_value = encode_value
M._encode_string = encode_string
M._encode_array = encode_array
M._encode_object = encode_object

return M
