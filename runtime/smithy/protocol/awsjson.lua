

local json_codec = require("smithy.codec.json")
local http = require("smithy.http")
local t = require("smithy.traits")
local schema_mod = require("smithy.schema")

local M = {}








local M_mt = { __index = M }

function M.new(settings)
   local s = settings
   if type(settings) == "string" then
      s = { version = settings }
   end
   local version = s and s.version or "1.0"
   return setmetatable({
      content_type = "application/x-amz-json-" .. version,
      service_id = s and s.service_id or "",
      codec = json_codec.new({ use_json_name = false }),
      has_event_stream_initial_message = true,
   }, M_mt)
end

function M:serialize(input, service, operation)
   local body, err = self.codec:serialize(input or {}, operation.input)
   if err then return nil, err end

   local http_trait = operation:trait(t.HTTP)
   local service_id = service.id
   local op_id = operation.id
   local target = service_id.name .. "." .. op_id.name
   local ct = self.content_type
   local meth = http_trait and http_trait.method or "POST"
   local path = http_trait and http_trait.path or "/"
   local hdrs = {}
   hdrs["Content-Type"] = ct
   hdrs["X-Amz-Target"] = target
   return http.new_request(meth, path, hdrs, http.string_reader(body)), nil
end

local function parse_error_code(response, body_table)
   local header = response.headers and (
   response.headers["x-amzn-errortype"] or
   response.headers["X-Amzn-Errortype"])

   if header then
      return header:match("^([^:]+)") or header
   end
   if body_table then
      local code = body_table["__type"] or body_table["code"] or body_table["Code"]
      if code then
         local s = code
         return s:match("#(.+)$") or s
      end
   end
   return "UnknownError"
end

function M:deserialize(response, operation)
   local body_str, read_err = http.read_all(response.body)
   if read_err then
      local e = { type = "http", code = "ResponseReadError", message = read_err }
      return nil, e
   end

   if response.status_code < 200 or response.status_code >= 300 then
      local body_table
      if body_str and #body_str > 0 then
         local raw = require("smithy.json.decoder").decode(body_str)
         if type(raw) == "table" then body_table = raw end
      end

      local code = parse_error_code(response, body_table)
      local message = ""
      if body_table then
         message = (body_table["message"] or body_table["Message"] or
         body_table["errorMessage"] or "")
      end

      local e = {
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
   if err then return nil, err end
   return result, nil
end

return M
