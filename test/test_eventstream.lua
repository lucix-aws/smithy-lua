-- Test: runtime/smithy/eventstream.lua — binary frame decoder + event deserialization
-- Run: luajit test/test_eventstream.lua

package.path = "runtime/?.lua;runtime/?/init.lua;" .. package.path

local eventstream = require("smithy.eventstream")
local schema_mod = require("smithy.schema")
local traits = require("smithy.traits")
local stype = schema_mod.type
local ffi = require("ffi")
local bit = require("bit")

--- Convert a plain table schema definition to a proper Schema object.
local function S(t)
    if not t or t.trait then return t end -- already a Schema
    local members
    if t.members then
        members = {}
        for k, v in pairs(t.members) do
            members[k] = S(v)
        end
    end
    local target
    if t.target then target = S(t.target) end
    -- Convert trait keys from traits module
    local schema_traits
    if t.traits then
        schema_traits = {}
        for k, v in pairs(t.traits) do
            if k then schema_traits[k] = v end
        end
    end
    return schema_mod.new({
        type = t.type,
        members = members,
        target = target,
        traits = schema_traits,
    })
end

local pass_count = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print("PASS: " .. name)
    else
        print("FAIL: " .. name .. "\n  " .. tostring(err))
        os.exit(1)
    end
end

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "assert_eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
    end
end

local function assert_not_nil(v, msg)
    if v == nil then
        error((msg or "assert_not_nil") .. ": got nil", 2)
    end
end

----------------------------------------------------------------------------
-- Frame building helpers (for constructing test data)
----------------------------------------------------------------------------

local function write_u8(buf, v)
    buf[#buf + 1] = string.char(bit.band(v, 0xFF))
end

local function write_u16(buf, v)
    buf[#buf + 1] = string.char(bit.band(bit.rshift(v, 8), 0xFF))
    buf[#buf + 1] = string.char(bit.band(v, 0xFF))
end

local function write_u32(buf, v)
    buf[#buf + 1] = string.char(
        bit.band(bit.rshift(v, 24), 0xFF),
        bit.band(bit.rshift(v, 16), 0xFF),
        bit.band(bit.rshift(v, 8), 0xFF),
        bit.band(v, 0xFF)
    )
end

-- CRC-32 IEEE matching the runtime implementation
local crc_table = ffi.new("uint32_t[256]")
do
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            if bit.band(c, 1) == 1 then
                c = bit.bxor(bit.rshift(c, 1), 0xEDB88320)
            else
                c = bit.rshift(c, 1)
            end
        end
        crc_table[i] = c
    end
end

local function crc32_str(data, init)
    local crc = bit.bxor(init or 0, 0xFFFFFFFF)
    for i = 1, #data do
        local b = data:byte(i)
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, b), 0xFF)])
    end
    return tonumber(ffi.cast("uint32_t", bit.bxor(crc, 0xFFFFFFFF)))
end

