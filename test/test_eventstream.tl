local assert = require("luassert") as any
-- Test: runtime/smithy/eventstream.lua — binary frame decoder + event deserialization

local eventstream = require("smithy.eventstream")
local schema_mod = require("smithy.schema")
local traits = require("smithy.traits")
local stype = schema_mod.type
local ffi = require("ffi")
local bit = require("bit")

--- Convert a plain table schema definition to a proper Schema object.
local function S(t: {string:any}): any
    if not t or (t as {string:any})["trait"] then return t end -- already a Schema
    local members: {string:any}
    if t["members"] then
        members = {}
        for k, v in pairs(t["members"] as {string:any}) do
            members[k] = S(v as {string:any})
        end
    end
    local target: any
    if t["target"] then target = S(t["target"] as {string:any}) end
    local schema_traits: {string:any}
    if t["traits"] then
        schema_traits = {}
        for k, v in pairs(t["traits"] as {string:any}) do
            if k then schema_traits[k] = v end
        end
    end
    return schema_mod.new({
        type = t["type"] as string,
        members = members,
        target = target,
        traits = schema_traits,
    } as any)
end

----------------------------------------------------------------------------
-- Frame building helpers (for constructing test data)
----------------------------------------------------------------------------

local function write_u8(buf: {string}, v: number)
    buf[#buf + 1] = string.char(bit.band(v, 0xFF))
end

local function write_u16(buf: {string}, v: number)
    buf[#buf + 1] = string.char(bit.band(bit.rshift(v, 8), 0xFF))
    buf[#buf + 1] = string.char(bit.band(v, 0xFF))
end

local function write_u32(buf: {string}, v: number)
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

local function crc32_str(data: string, init: number): number
    local crc = bit.bxor(init or 0, 0xFFFFFFFF)
    for i = 1, #data do
        local b = data:byte(i)
        crc = bit.bxor(bit.rshift(crc, 8), crc_table[bit.band(bit.bxor(crc, b), 0xFF)])
    end
    return tonumber(ffi.cast("uint32_t", bit.bxor(crc, 0xFFFFFFFF))) as number
end

-- Encode a string header value (type 7)
local function encode_string_header(name: string, value: string): string
    local buf: {string} = {}
    write_u8(buf, #name)
    buf[#buf + 1] = name
    write_u8(buf, 7) -- string type
    write_u16(buf, #value)
    buf[#buf + 1] = value
    return table.concat(buf)
end

-- Build a complete event stream frame
local function build_frame(headers_data: string, payload: string): string
    payload = payload or ""
    local headers_len = #headers_data
    local total_len = 4 + 4 + 4 + headers_len + #payload + 4

    local prelude: {string} = {}
    write_u32(prelude, total_len)
    write_u32(prelude, headers_len)
    local prelude_str = table.concat(prelude)
    local prelude_crc = crc32_str(prelude_str)

    local msg_buf: {string} = {}
    msg_buf[#msg_buf + 1] = prelude_str
    write_u32(msg_buf, prelude_crc)
    msg_buf[#msg_buf + 1] = headers_data
    msg_buf[#msg_buf + 1] = payload
    local msg_without_crc = table.concat(msg_buf)

    local msg_crc = crc32_str(msg_without_crc)
    local crc_buf: {string} = {}
    write_u32(crc_buf, msg_crc)

    return msg_without_crc .. table.concat(crc_buf)
end

-- Build a simple event message frame
local function build_event_frame(event_type: string, payload: string, content_type: string): string
    local headers = encode_string_header(":message-type", "event")
                 .. encode_string_header(":event-type", event_type)
    if content_type then
        headers = headers .. encode_string_header(":content-type", content_type)
    end
    return build_frame(headers, payload)
end

describe("eventstream", function()

it("decode_frame: minimal frame (no headers, no payload)", function()
    local frame_data = build_frame("", "")
    local frame, err = eventstream.decode_frame(frame_data)
    assert.are.equal(nil, err)
    assert.is_truthy(frame)
    assert.are.equal("", (frame as eventstream.Frame).payload)
end)

it("decode_frame: frame with string header", function()
    local headers = encode_string_header(":event-type", "MessageEvent")
    local frame_data = build_frame(headers, "")
    local frame, err = eventstream.decode_frame(frame_data)
    assert.are.equal(nil, err)
    assert.is_truthy(frame)
    assert.are.equal("MessageEvent", (frame as eventstream.Frame).headers[":event-type"])
end)

it("decode_frame: frame with payload", function()
    local headers = encode_string_header(":message-type", "event")
                 .. encode_string_header(":event-type", "test")
    local payload = '{"message":"hello"}'
    local frame_data = build_frame(headers, payload)
    local frame, err = eventstream.decode_frame(frame_data)
    assert.are.equal(nil, err)
    assert.is_truthy(frame)
    assert.are.equal(payload, (frame as eventstream.Frame).payload)
    assert.are.equal("event", (frame as eventstream.Frame).headers[":message-type"])
    assert.are.equal("test", (frame as eventstream.Frame).headers[":event-type"])
end)

it("decode_frame: CRC mismatch detected", function()
    local frame_data = build_frame("", "")
    local len = #frame_data
    frame_data = frame_data:sub(1, len - 3) .. "\x00" .. frame_data:sub(len - 1)
    local frame, err = eventstream.decode_frame(frame_data)
    assert.is_nil(frame)
    assert.are.equal("message CRC mismatch", err)
end)

it("decode_frame: frame too short", function()
    local frame, err = eventstream.decode_frame("short")
    assert.is_nil(frame)
    assert.are.equal("frame too short", err)
end)

it("new_frame_reader: reads multiple frames from chunked reader", function()
    local frame1 = build_event_frame("event1", '{"a":1}', "application/json")
    local frame2 = build_event_frame("event2", '{"b":2}', "application/json")
    local all_data = frame1 .. frame2

    local chunks: {string} = { all_data:sub(1, 10), all_data:sub(11, 30), all_data:sub(31) }
    local idx = 0
    local reader = function(): string
        idx = idx + 1
        return chunks[idx]
    end

    local read_frame = eventstream.new_frame_reader(reader)

    local f1, err1 = read_frame()
    assert.are.equal(nil, err1)
    assert.is_truthy(f1)
    assert.are.equal("event1", (f1 as eventstream.Frame).headers[":event-type"])

    local f2, err2 = read_frame()
    assert.are.equal(nil, err2)
    assert.is_truthy(f2)
    assert.are.equal("event2", (f2 as eventstream.Frame).headers[":event-type"])

    local f3 = read_frame()
    assert.is_nil(f3)
end)

it("deserialize_event: message event with JSON payload", function()
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
    } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "MessageEvent",
            [":content-type"] = "application/json",
        },
        payload = '{"message":"hello world"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.are.equal(nil, err)
    assert.is_truthy(event)
    assert.is_truthy((event as {string:any}).MessageEvent)
    assert.are.equal("hello world", ((event as {string:any}).MessageEvent as {string:any}).message)
end)

it("deserialize_event: event with @eventHeader binding", function()
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
    } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "HeaderEvent",
            [":content-type"] = "application/json",
            ["sequenceNum"] = 42,
        },
        payload = '{"data":"test"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.are.equal(nil, err)
    assert.is_truthy(event)
    assert.is_truthy((event as {string:any}).HeaderEvent)
    assert.are.equal(42, ((event as {string:any}).HeaderEvent as {string:any}).sequenceNum)
    assert.are.equal("test", ((event as {string:any}).HeaderEvent as {string:any}).data)
end)

it("deserialize_event: event with @eventPayload blob", function()
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
    } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "BlobEvent",
            [":content-type"] = "application/octet-stream",
        },
        payload = "\x01\x02\x03\x04",
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.are.equal(nil, err)
    assert.is_truthy(event)
    assert.are.equal("\x01\x02\x03\x04", ((event as {string:any}).BlobEvent as {string:any}).data)
end)

it("deserialize_event: unmodeled error", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })
    local event_schema = S({ type = stype.UNION, members = {} } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "error",
            [":error-code"] = "InternalError",
            [":error-message"] = "Something went wrong",
        },
        payload = "",
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.is_nil(event)
    assert.is_truthy(err)
    assert.are.equal("api", (err as {string:any})["type"])
    assert.are.equal("InternalError", (err as {string:any}).code)
    assert.are.equal("Something went wrong", (err as {string:any}).message)
end)

it("deserialize_event: modeled exception", function()
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
    } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "exception",
            [":exception-type"] = "ValidationError",
            [":content-type"] = "application/json",
        },
        payload = '{"message":"invalid input"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.is_nil(event)
    assert.is_truthy(err)
    assert.are.equal("api", (err as {string:any})["type"])
    assert.are.equal("ValidationError", (err as {string:any}).code)
    assert.are.equal("invalid input", (err as {string:any}).message)
end)

it("deserialize_event: unknown event type is skipped", function()
    local json_codec = require("smithy.codec.json").new({ use_json_name = false })
    local event_schema = S({ type = stype.UNION, members = {} } as {string:any})

    local frame: eventstream.Frame = {
        headers = {
            [":message-type"] = "event",
            [":event-type"] = "NewUnknownEvent",
        },
        payload = '{"foo":"bar"}',
    }

    local event, err = eventstream.deserialize_event(frame, event_schema, json_codec)
    assert.is_nil(event)
    assert.is_nil(err)
end)

it("stream: events() iterator with multiple events", function()
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
    } as {string:any})

    local frame1 = build_event_frame("Msg", '{"text":"one"}', "application/json")
    local frame2 = build_event_frame("Msg", '{"text":"two"}', "application/json")
    local all_data = frame1 .. frame2

    local done = false
    local reader = function(): string
        if done then return nil end
        done = true
        return all_data
    end

    local stream = eventstream.new_stream(reader, event_schema, json_codec)
    local events: {any} = {}
    for event, err in stream:events() do
        if err then error("unexpected error: " .. (err as {string:any}).message) end
        events[#events + 1] = event
    end

    assert.are.equal(2, #events)
    assert.are.equal("one", ((events[1] as {string:any}).Msg as {string:any}).text)
    assert.are.equal("two", ((events[2] as {string:any}).Msg as {string:any}).text)
end)

it("stream: initial-response for RPC protocols", function()
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
    } as {string:any})

    local output_schema = S({
        type = stype.STRUCTURE,
        members = {
            sessionId = { type = stype.STRING },
        },
    } as {string:any})

    local initial = build_event_frame("initial-response", '{"sessionId":"abc123"}', "application/json")
    local event = build_event_frame("Msg", '{"text":"hello"}', "application/json")
    local all_data = initial .. event

    local done = false
    local reader = function(): string
        if done then return nil end
        done = true
        return all_data
    end

    local stream = eventstream.new_stream(reader, event_schema, json_codec, {
        has_initial_message = true,
        output_schema = output_schema,
    } as any)

    assert.is_truthy((stream as eventstream.Stream).initial_response)
    assert.are.equal("abc123", ((stream as eventstream.Stream).initial_response as {string:any}).sessionId)

    local events: {any} = {}
    for ev in stream:events() do
        events[#events + 1] = ev
    end
    assert.are.equal(1, #events)
    assert.are.equal("hello", ((events[1] as {string:any}).Msg as {string:any}).text)
end)

end)
