-- smithy-lua runtime: event stream binary frame decoding and deserialization.
-- Implements the application/vnd.amazon.eventstream wire format shared by all
-- AWS protocols. This module is protocol-agnostic; protocols compose it.

local bit = require("bit")
local ffi = require("ffi")
local traits = require("smithy.traits")

local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift
local strait = traits

local M = {}

----------------------------------------------------------------------------
-- CRC-32C (Castagnoli) - used by the event stream binary framing.
-- Note: AWS event stream uses CRC-32 IEEE (standard), NOT CRC-32C.
-- The polynomial is 0xEDB88320 (reflected IEEE).
----------------------------------------------------------------------------

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
        local b = data[i]
        crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, b), 0xFF)])
    end
    return tonumber(ffi.cast("uint32_t", bxor(crc, 0xFFFFFFFF)))
end

-- Convert a uint32 to 4 bytes (big-endian) for CRC computation
local function uint32_bytes(v)
    return string.char(
        band(rshift(v, 24), 0xFF),
        band(rshift(v, 16), 0xFF),
        band(rshift(v, 8), 0xFF),
        band(v, 0xFF)
    )
end

----------------------------------------------------------------------------
-- Binary reading helpers
----------------------------------------------------------------------------

local function read_u8(buf, pos)
    return buf[pos], pos + 1
end

local function read_u16(buf, pos)
    return lshift(buf[pos], 8) + buf[pos + 1], pos + 2
end

local function read_u32(buf, pos)
    -- Use tonumber to avoid issues with sign extension in LuaJIT
    local v = lshift(buf[pos], 24) + lshift(buf[pos + 1], 16) +
              lshift(buf[pos + 2], 8) + buf[pos + 3]
    return tonumber(ffi.cast("uint32_t", v)), pos + 4
end

local function read_u64(buf, pos)
    -- Return as two 32-bit halves (hi, lo) since Lua numbers lose precision
    local hi = lshift(buf[pos], 24) + lshift(buf[pos + 1], 16) +
               lshift(buf[pos + 2], 8) + buf[pos + 3]
    local lo = lshift(buf[pos + 4], 24) + lshift(buf[pos + 5], 16) +
               lshift(buf[pos + 6], 8) + buf[pos + 7]
    return tonumber(ffi.cast("uint32_t", hi)), tonumber(ffi.cast("uint32_t", lo)), pos + 8
end

----------------------------------------------------------------------------
-- Frame decoding
----------------------------------------------------------------------------

-- Minimum message: 4 (total_len) + 4 (headers_len) + 4 (prelude_crc) + 4 (msg_crc) = 16
local MIN_MESSAGE_LEN = 16

