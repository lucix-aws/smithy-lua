

local json_codec = require("smithy.codec.json")
local http_mod = require("smithy.http")
local schema_mod = require("smithy.schema")
local decoder = require("smithy.json.decoder")

local awsjson_mod = {}






local awsjson_mt = { __index = awsjson_mod }

function awsjson_mod.new(settings)
   local s
   if type(settings) == "string" then
      s = { version = settings }
   else
      s = (settings) or {}
   end
   local version = (s.version) or "1.0"
   return setmetatable({
      content_type = "application/x-amz-json-" .. version,
      service_id = (s.service_id) or "",
      codec = json_codec.new({ use_json_name = false }),
      has_event_stream_initial_message = true,
   }, awsjson_mt)
end

function awsjson_mod:serialize(input, operation)
   local body, err = self.codec:serialize(input or {}, operation.input_schema)
   if err then return nil, err end

   return http_mod.new_request(
   (operation.http_method) or "POST",
   (operation.http_path) or "/",
   {
      ["Content-Type"] = self.content_type,
      ["X-Amz-Target"] = self.service_id .. "." .. (operation.name),
   },
   http_mod.string_reader(body)),
   nil
end

local function parse_error_code(response, body_table)
   local header = response.headers and (
   response.headers["x-amzn-errortype"] or
   response.headers["X-Amzn-Errortype"])

   if header then
      return header:match("^([^:]+)") or header
   end
   if body_table then
      local code = (body_table["__type"] or body_table["code"] or body_table["Code"])
      if code then
         return code:match("#(.+)$") or code
      end
   end
   return "UnknownError"
end

function awsjson_mod:deserialize(response, operation)
   local body_str, read_err = http_mod.read_all(response.body)
   if read_err then
      return nil, { type = "http", code = "ResponseReadError", message = read_err }
   end

   if response.status_code < 200 or response.status_code >= 300 then
      local body_table = nil
      if body_str and #body_str > 0 then
         local raw = decoder.decode(body_str)
         if type(raw) == "table" then body_table = raw end
      end

      local code = parse_error_code(response, body_table)
      local message = ""
      if body_table then
         message = (body_table["message"] or body_table["Message"] or
         body_table["errorMessage"] or "")
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

   return self.codec:deserialize(body_str, operation.output_schema)
end

return awsjson_mod
