-- smithy-lua runtime: awsJson1.0 / awsJson1.1 protocol
-- Implements the ClientProtocol interface (serialize + deserialize).

local json_codec = require("codec.json")
local http = require("http")

local M = {}
M.__index = M

--- Create a new awsJson protocol instance.
--- @param settings table: { version = "1.0"|"1.1", service_id = string }
--- @return table: protocol with serialize/deserialize
function M.new(settings)
    local version = settings and settings.version or "1.0"
    return setmetatable({
        content_type = "application/x-amz-json-" .. version,
        service_id = settings and settings.service_id or "",
        -- awsJson does NOT use json_name — member names go on the wire as-is
        codec = json_codec.new({ use_json_name = false }),
    }, M)
end

--- Serialize modeled input into an HTTP request.
--- @param self table: protocol instance
--- @param input table: user input
--- @param operation table: codegen operation metadata
--- @return table, table: HTTP request, err
function M.serialize(self, input, operation)
    local body, err = self.codec:serialize(input or {}, operation.input_schema)
    if err then return nil, err end

    return http.new_request(
        operation.http_method or "POST",
        operation.http_path or "/",
        {
            ["Content-Type"] = self.content_type,
            ["X-Amz-Target"] = self.service_id .. "." .. operation.name,
        },
        http.string_reader(body)
    ), nil
end

--- Extract error code from response.
--- Checks x-amzn-errortype header first, then __type in body.
local function parse_error_code(response, body_table)
    -- Header takes precedence
    local header = response.headers and (
        response.headers["x-amzn-errortype"] or
        response.headers["X-Amzn-Errortype"]
    )
    if header then
        -- Strip anything after ':' (e.g. "ValidationException:http://...")
        return header:match("^([^:]+)") or header
    end
    -- Fall back to body
    if body_table then
        local code = body_table["__type"] or body_table["code"] or body_table["Code"]
        if code then
            -- __type may be a full shape ID like "com.amazonaws.sqs#QueueDoesNotExist"
            return code:match("#(.+)$") or code
        end
    end
    return "UnknownError"
end

--- Deserialize an HTTP response into modeled output or an error.
--- @param self table: protocol instance
--- @param response table: HTTP response
--- @param operation table: codegen operation metadata
--- @return table, table: output, err
function M.deserialize(self, response, operation)
    local body_str, read_err = http.read_all(response.body)
    if read_err then
        return nil, { type = "http", code = "ResponseReadError", message = read_err }
    end

    -- Error response
    if response.status_code < 200 or response.status_code >= 300 then
        local body_table = nil
        if body_str and #body_str > 0 then
            -- Parse as raw JSON (no schema) for error fields
            local raw = require("json.decoder").decode(body_str)
            if type(raw) == "table" then body_table = raw end
        end

        local code = parse_error_code(response, body_table)
        local message = ""
        if body_table then
            message = body_table["message"] or body_table["Message"]
                or body_table["errorMessage"] or ""
        end

        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    -- Success: empty body is valid (e.g. DeleteQueue returns nothing)
    if not body_str or #body_str == 0 or body_str == "{}" then
        return {}, nil
    end

    return self.codec:deserialize(body_str, operation.output_schema)
end

return M
