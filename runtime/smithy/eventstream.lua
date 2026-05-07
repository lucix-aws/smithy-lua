

local bit = require("bit")
local ffi = require("ffi")
local traits = require("smithy.traits")

local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift
local strait = traits

local M = { Frame = {}, Stream = {}, SigningWriter = {} }
















































local crc_table = ffi.new("uint32_t[256]")
do
   for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
         if band(c, 1) == 1 then
            c = bxor(rshift(c, 1), 0xEDB88320)
         else
            c = rshift(c, 1)
         end
      end
      crc_table[i] = c
   end
end

local function crc32(data, offset, len, init)
   local crc = bxor(init or 0, 0xFFFFFFFF)
   for i = offset, offset + len - 1 do
      local b = (data)[i]
      crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, b), 0xFF)])
   end
   return tonumber(ffi.cast("uint32_t", bxor(crc, 0xFFFFFFFF)))
end

local function uint32_bytes(v)
   return string.char(
   band(rshift(v, 24), 0xFF),
   band(rshift(v, 16), 0xFF),
   band(rshift(v, 8), 0xFF),
   band(v, 0xFF))

end





local function read_u8(buf, pos)
   return (buf)[pos], pos + 1
end

local function read_u16(buf, pos)
   local b = buf
   return lshift(b[pos], 8) + b[pos + 1], pos + 2
end

local function read_u32(buf, pos)
   local b = buf
   local v = lshift(b[pos], 24) + lshift(b[pos + 1], 16) +
   lshift(b[pos + 2], 8) + b[pos + 3]
   return tonumber(ffi.cast("uint32_t", v)), pos + 4
end

local function read_u64(buf, pos)
   local b = buf
   local hi = lshift(b[pos], 24) + lshift(b[pos + 1], 16) +
   lshift(b[pos + 2], 8) + b[pos + 3]
   local lo = lshift(b[pos + 4], 24) + lshift(b[pos + 5], 16) +
   lshift(b[pos + 6], 8) + b[pos + 7]
   return tonumber(ffi.cast("uint32_t", hi)), tonumber(ffi.cast("uint32_t", lo)), pos + 8
end





local MIN_MESSAGE_LEN = 16

function M.decode_frame(data)
   if type(data) == "string" then
      local len = #data
      if len < MIN_MESSAGE_LEN then
         return nil, "frame too short"
      end
      local buf = ffi.new("uint8_t[?]", len)
      ffi.copy(buf, data, len)
      return M._decode_from_buf(buf, len)
   end
   return nil, "expected string data"
end

function M._decode_from_buf(buf, buf_len)
   local pos = 0

   local total_len
   local headers_len
   total_len, pos = read_u32(buf, pos)
   headers_len, pos = read_u32(buf, pos)

   if total_len > buf_len then
      return nil, "incomplete frame"
   end
   if total_len < MIN_MESSAGE_LEN then
      return nil, "invalid total length"
   end

   local prelude_crc_expected = crc32(buf, 0, 8)
   local prelude_crc_actual
   prelude_crc_actual, pos = read_u32(buf, pos)
   if prelude_crc_expected ~= prelude_crc_actual then
      return nil, "prelude CRC mismatch"
   end

   local headers = {}
   local headers_end = pos + headers_len
   while pos < headers_end do
      local name_len
      name_len, pos = read_u8(buf, pos)
      local name = ffi.string(buf + pos, name_len)
      pos = pos + name_len

      local vtype
      vtype, pos = read_u8(buf, pos)

      local value
      if vtype == 0 then
         value = true
      elseif vtype == 1 then
         value = false
      elseif vtype == 2 then
         value = (buf)[pos]
         pos = pos + 1
      elseif vtype == 3 then
         value, pos = read_u16(buf, pos)
      elseif vtype == 4 then
         value, pos = read_u32(buf, pos)
      elseif vtype == 5 then
         local hi
         local lo
         hi, lo, pos = read_u64(buf, pos)
         value = hi * 4294967296 + lo
      elseif vtype == 6 then
         local vlen
         vlen, pos = read_u16(buf, pos)
         value = ffi.string(buf + pos, vlen)
         pos = pos + vlen
      elseif vtype == 7 then
         local vlen
         vlen, pos = read_u16(buf, pos)
         value = ffi.string(buf + pos, vlen)
         pos = pos + vlen
      elseif vtype == 8 then
         local hi
         local lo
         hi, lo, pos = read_u64(buf, pos)
         value = (hi * 4294967296 + lo) / 1000
      elseif vtype == 9 then
         value = ffi.string(buf + pos, 16)
         pos = pos + 16
      else
         return nil, "unknown header value type: " .. tostring(vtype)
      end

      headers[name] = value
   end

   local payload_len = total_len - 12 - headers_len - 4
   local payload = ""
   if payload_len > 0 then
      payload = ffi.string(buf + pos, payload_len)
      pos = pos + payload_len
   end

   local msg_crc_expected = crc32(buf, 0, total_len - 4)
   local msg_crc_actual
   msg_crc_actual, pos = read_u32(buf, pos)
   if msg_crc_expected ~= msg_crc_actual then
      return nil, "message CRC mismatch"
   end

   local frame = { headers = headers, payload = payload }
   return frame, nil
