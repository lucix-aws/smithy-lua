-- smithy-lua runtime: awsJson1.0 / awsJson1.1 protocol

local json_codec = require("smithy.codec.json")
local http = require("smithy.http")
local t = require("smithy.traits")
local schema_mod = require("smithy.schema")

local record M
    content_type: string
    service_id: string
    codec: json_codec
    has_event_stream_initial_message: boolean

    metamethod __index: M
end

local M_mt: metatable<M> = { __index = M }

function M.new(settings: any): M
    local s = settings as {string:string}
    if type(settings) == "string" then
        s = { version = settings as string }
    end
    local version = s and s.version or "1.0"
    return setmetatable({
        content_type = "application/x-amz-json-" .. version,
        service_id = s and s.service_id or "",
        codec = json_codec.new({ use_json_name = false }),
        has_event_stream_initial_message = true,
    } as M, M_mt)
end

function M:serialize(input: {string:any}, service: schema_mod.ServiceSchema, operation: schema_mod.OperationSchema): http.Request, http.Error
    local body, err = self.codec:serialize(input or {} as {string:any}, operation.input)
    if err then return nil, err as http.Error end

    local http_trait = operation:trait(t.HTTP) as {string:string}
    local service_id = service.id as any as {string:string}
    local op_id = operation.id as any as {string:string}
    local target = service_id.name .. "." .. op_id.name
    local ct = self.content_type
    local meth = http_trait and http_trait.method or "POST"
    local path = http_trait and http_trait.path or "/"
    local hdrs: {string:string} = {}
    hdrs["Content-Type"] = ct
    hdrs["X-Amz-Target"] = target
    return http.new_request(meth, path, hdrs, http.string_reader(body)), nil
end

local function parse_error_code(response: http.Response, body_table: {string:any}): string
    local header = response.headers and (
        response.headers["x-amzn-errortype"] or
        response.headers["X-Amzn-Errortype"]
    )
    if header then
        return header:match("^([^:]+)") or header
    end
    if body_table then
        local code = body_table["__type"] or body_table["code"] or body_table["Code"]
        if code then
            local s = code as string
            return s:match("#(.+)$") or s
        end
    end
    return "UnknownError"
end

function M:deserialize(response: http.Response, operation: schema_mod.OperationSchema): {string:any}, http.Error
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        local e: http.Error = { type = "http", code = "ResponseReadError", message = read_err as any as string }
        return nil, e
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local body_table: {string:any}
        if body_str and #body_str > 0 then
            local raw = require("smithy.json.decoder").decode(body_str)
            if type(raw) == "table" then body_table = raw as {string:any} end
        end

        local code = parse_error_code(response, body_table)
        local message = ""
        if body_table then
            message = (body_table["message"] or body_table["Message"]
                or body_table["errorMessage"] or "") as string
        end

        local e: http.Error = {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
        return nil, e
    end

    if not body_str or #body_str == 0 then
        return {}, nil
    end

    local result, err = self.codec:deserialize(body_str, operation.output)
    if err then return nil, err as http.Error end
    return result as {string:any}, nil
end

return M
