-- smithy-lua runtime: Smithy RPCv2 protocol (CBOR and JSON variants)
-- RPC-style protocol parameterized by codec format.

local http = require("smithy.http")
local prelude = require("smithy.prelude")

local M = {}
M.__index = M

local function new(codec, protocol_id, content_type, settings)
    settings = settings or {}
    return setmetatable({
        codec = codec,
        protocol_id = protocol_id,
        content_type = content_type,
        service_name = settings.service_name or "",
        has_event_stream_initial_message = true,
    }, M)
end

function M.new_cbor(settings)
    local cbor_codec = require("smithy.codec.cbor")
    return new(cbor_codec.new(), "rpc-v2-cbor", "application/cbor", settings)
end

function M.new_json(settings)
    local json_codec = require("smithy.codec.json")
    return new(json_codec.new(), "rpc-v2-json", "application/json", settings)
end

function M.serialize(self, input, service, operation)
    input = input or {}
    local path = "/service/" .. service.id.name .. "/operation/" .. operation.id.name

    local headers = {
        ["smithy-protocol"] = self.protocol_id,
        ["Accept"] = self.content_type,
    }

    local schema = operation.input
    if schema == prelude.Unit then
        return http.new_request("POST", path, headers, http.string_reader("")), nil
    end

    headers["Content-Type"] = self.content_type
    local body_str, err = self.codec:serialize(input, schema)
    if err then return nil, err end

    return http.new_request("POST", path, headers, http.string_reader(body_str)), nil
end

function M.deserialize(self, response, operation)
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    local proto_header = response.headers and (
        response.headers["Smithy-Protocol"] or
        response.headers["smithy-protocol"]
    )
    if proto_header and proto_header ~= self.protocol_id then
        return nil, {
            type = "sdk",
            code = "ProtocolMismatch",
            message = "expected Smithy-Protocol: " .. self.protocol_id .. ", got: " .. proto_header,
        }
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local code, message = "UnknownError", ""
        if body_str and #body_str > 0 then
            local raw = self.codec:deserialize(body_str, nil)
            if type(raw) == "table" then
                local rt = raw["__type"] or ""
                code = rt:match("#(.+)$") or rt
                if code == "" then code = "UnknownError" end
                message = raw["message"] or raw["Message"] or ""
            end
        end
        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    if not body_str or #body_str == 0 then return {}, nil end

    return self.codec:deserialize(body_str, operation.output)
end

return M
