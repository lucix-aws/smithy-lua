


local schema_mod = require("smithy.schema")
local stype = schema_mod.type
local t = require("smithy.traits")
local concat = table.concat
local format = string.format
local huge = math.huge

local M = { XmlNode = {} }

















local M_mt = { __index = M }

local base64 = require("smithy.base64")
local base64_encode = base64.encode
local base64_decode = base64.decode
local json_codec = require("smithy.codec.json")

function M.new(settings)
   settings = settings or {}
   return setmetatable({
      default_timestamp_format = settings.default_timestamp_format or schema_mod.timestamp.DATE_TIME,
   }, M_mt)
end

local function xml_escape(s)
   s = tostring(s)
   return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function xml_name(name, member_schema)
   if member_schema then
      local xn = member_schema:trait(t.XML_NAME)
      if xn then return xn.name end
   end
   return name
end

local function ns_attr_str(ns)
   local ns_tbl = ns
   local attr = ns_tbl.prefix and ("xmlns:" .. ns_tbl.prefix) or "xmlns"
   return " " .. attr .. '="' .. xml_escape(ns_tbl.uri) .. '"'
end

local function format_timestamp(v, schema, codec)
   local ts_format = codec.default_timestamp_format
   if schema then
      local tf = schema:trait(t.TIMESTAMP_FORMAT)
      if tf then ts_format = tf.format end
   end
   if ts_format == schema_mod.timestamp.EPOCH_SECONDS then
      if v % 1 == 0 then return format("%.0f", v) end
      return tostring(v)
   elseif ts_format == schema_mod.timestamp.HTTP_DATE then
      return json_codec._format_http_date(v)
   end
   return json_codec._format_iso8601(v)
end

local function simple_value(v, schema, codec)
   local st = schema.type
   if st == stype.BOOLEAN then return v and "true" or "false" end
   if st == stype.BLOB then return base64_encode(v) end
   if st == stype.TIMESTAMP then return format_timestamp(v, schema, codec) end
   if st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
      error("bigInteger/bigDecimal not supported in XML codec")
   end
   if st == stype.FLOAT or st == stype.DOUBLE then
      local num = v
      if num ~= num then return "NaN"
      elseif num == huge then return "Infinity"
      elseif num == -huge then return "-Infinity"
      end
   end
   if st == stype.INTEGER or st == stype.LONG or st == stype.SHORT or
      st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
      return format("%.0f", v)
   end
   return tostring(v)
end

