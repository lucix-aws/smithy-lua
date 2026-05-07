

local xml_codec = require("smithy.codec.xml")
local base64 = require("smithy.base64")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local stype = schema_mod.type

local M = {}







local M_mt = { __index = M }

function M.new(settings)
   settings = settings or {}
   return setmetatable({
      version = settings.version or "",
      xml = xml_codec.new({ default_timestamp_format = schema_mod.timestamp.DATE_TIME }),
      ec2 = settings.ec2 or false,
   }, M_mt)
end

local function pct_encode(s)
   return (tostring(s):gsub("[^A-Za-z0-9_.~-]", function(c)
      return string.format("%%%02X", c:byte())
   end))
end

local function capitalize(s)
   if #s == 0 then return s end
   return s:sub(1, 1):upper() .. s:sub(2)
end

local function query_key(name, ms, ec2)
   if ec2 then
      local ec2qn = ms:trait(t.EC2_QUERY_NAME)
      if ec2qn then return ec2qn.name end
      local xn = ms:trait(t.XML_NAME)
      if xn then return capitalize(xn.name) end
      return capitalize(name)
   else
      local xn = ms:trait(t.XML_NAME)
      if xn then return xn.name end
      return name
   end
end

local function serialize_query(v, prefix, schema, params, ec2)
   if v == nil then return end
   local st = schema.type

   if st == stype.STRUCTURE then
      local members = schema:members()
      for mname, ms in pairs(members) do
         local tbl = v
         if tbl[mname] ~= nil then
            local key = query_key(mname, ms, ec2)
            serialize_query(tbl[mname], prefix == "" and key or (prefix .. "." .. key), ms, params, ec2)
         end
      end

   elseif st == stype.LIST then
      local elem_schema = schema.list_member or schema_mod.new({ type = stype.STRING })
      local flattened = ec2 or schema:trait(t.XML_FLATTENED)
      local list = v
      if #list == 0 and not ec2 then
         params[#params + 1] = pct_encode(prefix) .. "="
      elseif flattened then
         for i = 1, #list do
            serialize_query(list[i], prefix .. "." .. i, elem_schema, params, ec2)
         end
      else
         local member_label = "member"
         local xn = elem_schema:trait(t.XML_NAME)
         if xn then
            member_label = xn.name
         end
         for i = 1, #list do
            serialize_query(list[i], prefix .. "." .. member_label .. "." .. i, elem_schema, params, ec2)
         end
      end

   elseif st == stype.MAP then
      local key_schema = schema.map_key or schema_mod.new({ type = stype.STRING })
      local val_schema = schema.map_value or schema_mod.new({ type = stype.STRING })
      local flattened = schema:trait(t.XML_FLATTENED)
      local key_xn = key_schema:trait(t.XML_NAME)
      local val_xn = val_schema:trait(t.XML_NAME)
      local key_label = key_xn and key_xn.name or "key"
      local val_label = val_xn and val_xn.name or "value"
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      for i, k in ipairs(keys) do
         local entry_prefix
         if flattened then
            entry_prefix = prefix .. "." .. i
         else
            entry_prefix = prefix .. ".entry." .. i
         end
         params[#params + 1] = pct_encode(entry_prefix .. "." .. key_label) .. "=" .. pct_encode(k)
         serialize_query((v)[k], entry_prefix .. "." .. val_label, val_schema, params, ec2)
      end
      return

   elseif st == stype.BOOLEAN then
      params[#params + 1] = pct_encode(prefix) .. "=" .. ((v) and "true" or "false")
      return

   elseif st == stype.BLOB then
      local b64 = base64.encode(v)
      params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(b64)
      return

   elseif st == stype.TIMESTAMP then
      local ts_format = schema_mod.timestamp.DATE_TIME
      local ts_trait = schema:trait(t.TIMESTAMP_FORMAT)
      if ts_trait then
         ts_format = ts_trait.format
      end
      local formatted
      local n = v
      if ts_format == schema_mod.timestamp.EPOCH_SECONDS then
         if n % 1 == 0 then
            formatted = string.format("%.0f", n)
         else
            formatted = tostring(n)
         end
      elseif ts_format == schema_mod.timestamp.HTTP_DATE then
         formatted = require("smithy.codec.json")._format_http_date(n)
      else
         formatted = require("smithy.codec.json")._format_iso8601(n)
      end
      params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(formatted)
      return

   elseif st == stype.FLOAT or st == stype.DOUBLE then
      local n = v
      local s
      if n ~= n then s = "NaN"
      elseif n == math.huge then s = "Infinity"
      elseif n == -math.huge then s = "-Infinity"
      else s = tostring(n) end
      params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(s)
      return

   elseif st == stype.INTEGER or st == stype.LONG or st == stype.SHORT or
      st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
      params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(string.format("%.0f", v))
      return

   elseif st == "document" and type(v) == "table" then
      local tbl = v
      if #(v) > 0 then
         local list = v
         for i = 1, #list do
            serialize_query(list[i], prefix .. ".member." .. i, schema_mod.new({ type = stype.STRING }), params, ec2)
         end
      else
         local keys = {}
         for k in pairs(tbl) do keys[#keys + 1] = k end
         table.sort(keys)
         for i, k in ipairs(keys) do
            local entry_prefix = prefix .. ".entry." .. i
            params[#params + 1] = pct_encode(entry_prefix .. ".key") .. "=" .. pct_encode(k)
            serialize_query(tbl[k], entry_prefix .. ".value", schema_mod.new({ type = stype.STRING }), params, ec2)
         end
      end
      return

   else
      params[#params + 1] = pct_encode(prefix) .. "=" .. pct_encode(tostring(v))
      return
   end
end

function M:serialize(input, _service, operation)
   input = input or {}

   local schema = operation.input
   if schema and schema:members() then
      for mname, ms in pairs(schema:members()) do
         if input[mname] == nil and ms:trait(t.IDEMPOTENCY_TOKEN) then
            input[mname] = "00000000-0000-4000-8000-000000000000"
         end
      end
   end

   local op_id = operation.id
   local prefix_parts = {
      "Action=" .. pct_encode(op_id.name),
      "Version=" .. pct_encode(self.version),
   }

   local params = {}
   if schema and schema:members() then
      serialize_query(input, "", schema, params, self.ec2)
   end

   table.sort(params)
   local body
   if #params > 0 then
      body = table.concat(prefix_parts, "&") .. "&" .. table.concat(params, "&")
   else
      body = table.concat(prefix_parts, "&")
   end

   local http_trait = operation:trait(t.HTTP)
   local hdrs = {}
   hdrs["Content-Type"] = "application/x-www-form-urlencoded"
   return http.new_request(
   "POST",
   http_trait and http_trait.path or "/",
   hdrs,
   http.string_reader(body)),
   nil
end

local function parse_awsquery_error(body_str)
   if not body_str or #body_str == 0 then return "UnknownError", "" end
   local node = xml_codec.parse_xml(body_str)
   if not node then return "UnknownError", "" end

   local error_node
   for _, child in ipairs(node.children or {}) do
      if child.tag == "Error" then error_node = child; break end
   end

   local code, message = "UnknownError", ""
   if error_node then
      for _, child in ipairs(error_node.children or {}) do
         if child.tag == "Code" then code = child.text or code end
         if child.tag == "Message" or child.tag == "message" then message = child.text or message end
      end
   end
   return code, message
end

local function parse_ec2query_error(body_str)
   if not body_str or #body_str == 0 then return "UnknownError", "" end
   local node = xml_codec.parse_xml(body_str)
   if not node then return "UnknownError", "" end

   local errors_node
   for _, child in ipairs(node.children or {}) do
      if child.tag == "Errors" then errors_node = child; break end
   end
   local error_node
   if errors_node then
      for _, child in ipairs(errors_node.children or {}) do
         if child.tag == "Error" then error_node = child; break end
      end
   end

   local code, message = "UnknownError", ""
   if error_node then
      for _, child in ipairs(error_node.children or {}) do
         if child.tag == "Code" then code = child.text or code end
         if child.tag == "Message" or child.tag == "message" then message = child.text or message end
      end
   end
   return code, message
end

function M:deserialize(response, operation)
   local body_str, read_err = http.read_all(response.body)
   if read_err then
      local e = { type = "http", code = "ResponseReadError", message = read_err }
      return nil, e
   end

   if response.status_code < 200 or response.status_code >= 300 then
      local code
      local message
      if self.ec2 then
         code, message = parse_ec2query_error(body_str)
      else
         code, message = parse_awsquery_error(body_str)
      end
      local output_schema = operation.output
      if output_schema and output_schema.id and output_schema:trait(t.ERROR) then
         local oid = output_schema.id
         code = oid.name
      end
      local e = {
         type = "api",
         code = code,
         message = message,
         status_code = response.status_code,
      }
      return nil, e
   end

   if not body_str or #body_str == 0 then return {}, nil end

   local node = xml_codec.parse_xml(body_str)
   if not node then return {}, nil end

   local result_node
   if self.ec2 then
      result_node = node
   else
      local op_id = operation.id
      local result_tag = op_id.name .. "Result"
      for _, child in ipairs(node.children or {}) do
         if child.tag == result_tag then result_node = child; break end
      end
      if not result_node then result_node = node end
   end

   local output_schema = operation.output
   if not output_schema or not output_schema:members() then return {}, nil end

   local result = xml_codec.decode_node(result_node, output_schema, self.xml)
   return result, nil
end

return M