end





function M.new_frame_reader(body_reader)
   local buffer = ""

   local function read_frame()
      while #buffer < 12 do
         local chunk = body_reader()
         if not chunk then
            if #buffer == 0 then return nil end
            return nil, "unexpected EOF in prelude"
         end
         buffer = buffer .. chunk
      end

      local b1, b2, b3, b4 = buffer:byte(1, 4)
      local total_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4

      while #buffer < total_len do
         local chunk = body_reader()
         if not chunk then
            return nil, "unexpected EOF in frame body"
         end
         buffer = buffer .. chunk
      end

      local frame_data = buffer:sub(1, total_len)
      buffer = buffer:sub(total_len + 1)

      return M.decode_frame(frame_data)
   end

   return read_frame
end





local function deserialize_event_struct(frame, member_schema, codec)
   local target = (member_schema)._target or member_schema
   local members_fn = (target).members
   local members = members_fn and members_fn(target)
   if not members then return {} end

   local result = {}

   local payload_member_name
   local payload_member_schema
   local body_members = {}

   for name, ms in pairs(members) do
      local trait_fn = (ms).trait
      if trait_fn(ms, strait.EVENT_HEADER) then
         local hval = frame.headers[name]
         if hval ~= nil then
            result[name] = hval
         end
      elseif trait_fn(ms, strait.EVENT_PAYLOAD) then
         payload_member_name = name
         payload_member_schema = ms
      else
         body_members[name] = ms
      end
   end

   if payload_member_name then
      local ptype = (payload_member_schema).type
      if ptype == "blob" then
         result[payload_member_name] = frame.payload
      elseif ptype == "string" then
         result[payload_member_name] = frame.payload
      else
         local deser_fn = (codec).deserialize
         local decoded, err = deser_fn(codec, frame.payload, payload_member_schema)
         if err then return nil, err end
         result[payload_member_name] = decoded
      end
   elseif #frame.payload > 0 and next(body_members) then
      local deser_fn = (codec).deserialize
      local decoded, err = deser_fn(codec, frame.payload, target)
      if err then return nil, err end
      for k, v in pairs(decoded) do
         result[k] = v
      end
   end

   return result
end

function M.deserialize_event(frame, event_schema, codec)
   local msg_type = frame.headers[":message-type"]
   if not msg_type then
      return nil, { type = "sdk", message = "missing :message-type header" }
   end

   if msg_type == "error" then
      local code = (frame.headers[":error-code"] or "UnknownError")
      local message = (frame.headers[":error-message"] or "")
      return nil, { type = "api", code = code, message = message }
   end

   if msg_type == "exception" then
      local exc_type = frame.headers[":exception-type"]
      if not exc_type then
         return nil, { type = "api", code = "UnknownError", message = "missing :exception-type" }
      end
      local members_fn = (event_schema).members
      local es_members = members_fn and members_fn(event_schema) or (event_schema)._members
      local member_schema = es_members and es_members[exc_type]
      if not member_schema then
         return nil, { type = "api", code = exc_type, message = "unknown exception type" }
      end
      local data, err = deserialize_event_struct(frame, member_schema, codec)
      if err then return nil, err end
      local dmap = data
      return nil, {
         type = "api",
         code = exc_type,
         message = dmap.message or dmap.Message or "",
      }
   end

   if msg_type == "event" then
      local event_type = frame.headers[":event-type"]
      if not event_type then
         return nil, { type = "sdk", message = "missing :event-type header" }
      end

      if event_type == "initial-response" then
         return { _initial_response = true, _payload = frame.payload }, nil
      end

      local members_fn = (event_schema).members
      local es_members = members_fn and members_fn(event_schema) or (event_schema)._members
      local member_schema = es_members and es_members[event_type]
      if not member_schema then
         return nil, nil
      end

      local data, err = deserialize_event_struct(frame, member_schema, codec)
      if err then return nil, err end
      return { [event_type] = data }, nil
   end

   return nil, nil