--- Decode a single event stream frame from a byte string.
--- Returns: frame table {headers={}, payload=string}, or nil + error
function M.decode_frame(data)
    if type(data) == "string" then
        -- Convert string to byte array for uniform access
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

    -- Prelude: total_length(4) + headers_length(4)
    local total_len, headers_len
    total_len, pos = read_u32(buf, pos)
    headers_len, pos = read_u32(buf, pos)

    if total_len > buf_len then
        return nil, "incomplete frame"
    end
    if total_len < MIN_MESSAGE_LEN then
        return nil, "invalid total length"
    end

    -- Verify prelude CRC (covers first 8 bytes)
    local prelude_crc_expected = crc32(buf, 0, 8)
    local prelude_crc_actual
    prelude_crc_actual, pos = read_u32(buf, pos)
    if prelude_crc_expected ~= prelude_crc_actual then
        return nil, "prelude CRC mismatch"
    end

    -- Decode headers
    local headers = {}
    local headers_end = pos + headers_len
    while pos < headers_end do
        -- Header name: 1 byte length + name bytes
        local name_len
        name_len, pos = read_u8(buf, pos)
        local name = ffi.string(buf + pos, name_len)
        pos = pos + name_len

        -- Header value: 1 byte type + value
        local vtype
        vtype, pos = read_u8(buf, pos)

        local value
        if vtype == 0 then -- true
            value = true
        elseif vtype == 1 then -- false
            value = false
        elseif vtype == 2 then -- int8
            value = buf[pos]; pos = pos + 1
        elseif vtype == 3 then -- int16
            value, pos = read_u16(buf, pos)
        elseif vtype == 4 then -- int32
            value, pos = read_u32(buf, pos)
        elseif vtype == 5 then -- int64
            local hi, lo
            hi, lo, pos = read_u64(buf, pos)
            value = hi * 4294967296 + lo
        elseif vtype == 6 then -- bytes
            local vlen
            vlen, pos = read_u16(buf, pos)
            value = ffi.string(buf + pos, vlen)
            pos = pos + vlen
        elseif vtype == 7 then -- string
            local vlen
            vlen, pos = read_u16(buf, pos)
            value = ffi.string(buf + pos, vlen)
            pos = pos + vlen
        elseif vtype == 8 then -- timestamp (epoch millis as int64)
            local hi, lo
            hi, lo, pos = read_u64(buf, pos)
            value = (hi * 4294967296 + lo) / 1000
        elseif vtype == 9 then -- uuid (16 bytes)
            value = ffi.string(buf + pos, 16)
            pos = pos + 16
        else
            return nil, "unknown header value type: " .. vtype
        end

        headers[name] = value
    end

    -- Payload: total_len - 12 (prelude) - headers_len - 4 (msg_crc)
    local payload_len = total_len - 12 - headers_len - 4
    local payload = ""
    if payload_len > 0 then
        payload = ffi.string(buf + pos, payload_len)
        pos = pos + payload_len
    end

    -- Verify message CRC (covers everything except the last 4 bytes)
    local msg_crc_expected = crc32(buf, 0, total_len - 4)
    local msg_crc_actual
    msg_crc_actual, pos = read_u32(buf, pos)
    if msg_crc_expected ~= msg_crc_actual then
        return nil, "message CRC mismatch"
    end

    return { headers = headers, payload = payload }, nil
end

----------------------------------------------------------------------------
-- Reading frames from a reader (chunked byte stream)
----------------------------------------------------------------------------

--- Create a frame reader that reads frames from a body reader function.
--- The reader function returns chunks (strings) or nil on EOF.
function M.new_frame_reader(body_reader)
    local buffer = ""

    local function read_frame()
        -- Accumulate until we have at least the prelude (12 bytes)
        while #buffer < 12 do
            local chunk = body_reader()
            if not chunk then
                if #buffer == 0 then return nil end -- clean EOF
                return nil, "unexpected EOF in prelude"
            end
            buffer = buffer .. chunk
        end

        -- Read total_length from first 4 bytes
        local b1, b2, b3, b4 = buffer:byte(1, 4)
        local total_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4

        -- Accumulate until we have the full message
        while #buffer < total_len do
            local chunk = body_reader()
            if not chunk then
                return nil, "unexpected EOF in frame body"
            end
            buffer = buffer .. chunk
        end

        -- Extract this frame and advance buffer
        local frame_data = buffer:sub(1, total_len)
        buffer = buffer:sub(total_len + 1)

        return M.decode_frame(frame_data)
    end

    return read_frame
end

----------------------------------------------------------------------------
-- Event deserialization
----------------------------------------------------------------------------

--- Deserialize an event's payload members using the protocol codec, respecting
--- @eventHeader and @eventPayload bindings.
local function deserialize_event_struct(frame, member_schema, codec)
    local target = member_schema._target or member_schema
    local members = target:members()
    if not members then return {} end

    local result = {}

    -- Separate header-bound, payload-bound, and body members
    local payload_member_name, payload_member_schema
    local body_members = {}

    for name, ms in pairs(members) do
        if ms:trait(strait.EVENT_HEADER) then
            -- Read from frame headers
            local hval = frame.headers[name]
            if hval ~= nil then
                result[name] = hval
            end
        elseif ms:trait(strait.EVENT_PAYLOAD) then
            payload_member_name = name
            payload_member_schema = ms
        else
            body_members[name] = ms
        end
    end

    -- If there's an explicit @eventPayload member, the entire payload is that member
    if payload_member_name then
        local ptype = payload_member_schema.type
        if ptype == "blob" then
            result[payload_member_name] = frame.payload
        elseif ptype == "string" then
            result[payload_member_name] = frame.payload
        else
            -- Structure payload: deserialize with codec
            local decoded, err = codec:deserialize(frame.payload, payload_member_schema)
            if err then return nil, err end
            result[payload_member_name] = decoded
        end
    elseif #frame.payload > 0 and next(body_members) then
        -- Implicit payload: all non-header members form the body, deserialize as structure
        local decoded, err = codec:deserialize(frame.payload, target)
        if err then return nil, err end
        -- Merge decoded body into result (which may already have header values)
        for k, v in pairs(decoded) do
            result[k] = v
        end
    end

    return result