-- Encode a string header value (type 7)
local function encode_string_header(name, value)
    local buf = {}
    write_u8(buf, #name)
    buf[#buf + 1] = name
    write_u8(buf, 7) -- string type
    write_u16(buf, #value)
    buf[#buf + 1] = value
    return table.concat(buf)
end

-- Build a complete event stream frame
local function build_frame(headers_data, payload)
    payload = payload or ""
    local headers_len = #headers_data
    local total_len = 4 + 4 + 4 + headers_len + #payload + 4 -- prelude(12) + headers + payload + msg_crc

    -- Build prelude
    local prelude = {}
    write_u32(prelude, total_len)
    write_u32(prelude, headers_len)
    local prelude_str = table.concat(prelude)
    local prelude_crc = crc32_str(prelude_str)

    -- Build message without final CRC
    local msg_buf = {}
    msg_buf[#msg_buf + 1] = prelude_str
    write_u32(msg_buf, prelude_crc)
    msg_buf[#msg_buf + 1] = headers_data
    msg_buf[#msg_buf + 1] = payload
    local msg_without_crc = table.concat(msg_buf)

    -- Compute message CRC over everything
    local msg_crc = crc32_str(msg_without_crc)
    local crc_buf = {}
    write_u32(crc_buf, msg_crc)

    return msg_without_crc .. table.concat(crc_buf)
end

-- Build a simple event message frame
local function build_event_frame(event_type, payload, content_type)
    local headers = encode_string_header(":message-type", "event")
                 .. encode_string_header(":event-type", event_type)
    if content_type then
        headers = headers .. encode_string_header(":content-type", content_type)
    end
    return build_frame(headers, payload)
end

----------------------------------------------------------------------------
-- Tests
----------------------------------------------------------------------------

test("decode_frame: minimal frame (no headers, no payload)", function()
    local frame_data = build_frame("", "")
    local frame, err = eventstream.decode_frame(frame_data)
    assert_eq(err, nil, "err")
    assert_not_nil(frame, "frame")
    assert_eq(frame.payload, "", "payload")
end)

test("decode_frame: frame with string header", function()
    local headers = encode_string_header(":event-type", "MessageEvent")
    local frame_data = build_frame(headers, "")
    local frame, err = eventstream.decode_frame(frame_data)
    assert_eq(err, nil, "err")
    assert_not_nil(frame, "frame")
    assert_eq(frame.headers[":event-type"], "MessageEvent", "event-type header")
end)

test("decode_frame: frame with payload", function()
    local headers = encode_string_header(":message-type", "event")
                 .. encode_string_header(":event-type", "test")
    local payload = '{"message":"hello"}'
    local frame_data = build_frame(headers, payload)
    local frame, err = eventstream.decode_frame(frame_data)
    assert_eq(err, nil, "err")
    assert_not_nil(frame, "frame")
    assert_eq(frame.payload, payload, "payload")
    assert_eq(frame.headers[":message-type"], "event", "message-type")
    assert_eq(frame.headers[":event-type"], "test", "event-type")
end)

test("decode_frame: CRC mismatch detected", function()
    local frame_data = build_frame("", "")
    -- Corrupt a byte in the middle (after prelude CRC, before msg CRC)
    -- For a minimal frame this is the msg CRC itself, flip a middle byte
    local len = #frame_data
    frame_data = frame_data:sub(1, len - 3) .. "\x00" .. frame_data:sub(len - 1)
    local frame, err = eventstream.decode_frame(frame_data)
    assert_eq(frame, nil, "frame should be nil")
    assert_eq(err, "message CRC mismatch", "error")
end)

test("decode_frame: frame too short", function()
    local frame, err = eventstream.decode_frame("short")
    assert_eq(frame, nil, "frame should be nil")
    assert_eq(err, "frame too short", "error")
end)

test("new_frame_reader: reads multiple frames from chunked reader", function()
    local frame1 = build_event_frame("event1", '{"a":1}', "application/json")
    local frame2 = build_event_frame("event2", '{"b":2}', "application/json")
    local all_data = frame1 .. frame2

    -- Simulate chunked delivery (split at arbitrary points)
    local chunks = { all_data:sub(1, 10), all_data:sub(11, 30), all_data:sub(31) }
    local idx = 0
    local reader = function()
        idx = idx + 1
        return chunks[idx]
    end

    local read_frame = eventstream.new_frame_reader(reader)

    local f1, err1 = read_frame()
    assert_eq(err1, nil, "err1")
    assert_not_nil(f1, "frame1")
    assert_eq(f1.headers[":event-type"], "event1", "event1 type")

    local f2, err2 = read_frame()
    assert_eq(err2, nil, "err2")
    assert_not_nil(f2, "frame2")
    assert_eq(f2.headers[":event-type"], "event2", "event2 type")

    -- EOF
    local f3 = read_frame()
    assert_eq(f3, nil, "should be nil at EOF")
end)

test("deserialize_event: message event with JSON payload", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            MessageEvent = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        message = { type = stype.STRING },
                    },
                },
            },
        },
    })

    local frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "MessageEvent",
            [":content-type"] = "application/json",
        },
        payload = '{"message":"hello world"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert_eq(err, nil, "err")
    assert_not_nil(event, "event")
    assert_not_nil(event.MessageEvent, "MessageEvent")
    assert_eq(event.MessageEvent.message, "hello world", "message field")
end)

test("deserialize_event: event with @eventHeader binding", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            HeaderEvent = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        sequenceNum = {
                            type = stype.INTEGER,
                            traits = { [traits.EVENT_HEADER] = true },
                        },
                        data = { type = stype.STRING },
                    },
                },
            },
        },
    })

    local frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "HeaderEvent",
            [":content-type"] = "application/json",
            ["sequenceNum"] = 42,
        },
        payload = '{"data":"test"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert_eq(err, nil, "err")
    assert_not_nil(event, "event")
    assert_not_nil(event.HeaderEvent, "HeaderEvent")
    assert_eq(event.HeaderEvent.sequenceNum, 42, "sequenceNum from header")
    assert_eq(event.HeaderEvent.data, "test", "data from payload")
