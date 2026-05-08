-- smithy-lua runtime: event stream binary frame decoding and deserialization.

local bit = require("bit")
local ffi = require("ffi")
local traits = require("smithy.traits")

local band, bxor, rshift, lshift = bit.band, bit.bxor, bit.rshift, bit.lshift
local strait = traits

local record M
    record Frame
        headers: {string:any}
        payload: string
    end

    record Stream
        initial_response: any
        _read_frame: function(): Frame, string
        _event_schema: any
        _codec: any
        _closed: boolean
        _has_initial_message: boolean
        _output_schema: any
        _on_close: function()
        _error: any

        events: function(Stream): function(): any, any
        close: function(Stream)
        _read_initial_response: function(Stream): any
    end

    record SigningWriter
        _signer: any
        _queue: {string}
        _closed: boolean
        body_reader: function(): string

        write: function(SigningWriter, string): boolean, string
        close: function(SigningWriter)
    end

    decode_frame: function(data: string): Frame, string
    _decode_from_buf: function(buf: ffi.CData, buf_len: number): Frame, string
    new_frame_reader: function(body_reader: function(): string): function(): Frame, string
    deserialize_event: function(frame: Frame, event_schema: any, codec: any): any, any
    encode_headers: function(headers: {string:any}): string
    encode_bytes_header: function(name: string, value: string): string
    encode_timestamp_header: function(name: string, epoch_ms: number): string
    encode_frame: function(headers_bytes: string, payload: string): string
    serialize_event: function(event: any, event_schema: any, codec: any): string, string
    new_signing_writer: function(signer: any): SigningWriter
    new_stream: function(body_reader: function(): string, event_schema: any, codec: any, opts: {string:any}): Stream
end

----------------------------------------------------------------------------
-- CRC-32 (IEEE)
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

local function crc32(data: any, offset: number, len: number, init?: number): number
    local crc = bxor(init or 0, 0xFFFFFFFF)
    for i = offset, offset + len - 1 do
        local b = (data as {number:number})[i]
        crc = bxor(rshift(crc, 8), crc_table[band(bxor(crc, b), 0xFF)] as number)
    end
    return tonumber(ffi.cast("uint32_t", bxor(crc, 0xFFFFFFFF))) as number
end

local function uint32_bytes(v: number): string
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

local function read_u8(buf: any, pos: number): number, number
    return (buf as {number:number})[pos], pos + 1
end

local function read_u16(buf: any, pos: number): number, number
    local b = buf as {number:number}
    return lshift(b[pos], 8) + b[pos + 1], pos + 2
end

local function read_u32(buf: any, pos: number): number, number
    local b = buf as {number:number}
    local v = lshift(b[pos], 24) + lshift(b[pos + 1], 16) +
              lshift(b[pos + 2], 8) + b[pos + 3]
    return tonumber(ffi.cast("uint32_t", v)) as number, pos + 4
end

local function read_u64(buf: any, pos: number): number, number, number
    local b = buf as {number:number}
    local hi = lshift(b[pos], 24) + lshift(b[pos + 1], 16) +
               lshift(b[pos + 2], 8) + b[pos + 3]
    local lo = lshift(b[pos + 4], 24) + lshift(b[pos + 5], 16) +
               lshift(b[pos + 6], 8) + b[pos + 7]
    return tonumber(ffi.cast("uint32_t", hi)) as number, tonumber(ffi.cast("uint32_t", lo)) as number, pos + 8
end

----------------------------------------------------------------------------
-- Frame decoding
----------------------------------------------------------------------------

local MIN_MESSAGE_LEN = 16

function M.decode_frame(data: string): M.Frame, string
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