end

--- Deserialize a single event frame into a typed event table.
--- Returns: { [member_name] = event_data } (union-like), or nil + error
--- For error events, returns nil + error table.
function M.deserialize_event(frame, event_schema, codec)
    local msg_type = frame.headers[":message-type"]
    if not msg_type then
        return nil, { type = "sdk", message = "missing :message-type header" }
    end

    if msg_type == "error" then
        -- Unmodeled error: terminal
        local code = frame.headers[":error-code"] or "UnknownError"
        local message = frame.headers[":error-message"] or ""
        return nil, { type = "api", code = code, message = message }
    end

    if msg_type == "exception" then
        -- Modeled error event
        local exc_type = frame.headers[":exception-type"]
        if not exc_type then
            return nil, { type = "api", code = "UnknownError", message = "missing :exception-type" }
        end
        local es_members = event_schema:members() or (event_schema._members)
        local member_schema = es_members and es_members[exc_type]
        if not member_schema then
            return nil, { type = "api", code = exc_type, message = "unknown exception type" }
        end
        local data, err = deserialize_event_struct(frame, member_schema, codec)
        if err then return nil, err end
        return nil, {
            type = "api",
            code = exc_type,
            message = data.message or data.Message or "",
        }
    end

    if msg_type == "event" then
        local event_type = frame.headers[":event-type"]
        if not event_type then
            return nil, { type = "sdk", message = "missing :event-type header" }
        end

        -- initial-response is a special event in RPC protocols
        if event_type == "initial-response" then
            return { _initial_response = true, _payload = frame.payload }, nil
        end

        local es_members = event_schema:members() or (event_schema._members)
        local member_schema = es_members and es_members[event_type]
        if not member_schema then
            -- Unknown event type: skip (backwards compatible)
            return nil, nil
        end

        local data, err = deserialize_event_struct(frame, member_schema, codec)
        if err then return nil, err end
        return { [event_type] = data }, nil
    end

    -- Unknown message type: skip
    return nil, nil
end

----------------------------------------------------------------------------
-- Binary writing helpers
----------------------------------------------------------------------------

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
        band(v, 0xFF)
    )
end

----------------------------------------------------------------------------
-- Header encoding
----------------------------------------------------------------------------

