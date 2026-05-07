

local json_codec = require("smithy.codec.json")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local rest = require("smithy.protocol.rest")

local M = {}






local M_mt = { __index = M }

function M.new(_settings)
   return setmetatable({
      codec = json_codec.new({
         use_json_name = true,
         default_timestamp_format = schema_mod.timestamp.EPOCH_SECONDS,
      }),
      has_event_stream_initial_message = false,
   }, M_mt)
end

function M:serialize(input, _service, operation)
   input = input or {}
   local schema = operation.input

   local labels, query, headers, payload_name, payload_schema, body_members =
   rest.bind_request(input, schema)

   if not headers["Content-Type"] then
      headers["Content-Type"] = "application/json"
   end

   local url, method = rest.build_url(operation, labels, query)

   local body_str
   if payload_name then
      local v = input[payload_name]
      if v == nil then
         if payload_schema.type == "structure" then
            body_str = "{}"
         else
            body_str = ""
         end
      elseif payload_schema.type == "structure" or payload_schema.type == "union" then
         local err
         body_str, err = self.codec:serialize(v, payload_schema)
         if err then return nil, err end
      elseif payload_schema.type == "document" then
         body_str = require("smithy.json.encoder").encode(v)
      elseif payload_schema.type == "blob" then
         body_str = v
         if headers["Content-Type"] == "application/json" then
            local mt = payload_schema:trait(t.MEDIA_TYPE)
            headers["Content-Type"] = mt and mt.value or "application/octet-stream"
         end
      elseif payload_schema.type == "string" or payload_schema.type == "enum" then
         body_str = tostring(v)
         headers["Content-Type"] = "text/plain"
      else
         body_str = tostring(v)
      end
   else
      local has_body = false
      for name in pairs(body_members) do
         if input[name] ~= nil then has_body = true; break end
      end
      if has_body then
         local body_schema = schema_mod.new({ type = schema_mod.type.STRUCTURE, members = body_members })
         local err
         body_str, err = self.codec:serialize(input, body_schema)
         if err then return nil, err end
      elseif next(body_members) then
         body_str = "{}"
      else
         body_str = ""
         headers["Content-Type"] = nil
      end
   end

   return http.new_request(method, url, headers, http.string_reader(body_str)), nil
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
   local schema = operation.output
   local streaming = rest.has_streaming_payload(schema)

   local body_str
   local read_err
   if streaming and response.status_code >= 200 and response.status_code < 300 then
      body_str = nil
   else
      body_str, read_err = http.read_all(response.body)
      if read_err then
         local e = { type = "http", code = "ResponseReadError", message = read_err }
         return nil, e
      end
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

   local output, payload_name, payload_schema, body_members =
   rest.bind_response(response, schema)

   if payload_name then
      if payload_schema:trait(t.STREAMING) then
         output[payload_name] = response.body
      elseif body_str and #body_str > 0 then
         if payload_schema.type == "structure" or payload_schema.type == "union" then
            local v, err = self.codec:deserialize(body_str, payload_schema)
            if err then return nil, err end
            output[payload_name] = v
         elseif payload_schema.type == "document" then
            output[payload_name] = require("smithy.json.decoder").decode(body_str)
         elseif payload_schema.type == "blob" or payload_schema.type == "string" then
            output[payload_name] = body_str
         else
            output[payload_name] = body_str
         end
      end
   elseif body_str and #body_str > 0 then
      local body_schema = schema_mod.new({ type = schema_mod.type.STRUCTURE, members = body_members })
      local decoded, err = self.codec:deserialize(body_str, body_schema)
      if err then return nil, err end
      for k, v in pairs(decoded) do
         output[k] = v
      end
   end

   return output, nil
end

return M
