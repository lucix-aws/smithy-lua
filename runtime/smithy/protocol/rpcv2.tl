-- smithy-lua runtime: Smithy RPCv2 protocol (CBOR and JSON variants)

local http = require("smithy.http")
local prelude = require("smithy.prelude")
local schema_mod = require("smithy.schema")

local record Codec
    serialize: function(Codec, input: {string:any}, schema: schema_mod.Schema): string, any
    deserialize: function(Codec, bytes: string, schema: schema_mod.Schema): any, any
end

local record M
    codec: Codec
    protocol_id: string
    content_type: string
    service_name: string
    has_event_stream_initial_message: boolean

    metamethod __index: M
end

local M_mt: metatable<M> = { __index = M }

local function new(codec: Codec, protocol_id: string, content_type: string, settings: {string:any}): M
    settings = settings or {}
    return setmetatable({
        codec = codec,
        protocol_id = protocol_id,
        content_type = content_type,
        service_name = settings.service_name as string or "",
        has_event_stream_initial_message = true,
    } as M, M_mt)
end

function M.new_cbor(settings: {string:any}): M
    local cbor_codec = require("smithy.codec.cbor")
    return new(cbor_codec.new() as Codec, "rpc-v2-cbor", "application/cbor", settings)
end

function M.new_json(settings: {string:any}): M
    local json_codec = require("smithy.codec.json")
    return new(json_codec.new() as Codec, "rpc-v2-json", "application/json", settings)
end

function M:serialize(input: {string:any}, service: schema_mod.ServiceSchema, operation: schema_mod.OperationSchema): http.Request, http.Error
    input = input or {}
    local service_id = service.id as any as {string:string}
    local op_id = operation.id as any as {string:string}
    local path = "/service/" .. service_id.name .. "/operation/" .. op_id.name

    local headers: {string:string} = {}
    headers["smithy-protocol"] = self.protocol_id
    headers["Accept"] = self.content_type

    local schema = operation.input
    if schema == prelude.Unit then
        return http.new_request("POST", path, headers, http.string_reader("")), nil
    end

    headers["Content-Type"] = self.content_type
    local body_str, err = self.codec:serialize(input, schema)
    if err then return nil, err as http.Error end

    return http.new_request("POST", path, headers, http.string_reader(body_str)), nil
end

function M:deserialize(response: http.Response, operation: schema_mod.OperationSchema): {string:any}, http.Error
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        local e: http.Error = { type = "http", code = "ResponseReadError", message = read_err as any as string }
        return nil, e
    end

    local proto_header = response.headers and (
        response.headers["Smithy-Protocol"] or
        response.headers["smithy-protocol"]
    )
    if proto_header and proto_header ~= self.protocol_id then
        local e: http.Error = {
            type = "sdk",
            code = "ProtocolMismatch",
            message = "expected Smithy-Protocol: " .. self.protocol_id .. ", got: " .. proto_header,
        }
        return nil, e
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local code, message = "UnknownError", ""
        if body_str and #body_str > 0 then
            local raw = self.codec:deserialize(body_str, nil as schema_mod.Schema)
            if type(raw) == "table" then
                local tbl = raw as {string:any}
                local rt = (tbl["__type"] or "") as string
                code = rt:match("#(.+)$") or rt
                if code == "" then code = "UnknownError" end
                message = (tbl["message"] or tbl["Message"] or "") as string
            end
        end
        local e: http.Error = {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
        return nil, e
    end

    if not body_str or #body_str == 0 then return {}, nil end

    local result, err = self.codec:deserialize(body_str, operation.output)
    if err then return nil, err as http.Error end
    return result as {string:any}, nil
end

return M