--- Encode a single header name+value into binary.
local function encode_header(name, value)
    local parts = { write_u8_str(#name), name }
    local vtype = type(value)
    if vtype == "boolean" then
        parts[#parts + 1] = write_u8_str(value and 0 or 1)
    elseif vtype == "number" then
        -- Encode as int32
        parts[#parts + 1] = write_u8_str(4)
        parts[#parts + 1] = write_u32_str(value)
    elseif vtype == "string" then
        parts[#parts + 1] = write_u8_str(7) -- string type
        parts[#parts + 1] = write_u16_str(#value)
        parts[#parts + 1] = value
    else
        error("unsupported header value type: " .. vtype)
    end
    return table.concat(parts)
end

--- Encode a header with explicit type 6 (bytes).
function M.encode_bytes_header(name, value)
    local parts = { write_u8_str(#name), name }
    parts[#parts + 1] = write_u8_str(6) -- bytes type
    parts[#parts + 1] = write_u16_str(#value)
    parts[#parts + 1] = value
    return table.concat(parts)
end

--- Encode a header with explicit type 8 (timestamp, epoch millis as int64).
function M.encode_timestamp_header(name, epoch_ms)
    local parts = { write_u8_str(#name), name }
    parts[#parts + 1] = write_u8_str(8)
    -- Encode as 8 bytes big-endian
    local hi = math.floor(epoch_ms / 4294967296)
    local lo = epoch_ms - hi * 4294967296
    parts[#parts + 1] = write_u32_str(hi)
    parts[#parts + 1] = write_u32_str(lo)
    return table.concat(parts)
end

--- Encode headers table into binary. Returns concatenated header bytes.
function M.encode_headers(headers)
    local parts = {}
    for name, value in pairs(headers) do
        parts[#parts + 1] = encode_header(name, value)
    end
    return table.concat(parts)
end

----------------------------------------------------------------------------
-- Frame encoding
----------------------------------------------------------------------------

-- CRC over a string
local function crc32_string(s, init)
    local len = #s
    local buf = ffi.new("uint8_t[?]", len)
    ffi.copy(buf, s, len)
    return crc32(buf, 0, len, init)
end

--- Encode a frame (headers_bytes string + payload string) into a complete
--- event stream message binary string.
function M.encode_frame(headers_bytes, payload)
    payload = payload or ""
    local headers_len = #headers_bytes
    local total_len = 12 + headers_len + #payload + 4 -- prelude(12) + headers + payload + msg_crc

    -- Prelude: total_length(4) + headers_length(4)
    local prelude = write_u32_str(total_len) .. write_u32_str(headers_len)
    local prelude_crc = crc32_string(prelude)

    -- Message without final CRC
    local msg = prelude .. write_u32_str(prelude_crc) .. headers_bytes .. payload

    -- Message CRC over everything
    local msg_crc = crc32_string(msg)

    return msg .. write_u32_str(msg_crc)
end

----------------------------------------------------------------------------
-- Event serialization (input direction)
----------------------------------------------------------------------------

--- Serialize an event table into a binary event stream frame.
--- @param event table: union-like table, e.g. { AudioEvent = { AudioChunk = "..." } }
--- @param event_schema table: the streaming union schema (with members)
--- @param codec table: protocol codec for payload serialization
--- @return string: encoded frame bytes, or nil + error
function M.serialize_event(event, event_schema, codec)
    -- Find the single set member (union semantics)
    local event_type, event_data
    for k, v in pairs(event) do
        event_type = k
        event_data = v
        break
    end
    if not event_type then
        return nil, "empty event"
    end

    local es_members = event_schema:members() or (event_schema._members)
    local member_schema = es_members and es_members[event_type]
    if not member_schema then
        return nil, "unknown event type: " .. event_type
    end

    local target = member_schema._target or member_schema
    local members = target:members()

    -- Build headers and payload
    local header_parts = {}
    -- Protocol headers
    header_parts[#header_parts + 1] = encode_header(":message-type", "event")
    header_parts[#header_parts + 1] = encode_header(":event-type", event_type)

    local payload = ""
    if members then
        local payload_member_name, payload_member_schema
        local body_members = {}

        for name, ms in pairs(members) do
            if ms:trait(strait.EVENT_HEADER) then
                -- Serialize to event header
                if event_data[name] ~= nil then
                    header_parts[#header_parts + 1] = encode_header(name, event_data[name])
                end
            elseif ms:trait(strait.EVENT_PAYLOAD) then
                payload_member_name = name
                payload_member_schema = ms
            else
                body_members[name] = ms
            end
        end

        if payload_member_name and event_data[payload_member_name] ~= nil then
            local ptype = payload_member_schema.type
            if ptype == "blob" or ptype == "string" then
                payload = event_data[payload_member_name]
                if ptype == "blob" then
                    header_parts[#header_parts + 1] = encode_header(":content-type", "application/octet-stream")
                else
                    header_parts[#header_parts + 1] = encode_header(":content-type", "text/plain")
                end
            else
                -- Structure payload: serialize with codec
                payload = codec:serialize_value(event_data[payload_member_name], payload_member_schema)
                header_parts[#header_parts + 1] = encode_header(":content-type", codec.content_type or "application/json")
            end
        elseif next(body_members) then
            -- Implicit payload: serialize all non-header members as structure
            payload = codec:serialize_value(event_data, target)
            header_parts[#header_parts + 1] = encode_header(":content-type", codec.content_type or "application/json")
        end
    end

    local headers_bytes = table.concat(header_parts)
    return M.encode_frame(headers_bytes, payload)
end

----------------------------------------------------------------------------
-- SigningWriter: signs event frames and provides a streaming body reader
----------------------------------------------------------------------------

local SigningWriter = {}
SigningWriter.__index = SigningWriter

--- Create a new SigningWriter.
--- @param signer table: event stream signer with :sign(headers_bytes, payload)
--- @return table: writer with :write(frame), :close(), and .body_reader
function M.new_signing_writer(signer)
    local sw = setmetatable({
        _signer = signer,
        _queue = {},   -- queue of signed envelope frame strings
        _closed = false,
    }, SigningWriter)

    -- Body reader function for the HTTP client to pull from
    sw.body_reader = function()
        -- Return queued frames
        if #sw._queue > 0 then
            local frame = table.remove(sw._queue, 1)
            return frame
        end
        -- EOF
        if sw._closed then return nil end
        -- No data yet (caller must write before reader pulls)
        return nil
    end

    return sw
end

--- Write an already-encoded inner event frame. Signs it and enqueues the
--- outer envelope frame.
function SigningWriter:write(inner_frame)
    if self._closed then return nil, "writer closed" end

    local now = os.time()
    local epoch_ms = now * 1000

    -- Build the :date header for signing
    local date_header = M.encode_timestamp_header(":date", epoch_ms)

    -- Sign: the signer sees the :date header bytes and the inner frame as payload
    local sig = self._signer:sign(date_header, inner_frame, now)

    -- Build outer envelope: :date + :chunk-signature headers, inner frame as payload
    local headers_bytes = date_header .. M.encode_bytes_header(":chunk-signature", sig)
    local envelope = M.encode_frame(headers_bytes, inner_frame)

    self._queue[#self._queue + 1] = envelope
    return true
end

--- Close the writer: send a signed empty message to signal end-of-stream.
function SigningWriter:close()
    if self._closed then return end

    local now = os.time()
    local epoch_ms = now * 1000
    local date_header = M.encode_timestamp_header(":date", epoch_ms)

    -- Sign empty payload
    local sig = self._signer:sign(date_header, "", now)
    local headers_bytes = date_header .. M.encode_bytes_header(":chunk-signature", sig)
    local envelope = M.encode_frame(headers_bytes, "")

    self._queue[#self._queue + 1] = envelope
    self._closed = true
end

----------------------------------------------------------------------------
-- Stream object
----------------------------------------------------------------------------

local Stream = {}
Stream.__index = Stream

--- Create a new event stream reader.
--- @param body_reader function: reader that returns chunks
--- @param event_schema table: the streaming union schema
--- @param codec table: protocol codec for payload deserialization
--- @param opts table|nil: { has_initial_message = bool, output_schema = table }
--- @return table: stream object with :events() and :close()
function M.new_stream(body_reader, event_schema, codec, opts)
    opts = opts or {}
    local stream = setmetatable({
        _read_frame = M.new_frame_reader(body_reader),
        _event_schema = event_schema,
        _codec = codec,
        _closed = false,
        _has_initial_message = opts.has_initial_message or false,
        _output_schema = opts.output_schema,
        _on_close = opts.on_close,
        initial_response = nil,
    }, Stream)

    -- For RPC protocols, read the initial-response event
    if stream._has_initial_message then
        local err = stream:_read_initial_response()
        if err then
            stream._error = err
        end
    end

    return stream
end

function Stream:_read_initial_response()
    local frame, err = self._read_frame()
    if err then return err end
    if not frame then return { type = "sdk", message = "expected initial-response, got EOF" } end

    local event_type = frame.headers[":event-type"]
    if event_type ~= "initial-response" then
        return { type = "sdk", message = "expected initial-response, got: " .. tostring(event_type) }
    end

    -- Deserialize the initial response payload using the output schema
    if self._output_schema and #frame.payload > 0 then
        local decoded, derr = self._codec:deserialize(frame.payload, self._output_schema)
        if derr then return derr end
        self.initial_response = decoded
    else
        self.initial_response = {}
    end
    return nil
end

--- Returns an iterator function that yields (event, err) pairs.
--- Each event is a table like { memberName = { ...fields... } }.
--- Returns nil when the stream ends. Returns nil, err on error.
function Stream:events()
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
            -- event may be nil for unknown/skipped events, keep reading
            if event then return event end
        end
    end
end

--- Close the stream.
function Stream:close()
    if self._closed then return end
    self._closed = true
    if self._on_close then self._on_close() end
end

return M
