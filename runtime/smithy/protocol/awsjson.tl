-- smithy-lua runtime: awsJson1.0 / awsJson1.1 protocol

local json_codec = require("smithy.codec.json")
local http_mod = require("smithy.http")
local schema_mod = require("smithy.schema")
local decoder = require("smithy.json.decoder")

local record awsjson_mod
    content_type: string
    service_id: string
    codec: json_codec
    has_event_stream_initial_message: boolean
end

local awsjson_mt: metatable<awsjson_mod> = { __index = awsjson_mod }

function awsjson_mod.new(settings: any): awsjson_mod
    local s: {string:any}
    if type(settings) == "string" then
        s = { version = settings }
    else
        s = (settings as {string:any}) or {}
    end
    local version = (s.version as string) or "1.0"
    return setmetatable({
        content_type = "application/x-amz-json-" .. version,
        service_id = (s.service_id as string) or "",
        codec = json_codec.new({ use_json_name = false }),
        has_event_stream_initial_message = true,
    } as awsjson_mod, awsjson_mt)
end

function awsjson_mod:serialize(input: any, operation: {string:any}): http_mod.Request, any
    local body, err = self.codec:serialize(input or {}, operation.input_schema as schema_mod.Schema)
    if err then return nil, err end

    return http_mod.new_request(
        (operation.http_method as string) or "POST",
        (operation.http_path as string) or "/",
        {
            ["Content-Type"] = self.content_type,
            ["X-Amz-Target"] = self.service_id .. "." .. (operation.name as string),
        },
        http_mod.string_reader(body)
    ), nil
end

local function parse_error_code(response: http_mod.Response, body_table: {string:any}): string
    local header = response.headers and (
        response.headers["x-amzn-errortype"] or
        response.headers["X-Amzn-Errortype"]
    )
    if header then
        return header:match("^([^:]+)") or header
    end
    if body_table then
        local code = (body_table["__type"] or body_table["code"] or body_table["Code"]) as string
        if code then
            return code:match("#(.+)$") or code
        end
    end
    return "UnknownError"
end

function awsjson_mod:deserialize(response: http_mod.Response, operation: {string:any}): any, any
    local body_str, read_err = http_mod.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local body_table: {string:any} = nil
        if body_str and #body_str > 0 then
            local raw = decoder.decode(body_str)
            if type(raw) == "table" then body_table = raw as {string:any} end
        end

        local code = parse_error_code(response, body_table)
        local message = ""
        if body_table then
            message = (body_table["message"] or body_table["Message"]
                or body_table["errorMessage"] or "") as string
        end

        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    if not body_str or #body_str == 0 then
        return {}, nil
    end

    return self.codec:deserialize(body_str, operation.output_schema as schema_mod.Schema)
end

return awsjson_mod