end)

test("deserialize_event: event with @eventPayload blob", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            BlobEvent = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        data = {
                            type = stype.BLOB,
                            traits = { [traits.EVENT_PAYLOAD] = true },
                        },
                    },
                },
            },
        },
    })

    local frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "BlobEvent",
            [":content-type"] = "application/octet-stream",
        },
        payload = "\x01\x02\x03\x04",
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert_eq(err, nil, "err")
    assert_not_nil(event, "event")
    assert_eq(event.BlobEvent.data, "\x01\x02\x03\x04", "blob payload")
end)

test("deserialize_event: unmodeled error", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })
    local event_schema = S({ type = stype.UNION, members = {} })

    local frame = {
        headers = {
            [":message-type"] = "error",
            [":error-code"] = "InternalError",
            [":error-message"] = "Something went wrong",
        },
        payload = "",
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert_eq(event, nil, "event should be nil")
    assert_not_nil(err, "err")
    assert_eq(err.type, "api", "error type")
    assert_eq(err.code, "InternalError", "error code")
    assert_eq(err.message, "Something went wrong", "error message")
end)

test("deserialize_event: modeled exception", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            ValidationError = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        message = { type = stype.STRING },
                    },
                },
            },
        },
    })

    local frame = {
        headers = {
            [":message-type"] = "exception",
            [":exception-type"] = "ValidationError",
            [":content-type"] = "application/json",
        },
        payload = '{"message":"invalid input"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert_eq(event, nil, "event should be nil")
    assert_not_nil(err, "err")
    assert_eq(err.type, "api", "error type")
    assert_eq(err.code, "ValidationError", "error code")
    assert_eq(err.message, "invalid input", "error message")
end)

test("deserialize_event: unknown event type is skipped", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })
    local event_schema = S({ type = stype.UNION, members = {} })

    local frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "NewUnknownEvent",
        },
        payload = '{"foo":"bar"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    -- Unknown events are skipped (nil, nil)
    assert_eq(event, nil, "event should be nil")
    assert_eq(err, nil, "err should be nil")
end)

test("stream: events() iterator with multiple events", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            Msg = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        text = { type = stype.STRING },
                    },
                },
            },
        },
    })

    -- Build two event frames
    local frame1 = build_event_frame("Msg", '{"text":"one"}', "application/json")
    local frame2 = build_event_frame("Msg", '{"text":"two"}', "application/json")
    local all_data = frame1 .. frame2

    local done = false
    local reader = function()
        if done then return nil end
        done = true
        return all_data
    end

    local stream = eventstream.new_stream(reader, event_schema, json_codec)
    local events = {}
    for event, err in stream:events() do
        if err then error("unexpected error: " .. err.message) end
        events[#events + 1] = event
    end

    assert_eq(#events, 2, "event count")
    assert_eq(events[1].Msg.text, "one", "first event")
    assert_eq(events[2].Msg.text, "two", "second event")
end)

test("stream: initial-response for RPC protocols", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })

    local event_schema = S({
        type = stype.UNION,
        members = {
            Msg = {
                type = stype.STRUCTURE,
                target = {
                    type = stype.STRUCTURE,
                    members = {
                        text = { type = stype.STRING },
                    },
                },
            },
        },
    })

    local output_schema = S({
        type = stype.STRUCTURE,
        members = {
            sessionId = { type = stype.STRING },
        },
    })

    -- Build initial-response + one event
    local initial = build_event_frame("initial-response", '{"sessionId":"abc123"}', "application/json")
    local event = build_event_frame("Msg", '{"text":"hello"}', "application/json")
    local all_data = initial .. event

    local done = false
    local reader = function()
        if done then return nil end
        done = true
        return all_data
    end

    local stream = eventstream.new_stream(reader, event_schema, json_codec, {
        has_initial_message = true,
        output_schema = output_schema,
    })

    -- Initial response should be parsed
    assert_not_nil(stream.initial_response, "initial_response")
    assert_eq(stream.initial_response.sessionId, "abc123", "sessionId")

    -- Events should still work
    local events = {}
    for event in stream:events() do
        events[#events + 1] = event
    end
    assert_eq(#events, 1, "event count")
    assert_eq(events[1].Msg.text, "hello", "event text")
end)

print(string.format("\n%d tests passed", pass_count))