function M._decode_from_buf(buf: ffi.CData, buf_len: number): M.Frame, string
    local pos: number = 0

    local total_len: number
    local headers_len: number
    total_len, pos = read_u32(buf, pos)
    headers_len, pos = read_u32(buf, pos)

    if total_len > buf_len then
        return nil as M.Frame, "incomplete frame"
    end
    if total_len < MIN_MESSAGE_LEN then
        return nil, "invalid total length"
    end

    local prelude_crc_expected = crc32(buf, 0, 8)
    local prelude_crc_actual: number
    prelude_crc_actual, pos = read_u32(buf, pos)
    if prelude_crc_expected ~= prelude_crc_actual then
        return nil, "prelude CRC mismatch"
    end

    local headers: {string:any} = {}
    local headers_end = pos + headers_len
    while pos < headers_end do
        local name_len: number
        name_len, pos = read_u8(buf, pos)
        local name = ffi.string(buf + pos, name_len) as string
        pos = pos + name_len

        local vtype: number
        vtype, pos = read_u8(buf, pos)

        local value: any
        if vtype == 0 then
            value = true
        elseif vtype == 1 then
            value = false
        elseif vtype == 2 then
            value = (buf as {number:number})[pos]
            pos = pos + 1
        elseif vtype == 3 then
            value, pos = read_u16(buf, pos)
        elseif vtype == 4 then
            value, pos = read_u32(buf, pos)
        elseif vtype == 5 then
            local hi: number
            local lo: number
            hi, lo, pos = read_u64(buf, pos)
            value = hi * 4294967296 + lo
        elseif vtype == 6 then
            local vlen: number
            vlen, pos = read_u16(buf, pos)
            value = ffi.string(buf + pos, vlen) as string
            pos = pos + vlen
        elseif vtype == 7 then
            local vlen: number
            vlen, pos = read_u16(buf, pos)
            value = ffi.string(buf + pos, vlen) as string
            pos = pos + vlen
        elseif vtype == 8 then
            local hi: number
            local lo: number
            hi, lo, pos = read_u64(buf, pos)
            value = (hi * 4294967296 + lo) / 1000
        elseif vtype == 9 then
            value = ffi.string(buf + pos, 16) as string
            pos = pos + 16
        else
            return nil, "unknown header value type: " .. tostring(vtype)
        end

        headers[name] = value
    end

    local payload_len = total_len - 12 - headers_len - 4
    local payload = ""
    if payload_len > 0 then
        payload = ffi.string(buf + pos, payload_len) as string
        pos = pos + payload_len
    end

    local msg_crc_expected = crc32(buf, 0, total_len - 4)
    local msg_crc_actual: number
    msg_crc_actual, pos = read_u32(buf, pos)
    if msg_crc_expected ~= msg_crc_actual then
        return nil, "message CRC mismatch"
    end

    local frame: M.Frame = { headers = headers, payload = payload }
    return frame, nil
end

----------------------------------------------------------------------------
-- Reading frames from a reader
----------------------------------------------------------------------------

function M.new_frame_reader(body_reader: function(): string): function(): M.Frame, string
    local buffer = ""

    local function read_frame(): M.Frame, string
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

----------------------------------------------------------------------------
-- Event deserialization
----------------------------------------------------------------------------

local function deserialize_event_struct(frame: M.Frame, member_schema: any, codec: any): any, any
    local target = (member_schema as {string:any})._target or member_schema
    local members_fn = (target as {string:any}).members as function(any): {string:any}
    local members = members_fn and members_fn(target)
    if not members then return {} end

    local result: {string:any} = {}

    local payload_member_name: string
    local payload_member_schema: any
    local body_members: {string:any} = {}

    for name, ms in pairs(members) do
        local trait_fn = (ms as {string:any}).trait as function(any, any): any
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
        local ptype = (payload_member_schema as {string:any}).type as string
        if ptype == "blob" then
            result[payload_member_name] = frame.payload
        elseif ptype == "string" then
            result[payload_member_name] = frame.payload
        else
            local deser_fn = (codec as {string:any}).deserialize as function(any, string, any): any, any
            local decoded, err = deser_fn(codec, frame.payload, payload_member_schema)
            if err then return nil, err end
            result[payload_member_name] = decoded
        end
    elseif #frame.payload > 0 and next(body_members) then
        local deser_fn = (codec as {string:any}).deserialize as function(any, string, any): any, any
        local decoded, err = deser_fn(codec, frame.payload, target)
        if err then return nil, err end
        for k, v in pairs(decoded as {string:any}) do
            result[k] = v
        end
    end

    return result
end

function M.deserialize_event(frame: M.Frame, event_schema: any, codec: any): any, any
    local msg_type = frame.headers[":message-type"] as string
    if not msg_type then
        return nil, { type = "sdk", message = "missing :message-type header" }
    end

    if msg_type == "error" then
        local code = (frame.headers[":error-code"] or "UnknownError") as string
        local message = (frame.headers[":error-message"] or "") as string
        return nil, { type = "api", code = code, message = message }
    end

    if msg_type == "exception" then
        local exc_type = frame.headers[":exception-type"] as string
        if not exc_type then
            return nil, { type = "api", code = "UnknownError", message = "missing :exception-type" }
        end
        local members_fn = (event_schema as {string:any}).members as function(any): {string:any}
        local es_members: {string:any} = members_fn and members_fn(event_schema) or (event_schema as {string:any})._members as {string:any}
        local member_schema = es_members and (es_members as {string:any})[exc_type]
        if not member_schema then
            return nil, { type = "api", code = exc_type, message = "unknown exception type" }
        end
        local data, err = deserialize_event_struct(frame, member_schema, codec)
        if err then return nil, err end
        local dmap = data as {string:any}
        return nil, {
            type = "api",
            code = exc_type,
            message = dmap.message or dmap.Message or "",
        }
    end

    if msg_type == "event" then
        local event_type = frame.headers[":event-type"] as string
        if not event_type then
            return nil, { type = "sdk", message = "missing :event-type header" }
        end

        if event_type == "initial-response" then
            return { _initial_response = true, _payload = frame.payload }, nil
        end

        local members_fn = (event_schema as {string:any}).members as function(any): {string:any}
        local es_members: {string:any} = members_fn and members_fn(event_schema) or (event_schema as {string:any})._members as {string:any}
        local member_schema = es_members and (es_members as {string:any})[event_type]
        if not member_schema then
            return nil, nil
        end

        local data, err = deserialize_event_struct(frame, member_schema, codec)
        if err then return nil, err end
        return { [event_type] = data }, nil
    end

    return nil, nil
