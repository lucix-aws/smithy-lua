-- smithy-lua runtime: Smithy RPCv2 CBOR protocol
-- RPC-style protocol with CBOR body.

local cbor_codec = require("codec.cbor")
local http = require("http")
local schema_mod = require("schema")
local stype = schema_mod.type

local M = {}
M.__index = M

function M.new(settings)
    settings = settings or {}
    return setmetatable({
        codec = cbor_codec.new(),
        service_name = settings.service_name or "",
    }, M)
end

function M.serialize(self, input, operation)
    input = input or {}
    local path = "/service/" .. self.service_name .. "/operation/" .. operation.name

    local headers = {
        ["Smithy-Protocol"] = "rpc-v2-cbor",
        ["Accept"] = "application/cbor",
    }

    -- Check if input has any members with values
    local has_body = false
    local schema = operation.input_schema
    if schema and schema.members then
        for k in pairs(schema.members) do
            if input[k] ~= nil then has_body = true; break end
        end
    end

    local body_str
    if has_body then
        headers["Content-Type"] = "application/cbor"
        local err
        body_str, err = self.codec:serialize(input, schema)
        if err then return nil, err end
    else
        body_str = ""
    end

    return http.new_request(
        "POST",
        path,
        headers,
        http.string_reader(body_str)
    ), nil
end

function M.deserialize(self, response, operation)
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    -- Check Smithy-Protocol header
    local proto_header = response.headers and (
        response.headers["Smithy-Protocol"] or
        response.headers["smithy-protocol"]
    )
    if proto_header and proto_header ~= "rpc-v2-cbor" then
        return nil, {
            type = "sdk",
            code = "ProtocolMismatch",
            message = "expected Smithy-Protocol: rpc-v2-cbor, got: " .. proto_header,
        }
    end

    -- Error response
    if response.status_code < 200 or response.status_code >= 300 then
        local code, message = "UnknownError", ""
        if body_str and #body_str > 0 then
            local raw = self.codec:deserialize(body_str, nil)
            if type(raw) == "table" then
                local t = raw["__type"] or ""
                code = t:match("#(.+)$") or t
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

    -- Success: empty body is valid
    if not body_str or #body_str == 0 then return {}, nil end

    return self.codec:deserialize(body_str, operation.output_schema)
end

return M