end





local function write_u8_str(v)
   return string.char(band(v, 0xFF))
end

local function write_u16_str(v)
   return string.char(band(rshift(v, 8), 0xFF), band(v, 0xFF))
end

local function write_u32_str(v)
   return string.char(
   band(rshift(v, 24), 0xFF),
   band(rshift(v, 16), 0xFF),
   band(rshift(v, 8), 0xFF),
   band(v, 0xFF))

end





local function encode_header(name, value)
   local parts = { write_u8_str(#name), name }
   local vtype = type(value)
   if vtype == "boolean" then
      parts[#parts + 1] = write_u8_str((value) and 0 or 1)
   elseif vtype == "number" then
      parts[#parts + 1] = write_u8_str(4)
      parts[#parts + 1] = write_u32_str(value)
   elseif vtype == "string" then
      parts[#parts + 1] = write_u8_str(7)
      parts[#parts + 1] = write_u16_str(#(value))
      parts[#parts + 1] = value
   else
      error("unsupported header value type: " .. vtype)
   end
   return table.concat(parts)
end

function M.encode_bytes_header(name, value)
   local parts = { write_u8_str(#name), name }
   parts[#parts + 1] = write_u8_str(6)
   parts[#parts + 1] = write_u16_str(#value)
   parts[#parts + 1] = value
   return table.concat(parts)
end

function M.encode_timestamp_header(name, epoch_ms)
   local parts = { write_u8_str(#name), name }
   parts[#parts + 1] = write_u8_str(8)
   local hi = math.floor(epoch_ms / 4294967296)
   local lo = epoch_ms - hi * 4294967296
   parts[#parts + 1] = write_u32_str(hi)
   parts[#parts + 1] = write_u32_str(lo)
   return table.concat(parts)
end

function M.encode_headers(headers)
   local parts = {}
   for name, value in pairs(headers) do
      parts[#parts + 1] = encode_header(name, value)
   end
   return table.concat(parts)
end





local function crc32_string(s, init)
   local len = #s
   local buf = ffi.new("uint8_t[?]", len)
   ffi.copy(buf, s, len)
   return crc32(buf, 0, len, init)
end

function M.encode_frame(headers_bytes, payload)
   payload = payload or ""
   local headers_len = #headers_bytes
   local total_len = 12 + headers_len + #payload + 4

   local prelude = write_u32_str(total_len) .. write_u32_str(headers_len)
   local prelude_crc = crc32_string(prelude)

   local msg = prelude .. write_u32_str(prelude_crc) .. headers_bytes .. payload

   local msg_crc = crc32_string(msg)

   return msg .. write_u32_str(msg_crc)
end





function M.serialize_event(event, event_schema, codec)
   local event_type
   local event_data
   for k, v in pairs(event) do
      event_type = k
      event_data = v
      break
   end
   if not event_type then
      return nil, "empty event"
   end

   local members_fn = (event_schema).members
   local es_members = members_fn and members_fn(event_schema) or (event_schema)._members
   local member_schema = es_members and es_members[event_type]
   if not member_schema then
      return nil, "unknown event type: " .. event_type
   end

   local target = (member_schema)._target or member_schema
   local target_members_fn = (target).members
   local members = target_members_fn and target_members_fn(target)

   local header_parts = {}
   header_parts[#header_parts + 1] = encode_header(":message-type", "event")
   header_parts[#header_parts + 1] = encode_header(":event-type", event_type)

   local payload = ""
   if members then
      local payload_member_name
      local payload_member_schema
      local body_members = {}

      for name, ms in pairs(members) do
         local trait_fn = (ms).trait
         if trait_fn(ms, strait.EVENT_HEADER) then
            if (event_data)[name] ~= nil then
               header_parts[#header_parts + 1] = encode_header(name, (event_data)[name])
            end
         elseif trait_fn(ms, strait.EVENT_PAYLOAD) then
            payload_member_name = name
            payload_member_schema = ms
         else
            body_members[name] = ms
         end
      end

      if payload_member_name and (event_data)[payload_member_name] ~= nil then
         local ptype = (payload_member_schema).type
         if ptype == "blob" or ptype == "string" then
            payload = (event_data)[payload_member_name]
            if ptype == "blob" then
               header_parts[#header_parts + 1] = encode_header(":content-type", "application/octet-stream")
            else
               header_parts[#header_parts + 1] = encode_header(":content-type", "text/plain")
            end
         else
            local ser_fn = (codec).serialize_value
            payload = ser_fn(codec, (event_data)[payload_member_name], payload_member_schema)
            local ct = (codec).content_type or "application/json"
            header_parts[#header_parts + 1] = encode_header(":content-type", ct)
         end
      elseif next(body_members) then
         local ser_fn = (codec).serialize_value
         payload = ser_fn(codec, event_data, target)
         local ct = (codec).content_type or "application/json"
         header_parts[#header_parts + 1] = encode_header(":content-type", ct)
      end
   end

   local headers_bytes = table.concat(header_parts)
   return M.encode_frame(headers_bytes, payload)
end





local SigningWriter_mt = { __index = M.SigningWriter }

function M.new_signing_writer(signer)
   local sw = setmetatable({
      _signer = signer,
      _queue = {},
      _closed = false,
   }, SigningWriter_mt)

   sw.body_reader = function()
      if #sw._queue > 0 then
         local frame = table.remove(sw._queue, 1)
         return frame
      end
      if sw._closed then return nil end
      return nil
   end

   return sw
end

function M.SigningWriter:write(inner_frame)
   if self._closed then return nil, "writer closed" end

   local now = os.time()
   local epoch_ms = now * 1000

   local date_header = M.encode_timestamp_header(":date", epoch_ms)

   local sign_fn = (self._signer).sign
   local sig = sign_fn(self._signer, date_header, inner_frame, now)

   local headers_bytes = date_header .. M.encode_bytes_header(":chunk-signature", sig)
   local envelope = M.encode_frame(headers_bytes, inner_frame)

   self._queue[#self._queue + 1] = envelope
   return true
end

function M.SigningWriter:close()
   if self._closed then return end

   local now = os.time()
   local epoch_ms = now * 1000
   local date_header = M.encode_timestamp_header(":date", epoch_ms)

   local sign_fn = (self._signer).sign
   local sig = sign_fn(self._signer, date_header, "", now)
   local headers_bytes = date_header .. M.encode_bytes_header(":chunk-signature", sig)
   local envelope = M.encode_frame(headers_bytes, "")

   self._queue[#self._queue + 1] = envelope
   self._closed = true
end





local Stream_mt = { __index = M.Stream }

function M.new_stream(body_reader, event_schema, codec, opts)
   opts = opts or {}
   local stream = setmetatable({
      _read_frame = M.new_frame_reader(body_reader),
      _event_schema = event_schema,
      _codec = codec,
      _closed = false,
      _has_initial_message = (opts.has_initial_message or false),
      _output_schema = opts.output_schema,
      _on_close = opts.on_close,
      initial_response = nil,
   }, Stream_mt)

   if stream._has_initial_message then
      local err = stream:_read_initial_response()
      if err then
         stream._error = err
      end
   end

   return stream
end

function M.Stream:_read_initial_response()
   local frame, err = self._read_frame()
   if err then return err end
   if not frame then return { type = "sdk", message = "expected initial-response, got EOF" } end

   local event_type = frame.headers[":event-type"]
   if event_type ~= "initial-response" then
      return { type = "sdk", message = "expected initial-response, got: " .. tostring(event_type) }
   end

   if self._output_schema and #frame.payload > 0 then
      local deser_fn = (self._codec).deserialize
      local decoded, derr = deser_fn(self._codec, frame.payload, self._output_schema)
      if derr then return derr end
      self.initial_response = decoded
   else
      self.initial_response = {}
   end
   return nil
end

function M.Stream:events()
   return function()
      if self._closed then return nil end
      if self._error then
         local e = self._error
         self._error = nil
         return nil, e
      end

      while true do
         local frame, err = self._read_frame()
         if err then return nil, err end
         if not frame then
            self._closed = true
            return nil
         end

         local event, eerr = M.deserialize_event(frame, self._event_schema, self._codec)
         if eerr then return nil, eerr end
         if event then return event end
      end
   end
end

function M.Stream:close()
   if self._closed then return end
   self._closed = true
   if self._on_close then self._on_close() end
end

return M