end

----------------------------------------------------------------------------
-- Binary writing helpers
----------------------------------------------------------------------------

local function write_u8_str(v: number): string
    return string.char(band(v, 0xFF))
end

local function write_u16_str(v: number): string
    return string.char(band(rshift(v, 8), 0xFF), band(v, 0xFF))
end

local function write_u32_str(v: number): string
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

local function encode_header(name: string, value: any): string
    local parts: {string} = { write_u8_str(#name), name }
    local vtype = type(value)
    if vtype == "boolean" then
        parts[#parts + 1] = write_u8_str((value as boolean) and 0 or 1)
    elseif vtype == "number" then
        parts[#parts + 1] = write_u8_str(4)
        parts[#parts + 1] = write_u32_str(value as number)
    elseif vtype == "string" then
        parts[#parts + 1] = write_u8_str(7)
        parts[#parts + 1] = write_u16_str(#(value as string))
        parts[#parts + 1] = value as string
    else
        error("unsupported header value type: " .. vtype)
    end
    return table.concat(parts)
end

function M.encode_bytes_header(name: string, value: string): string
    local parts: {string} = { write_u8_str(#name), name }
    parts[#parts + 1] = write_u8_str(6)
    parts[#parts + 1] = write_u16_str(#value)
    parts[#parts + 1] = value
    return table.concat(parts)
end

function M.encode_timestamp_header(name: string, epoch_ms: number): string
    local parts: {string} = { write_u8_str(#name), name }
    parts[#parts + 1] = write_u8_str(8)
    local hi = math.floor(epoch_ms / 4294967296)
    local lo = epoch_ms - hi * 4294967296
    parts[#parts + 1] = write_u32_str(hi)
    parts[#parts + 1] = write_u32_str(lo)
    return table.concat(parts)
end

function M.encode_headers(headers: {string:any}): string
    local parts: {string} = {}
    for name, value in pairs(headers) do
        parts[#parts + 1] = encode_header(name, value)
    end
    return table.concat(parts)
end

----------------------------------------------------------------------------
-- Frame encoding
----------------------------------------------------------------------------

local function crc32_string(s: string, init?: number): number
    local len = #s
    local buf = ffi.new("uint8_t[?]", len)
    ffi.copy(buf, s, len)
    return crc32(buf, 0, len, init)
end

function M.encode_frame(headers_bytes: string, payload: string): string
    payload = payload or ""
    local headers_len = #headers_bytes
    local total_len = 12 + headers_len + #payload + 4

    local prelude = write_u32_str(total_len) .. write_u32_str(headers_len)
    local prelude_crc = crc32_string(prelude)

    local msg = prelude .. write_u32_str(prelude_crc) .. headers_bytes .. payload

    local msg_crc = crc32_string(msg)

    return msg .. write_u32_str(msg_crc)
end

----------------------------------------------------------------------------
-- Event serialization
----------------------------------------------------------------------------

function M.serialize_event(event: any, event_schema: any, codec: any): string, string
    local event_type: string
    local event_data: any
    for k, v in pairs(event as {string:any}) do
        event_type = k
        event_data = v
        break
    end
    if not event_type then
        return nil, "empty event"
    end

    local members_fn = (event_schema as {string:any}).members as function(any): {string:any}
    local es_members: {string:any} = members_fn and members_fn(event_schema) or (event_schema as {string:any})._members as {string:any}
    local member_schema = es_members and (es_members as {string:any})[event_type]
    if not member_schema then
        return nil, "unknown event type: " .. event_type
    end

    local target = (member_schema as {string:any})._target or member_schema
    local target_members_fn = (target as {string:any}).members as function(any): {string:any}
    local members = target_members_fn and target_members_fn(target)

    local header_parts: {string} = {}
    header_parts[#header_parts + 1] = encode_header(":message-type", "event")
    header_parts[#header_parts + 1] = encode_header(":event-type", event_type)

    local payload = ""
    if members then
        local payload_member_name: string
        local payload_member_schema: any
        local body_members: {string:any} = {}

        for name, ms in pairs(members) do
            local trait_fn = (ms as {string:any}).trait as function(any, any): any
            if trait_fn(ms, strait.EVENT_HEADER) then
                if (event_data as {string:any})[name] ~= nil then
                    header_parts[#header_parts + 1] = encode_header(name, (event_data as {string:any})[name])
                end
            elseif trait_fn(ms, strait.EVENT_PAYLOAD) then
                payload_member_name = name
                payload_member_schema = ms
            else
                body_members[name] = ms
            end
        end

        if payload_member_name and (event_data as {string:any})[payload_member_name] ~= nil then
            local ptype = (payload_member_schema as {string:any}).type as string
            if ptype == "blob" or ptype == "string" then
                payload = (event_data as {string:any})[payload_member_name] as string
                if ptype == "blob" then
                    header_parts[#header_parts + 1] = encode_header(":content-type", "application/octet-stream")
                else
                    header_parts[#header_parts + 1] = encode_header(":content-type", "text/plain")
                end
            else
                local ser_fn = (codec as {string:any}).serialize_value as function(any, any, any): string
                payload = ser_fn(codec, (event_data as {string:any})[payload_member_name], payload_member_schema)
                local ct = (codec as {string:any}).content_type as string or "application/json"
                header_parts[#header_parts + 1] = encode_header(":content-type", ct)
            end
        elseif next(body_members) then
            local ser_fn = (codec as {string:any}).serialize_value as function(any, any, any): string
            payload = ser_fn(codec, event_data, target)
            local ct = (codec as {string:any}).content_type as string or "application/json"
            header_parts[#header_parts + 1] = encode_header(":content-type", ct)
        end
    end

    local headers_bytes = table.concat(header_parts)
    return M.encode_frame(headers_bytes, payload)
end

----------------------------------------------------------------------------
-- SigningWriter
----------------------------------------------------------------------------

local SigningWriter_mt: metatable<M.SigningWriter> = { __index = M.SigningWriter as M.SigningWriter }

function M.new_signing_writer(signer: any): M.SigningWriter
    local sw: M.SigningWriter = setmetatable({
        _signer = signer,
        _queue = {},
        _closed = false,
    } as M.SigningWriter, SigningWriter_mt)

    sw.body_reader = function(): string
        if #sw._queue > 0 then
            local frame = table.remove(sw._queue, 1)
            return frame
        end
        if sw._closed then return nil end
        return nil
    end

    return sw
end

function M.SigningWriter:write(inner_frame: string): boolean, string
    if self._closed then return nil, "writer closed" end

    local now = os.time()
    local epoch_ms = now * 1000

    local date_header = M.encode_timestamp_header(":date", epoch_ms)

    local sign_fn = (self._signer as {string:any}).sign as function(any, string, string, number): string
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

    local sign_fn = (self._signer as {string:any}).sign as function(any, string, string, number): string
    local sig = sign_fn(self._signer, date_header, "", now)
    local headers_bytes = date_header .. M.encode_bytes_header(":chunk-signature", sig)
    local envelope = M.encode_frame(headers_bytes, "")

    self._queue[#self._queue + 1] = envelope
    self._closed = true
end

----------------------------------------------------------------------------
-- Stream object
----------------------------------------------------------------------------

local Stream_mt: metatable<M.Stream> = { __index = M.Stream as M.Stream }

function M.new_stream(body_reader: function(): string, event_schema: any, codec: any, opts: {string:any}): M.Stream
    opts = opts or {}
    local stream: M.Stream = setmetatable({
        _read_frame = M.new_frame_reader(body_reader),
        _event_schema = event_schema,
        _codec = codec,
        _closed = false,
        _has_initial_message = (opts.has_initial_message or false) as boolean,
        _output_schema = opts.output_schema,
        _on_close = opts.on_close as function(),
        initial_response = nil,
    } as M.Stream, Stream_mt)

    if stream._has_initial_message then
        local err = stream:_read_initial_response()
        if err then
            stream._error = err
        end
    end

    return stream
end

function M.Stream:_read_initial_response(): any
    local frame, err = self._read_frame()
    if err then return err end
    if not frame then return { type = "sdk", message = "expected initial-response, got EOF" } end

    local event_type = frame.headers[":event-type"] as string
    if event_type ~= "initial-response" then
        return { type = "sdk", message = "expected initial-response, got: " .. tostring(event_type) }
    end

    if self._output_schema and #frame.payload > 0 then
        local deser_fn = (self._codec as {string:any}).deserialize as function(any, string, any): any, any
        local decoded, derr = deser_fn(self._codec, frame.payload, self._output_schema)
        if derr then return derr end
        self.initial_response = decoded
    else
        self.initial_response = {}
    end
    return nil
end

function M.Stream:events(): function(): any, any
    return function(): any, any
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