local function encode_value(v, name, schema, buf, n, codec)
   if v == nil then return n end
   local st = schema.type

   if st == stype.STRUCTURE then
      n = n + 1; buf[n] = "<" .. name
      local xns = schema:trait(t.XML_NAMESPACE)
      if xns then
         n = n + 1; buf[n] = ns_attr_str(xns)
      end
      local members = schema:members() or {}
      for mname, ms in pairs(members) do
         if ms:trait(t.XML_ATTRIBUTE) and (v)[mname] ~= nil then
            local aname = xml_name(mname, ms)
            n = n + 1; buf[n] = " " .. aname .. '="' .. xml_escape(simple_value((v)[mname], ms, codec)) .. '"'
         end
      end
      n = n + 1; buf[n] = ">"
      local keys = {}
      for k in pairs(members) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, mname in ipairs(keys) do
         local ms = members[mname]
         if not ms:trait(t.XML_ATTRIBUTE) and (v)[mname] ~= nil then
            local ename = xml_name(mname, ms)
            n = encode_value((v)[mname], ename, ms, buf, n, codec)
         end
      end
      n = n + 1; buf[n] = "</" .. name .. ">"
      return n

   elseif st == stype.LIST then
      local elem_schema = schema.list_member
      if not elem_schema then
         local fallback = { type = stype.STRING }
         elem_schema = fallback
      end
      local flattened = schema:trait(t.XML_FLATTENED)
      local arr = v
      if flattened then
         for i = 1, #arr do
            n = encode_value(arr[i], name, elem_schema, buf, n, codec)
         end
      else
         local item_name = xml_name("member", elem_schema)
         local xns = schema:trait(t.XML_NAMESPACE)
         if xns then
            n = n + 1; buf[n] = "<" .. name .. ns_attr_str(xns) .. ">"
         else
            n = n + 1; buf[n] = "<" .. name .. ">"
         end
         for i = 1, #arr do
            n = encode_value(arr[i], item_name, elem_schema, buf, n, codec)
         end
         n = n + 1; buf[n] = "</" .. name .. ">"
      end
      return n

   elseif st == stype.MAP then
      local key_schema = schema.map_key
      if not key_schema then
         local fallback = { type = stype.STRING }
         key_schema = fallback
      end
      local val_schema = schema.map_value
      if not val_schema then
         local fallback = { type = stype.STRING }
         val_schema = fallback
      end
      local key_name = xml_name("key", key_schema)
      local val_name = xml_name("value", val_schema)
      local flattened = schema:trait(t.XML_FLATTENED)
      local entry_name = flattened and name or "entry"
      if not flattened then
         local ns_extra = ""
         local xns = schema:trait(t.XML_NAMESPACE)
         if xns then
            ns_extra = ns_attr_str(xns)
         end
         n = n + 1; buf[n] = "<" .. name .. ns_extra .. ">"
      end
      local keys = {}
      local map = v
      for k in pairs(map) do keys[#keys + 1] = k end
      table.sort(keys)
      local key_ns = key_schema:trait(t.XML_NAMESPACE)
      local key_ns_str = key_ns and ns_attr_str(key_ns) or ""
      for _, k in ipairs(keys) do
         n = n + 1; buf[n] = "<" .. entry_name .. ">"
         n = n + 1; buf[n] = "<" .. key_name .. key_ns_str .. ">" .. xml_escape(k) .. "</" .. key_name .. ">"
         n = encode_value(map[k], val_name, val_schema, buf, n, codec)
         n = n + 1; buf[n] = "</" .. entry_name .. ">"
      end
      if not flattened then
         n = n + 1; buf[n] = "</" .. name .. ">"
      end
      return n

   elseif st == stype.UNION then
      n = n + 1; buf[n] = "<" .. name .. ">"
      local members = schema:members() or {}
      for mname, ms in pairs(members) do
         if (v)[mname] ~= nil then
            local ename = xml_name(mname, ms)
            n = encode_value((v)[mname], ename, ms, buf, n, codec)
            break
         end
      end
      n = n + 1; buf[n] = "</" .. name .. ">"
      return n

   else
      local ns_extra = ""
      local xns = schema:trait(t.XML_NAMESPACE)
      if xns then
         ns_extra = ns_attr_str(xns)
      end
      n = n + 1; buf[n] = "<" .. name .. ns_extra .. ">" .. xml_escape(simple_value(v, schema, codec)) .. "</" .. name .. ">"
      return n
   end
end

function M.serialize(self, value, schema, root_name)
   root_name = root_name or (schema.id) or "root"
   local buf = {}
   local ok, n_or_err = pcall(encode_value, value, root_name, schema, buf, 0, self)
   if not ok then
      return nil, { type = "sdk", message = "xml serialize: " .. tostring(n_or_err) }
   end
   local schema_any = schema
   local target = (schema_any)._target
   if target and (n_or_err) > 0 then
      local root_ns = target:trait(t.XML_NAMESPACE)
      if root_ns then
         local ns_str = ns_attr_str(root_ns)
         buf[1] = buf[1]:gsub("^(<" .. root_name .. ")", "%1" .. ns_str, 1)
      end
   end
   return concat(buf, "", 1, n_or_err), nil
end


local function parse_xml(s)
   local pos = 1
   local len = #s

   if s:sub(1, 5) == "<?xml" then
      local found = s:find("?>", 1, true)
      if found then pos = found + 2 end
   end

   local function skip_ws()
      local _, e = s:find("^%s+", pos)
      if e then pos = e + 1 end
   end

   local function parse_node()
      if pos > len then return nil end

      if s:byte(pos) ~= 0x3C then
         local text_end = s:find("<", pos, true)
         if not text_end then
            local txt = s:sub(pos)
            pos = len + 1
            return txt
         end
         local txt = s:sub(pos, text_end - 1)
         pos = text_end
         return txt
      end

      if s:sub(pos, pos + 1) == "</" then return nil end

      local tag_end = s:find("[%s/>]", pos + 1)
      if not tag_end then return nil end
      local tag = s:sub(pos + 1, tag_end - 1)

      pos = tag_end
      local attrs = {}
      while true do
         skip_ws()
         if pos > len then break end
         local c = s:byte(pos)
         if c == 0x2F then
            pos = pos + 2
            local node = { tag = tag, attrs = attrs, children = {}, text = "" }
            return node
         elseif c == 0x3E then
            pos = pos + 1
            break
         else
            local aname_end = s:find("[=%s]", pos)
            if not aname_end then break end
            local aname = s:sub(pos, aname_end - 1)
            pos = aname_end
            skip_ws()
            if s:byte(pos) == 0x3D then pos = pos + 1 end
            skip_ws()
            local q = s:byte(pos)
            pos = pos + 1
            local val_end = s:find(string.char(q), pos, true)
            if val_end then
               attrs[aname] = s:sub(pos, val_end - 1)
               pos = val_end + 1
            end
         end
      end

      local children = {}
      local texts = {}
      while pos <= len do
         local ws_end = s:find("%S", pos)
         if ws_end and s:byte(ws_end) == 0x3C and s:sub(ws_end, ws_end + 1) ~= "</" then
            pos = ws_end
         end
         if pos > len then break end
         if s:sub(pos, pos + 1) == "</" then
            local close_end = s:find(">", pos, true)
            if close_end then pos = close_end + 1 end
            break
         end
         if s:sub(pos, pos + 8) == "<![CDATA[" then
            pos = pos + 9
            local cdata_end = s:find("]]>", pos, true)
            if cdata_end then
               texts[#texts + 1] = s:sub(pos, cdata_end - 1)
               pos = cdata_end + 3
            end
         elseif s:sub(pos, pos + 3) == "<!--" then
            local comment_end = s:find("-->", pos, true)
            if comment_end then pos = comment_end + 3 end
         else
            local child = parse_node()
            if child == nil then break end
            if type(child) == "string" then
               texts[#texts + 1] = child
            else
               children[#children + 1] = child
            end
         end
      end

      local node = { tag = tag, attrs = attrs, children = children, text = table.concat(texts) }
      return node
   end

   skip_ws()
   return parse_node()
end

local xml_entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
local function xml_unescape(s)
   return (s:gsub("&(%w+);", function(e) return xml_entities[e] or ("&" .. e .. ";") end):
   gsub("&#(%d+);", function(n_str) return string.char(tonumber(n_str)) end):
   gsub("&#x(%x+);", function(n_str) return string.char(tonumber(n_str, 16)) end))
end

local function decode_simple(text, schema, codec)
   text = xml_unescape(text)
   local st = schema.type
   if st == stype.BOOLEAN then return text == "true" end
   if st == stype.BLOB then return base64_decode(text) end
   if st == stype.BIG_INTEGER or st == stype.BIG_DECIMAL then
      error("bigInteger/bigDecimal not supported in XML codec")
   end
   if st == stype.TIMESTAMP then
      local n = tonumber(text)
      if n then return n end
      local ts_format = codec.default_timestamp_format
      local tf = schema:trait(t.TIMESTAMP_FORMAT)
      if tf then ts_format = tf.format end
      if ts_format == schema_mod.timestamp.HTTP_DATE then
         return json_codec._parse_http_date(text)
      end
      return json_codec._parse_iso8601(text)
   end
   if st == stype.INTEGER or st == stype.LONG or st == stype.SHORT or
      st == stype.BYTE or st == stype.INT_ENUM or st == "number" then
      return tonumber(text)
   end
   if st == stype.FLOAT or st == stype.DOUBLE then
      if text == "NaN" then return 0 / 0
      elseif text == "Infinity" then return huge
      elseif text == "-Infinity" then return -huge
      end
      return tonumber(text)
   end
   return text
end

local function decode_node(node, schema, codec)
   if not node then return nil end
   local st = schema.type

   if st == stype.STRUCTURE then
      local result = {}
      local members = schema:members() or {}
      local by_xml = {}
      for mname, ms in pairs(members) do
         local xn = xml_name(mname, ms)
         local entry = { mname, ms }
         by_xml[xn] = entry
      end
      if node.attrs then
         for aname, aval in pairs(node.attrs) do
            if not aname:match("^xmlns") then
               local entry = by_xml[aname]
               if entry and (entry[2]):trait(t.XML_ATTRIBUTE) then
                  result[entry[1]] = decode_simple(aval, entry[2], codec)
               end
            end
         end
      end
      local children_by_tag = {}
      for _, child in ipairs(node.children or {}) do
         if not children_by_tag[child.tag] then
            children_by_tag[child.tag] = {}
         end
         local tbl = children_by_tag[child.tag]
         tbl[#tbl + 1] = child
      end
      for ename, children in pairs(children_by_tag) do
         local entry = by_xml[ename]
         if entry then
            local ms = entry[2]
            if ms.type == stype.LIST and ms:trait(t.XML_FLATTENED) then
               local list = {}
               local elem_schema = ms.list_member
               if not elem_schema then
                  local fallback = { type = stype.STRING }
                  elem_schema = fallback
               end
               for _, child in ipairs(children) do
                  list[#list + 1] = decode_node(child, elem_schema, codec)
               end
               result[entry[1]] = list
            elseif ms.type == stype.MAP and ms:trait(t.XML_FLATTENED) then
               local map = (result[entry[1]]) or {}
               local key_schema = ms.map_key
               if not key_schema then
                  local fallback = { type = stype.STRING }
                  key_schema = fallback
               end
               local val_schema = ms.map_value
               if not val_schema then
                  local fallback = { type = stype.STRING }
                  val_schema = fallback
               end
               local kn = xml_name("key", key_schema)
               local vn = xml_name("value", val_schema)
               for _, child in ipairs(children) do
                  local k
                  local val
                  for _, gc in ipairs(child.children or {}) do
                     if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
                     if gc.tag == vn then val = decode_node(gc, val_schema, codec) end
                  end
                  if k then map[k] = val end
               end
               result[entry[1]] = map
            else
               result[entry[1]] = decode_node(children[1], ms, codec)
            end
         end
      end
      return result

   elseif st == stype.LIST then
      local elem_schema = schema.list_member
      if not elem_schema then
         local fallback = { type = stype.STRING }
         elem_schema = fallback
      end
      local item_name = xml_name("member", elem_schema)
      local result = {}
      for _, child in ipairs(node.children or {}) do
         if child.tag == item_name then
            result[#result + 1] = decode_node(child, elem_schema, codec)
         end
      end
      return result

   elseif st == stype.MAP then
      local key_schema = schema.map_key
      if not key_schema then
         local fallback = { type = stype.STRING }
         key_schema = fallback
      end
      local val_schema = schema.map_value
      if not val_schema then
         local fallback = { type = stype.STRING }
         val_schema = fallback
      end
      local kn = xml_name("key", key_schema)
      local vn = xml_name("value", val_schema)
      local result = {}
      for _, child in ipairs(node.children or {}) do
         if child.tag == "entry" then
            local k
            local val
            for _, gc in ipairs(child.children or {}) do
               if gc.tag == kn then k = decode_simple(gc.text, key_schema, codec) end
               if gc.tag == vn then val = decode_node(gc, val_schema, codec) end
            end
            if k then result[k] = val end
         end
      end
      return result

   elseif st == stype.UNION then
      local members = schema:members() or {}
      local by_xml = {}
      for mname, ms in pairs(members) do
         local xn = xml_name(mname, ms)
         local entry = { mname, ms }
         by_xml[xn] = entry
      end
      local result = {}
      for _, child in ipairs(node.children or {}) do
         local entry = by_xml[child.tag]
         if entry then
            result[entry[1]] = decode_node(child, entry[2], codec)
            break
         end
      end
      return result

   else
      return decode_simple(node.text or "", schema, codec)
   end
end

function M.deserialize(self, bytes, schema, _root_name)
   if not bytes or #bytes == 0 then return {}, nil end
   local ok, node = pcall(parse_xml, bytes)
   if not ok then
      return nil, { type = "sdk", message = "xml parse: " .. tostring(node) }
   end
   if not node then
      return nil, { type = "sdk", message = "xml parse: empty document" }
   end
   return decode_node(node, schema, self), nil
end

M.parse_xml = parse_xml
M.xml_unescape = xml_unescape
M.xml_escape = xml_escape
M.decode_node = decode_node

return M
