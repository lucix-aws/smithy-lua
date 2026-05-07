local partitions = require("smithy.endpoint.partitions")

local M = {}



local UNSET = {}





local function get_attr(obj, path)
   local cur = obj
   for part in (path):gmatch("[^.]+") do
      if cur == nil then return nil end
      local key, idx_str = part:match("^(.-)%[(-?%d+)%]$")
      if key then
         if key ~= "" then cur = (cur)[key] end
         local idx = tonumber(idx_str)
         if idx < 0 then
            idx = #(cur) + idx + 1
         else
            idx = idx + 1
         end
         cur = (cur)[idx]
      else
         cur = (cur)[part]
      end
   end
   return cur
end

local function resolve_template(tmpl, scope)
   if type(tmpl) ~= "string" then return tmpl end
   return ((tmpl):gsub("{([^}]+)}", function(expr)
      local ref, attr = expr:match("^([^#]+)#(.+)$")
      if ref then
         local val = scope[ref]
         if val == nil or val == UNSET then return "" end
         local result = get_attr(val, attr)
         return result ~= nil and tostring(result) or ""
      end
      local val = scope[expr]
      if val == nil or val == UNSET then return "" end
      return tostring(val)
   end))
end





local function fn_isSet(args)
   return args[1] ~= nil and args[1] ~= UNSET
end

local function fn_not(args)
   return not args[1]
end

local function fn_booleanEquals(args)
   return args[1] == args[2]
end

local function fn_stringEquals(args)
   return args[1] == args[2]
end

local function fn_getAttr(args)
   return get_attr(args[1], args[2])
end

local function fn_isValidHostLabel(args)
   local value = args[1]
   local allow_sub = args[2]
   if type(args[1]) ~= "string" or value == "" then return false end
   if allow_sub then
      for seg in value:gmatch("[^.]+") do
         if not seg:match("^[a-zA-Z0-9][-a-zA-Z0-9]*$") or #seg > 63 then
            return false
         end
      end
      return true
   end
   return value:match("^[a-zA-Z0-9][-a-zA-Z0-9]*$") ~= nil and #value <= 63
end

local function fn_parseURL(args)
   local url = args[1]
   if type(args[1]) ~= "string" then return nil end
   if url:find("?", 1, true) then return nil end
   if url:find("#", 1, true) then return nil end

   local scheme, rest = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://(.+)$")
   if not scheme then return nil end
   scheme = scheme:lower()

   local authority
   local path
   local slash_pos = rest:find("/", 1, true)
   if slash_pos then
      authority = rest:sub(1, slash_pos - 1)
      path = rest:sub(slash_pos)
   else
      authority = rest
      path = ""
   end

   local normalized = path
   if normalized == "" then
      normalized = "/"
   else
      if normalized:sub(1, 1) ~= "/" then
         normalized = "/" .. normalized
      end
      if normalized:sub(-1) ~= "/" then
         normalized = normalized .. "/"
      end
   end

   local is_ip = false
   local host = authority:match("^%[(.+)%]")
   if host then
      is_ip = true
   else
      host = authority:match("^([^:]+)")
      if host and host:match("^%d+%.%d+%.%d+%.%d+$") then
         is_ip = true
      end
   end

   return {
      scheme = scheme,
      authority = authority,
      path = path,
      normalizedPath = normalized,
      isIp = is_ip,
   }
end

local function fn_substring(args)
   local input = args[1]
   local start_idx = args[2]
   local end_idx = args[3]
   local reverse = args[4]
   if type(args[1]) ~= "string" then return nil end
   if input:match("[\128-\255]") then return nil end
   local len = #input
   if end_idx - start_idx <= 0 then return nil end
   if reverse then
      local orig_start = start_idx
      start_idx = len - end_idx
      end_idx = len - orig_start
   end
   if start_idx < 0 or end_idx > len then return nil end
   return input:sub(start_idx + 1, end_idx)
end

local function fn_uriEncode(args)
   local s = args[1]
   if type(args[1]) ~= "string" then return "" end
   return (s:gsub("([^A-Za-z0-9%-_.~])", function(c)
      return string.format("%%%02X", string.byte(c))
   end))
end

local function fn_split(args)
   local value = args[1]
   local delimiter = args[2]
   local limit = args[3]
   if type(args[1]) ~= "string" or type(args[2]) ~= "string" or delimiter == "" then
      return {}
   end
   local result = {}
   local pos = 1
   local dlen = #delimiter
   local splits = 0
   while true do
      if limit > 0 and splits >= limit - 1 then
         result[#result + 1] = value:sub(pos)
         break
      end
      local i = value:find(delimiter, pos, true)
      if not i then
         result[#result + 1] = value:sub(pos)
         break
      end
      result[#result + 1] = value:sub(pos, i - 1)
      pos = i + dlen
      splits = splits + 1
   end
   return result
end

local function fn_coalesce(args)
   for i = 1, #args - 1 do
      if args[i] ~= nil and args[i] ~= UNSET then
         return args[i]
      end
   end
   return args[#args]
end

local function fn_ite(args)
   if args[1] then return args[2] else return args[3] end
end





local function fn_aws_partition(args)
   local region = args[1]
   if type(args[1]) ~= "string" or region == "" then return nil end
   return partitions.get_partition(region)
end

local function fn_aws_parseArn(args)
   local value = args[1]
   if type(args[1]) ~= "string" then return nil end
   local parts = {}
   for part in (value .. ":"):gmatch("([^:]*):") do
      parts[#parts + 1] = part
   end
   if #parts < 6 then return nil end
   if parts[1] ~= "arn" then return nil end
   if parts[2] == "" or parts[3] == "" then return nil end

   local resource_str = table.concat(parts, ":", 6)
   if resource_str == "" then return nil end
   local resource_id = {}
   local offset = 1
   while offset <= #resource_str + 1 do
      local i = resource_str:find("[:/]", offset)
      if not i then
         resource_id[#resource_id + 1] = resource_str:sub(offset)
         break
      end
      resource_id[#resource_id + 1] = resource_str:sub(offset, i - 1)
      offset = i + 1
   end

   return {
      partition = parts[2],
      service = parts[3],
      region = parts[4],
      accountId = parts[5],
      resourceId = resource_id,
   }
end

local function fn_aws_isVirtualHostableS3Bucket(args)
   local value = args[1]
   local allow_sub = args[2]
   if type(args[1]) ~= "string" or #value < 3 then return false end
   if value:find("..", 1, true) then return false end
   if value:match("^%d+%.%d+%.%d+%.%d+$") then return false end

   local check_segment = function(seg)
      if #seg == 0 or #seg > 63 then return false end
      if not seg:match("^[a-z0-9][-a-z0-9]*[a-z0-9]$") and not seg:match("^[a-z0-9]$") then
         return false
      end
      return true
   end

   if allow_sub then
      for seg in value:gmatch("[^.]+") do
         if not check_segment(seg) then return false end
      end
      return true
   end
   return check_segment(value)
end






local _isSet = fn_isSet
local _not = fn_not
local _booleanEquals = fn_booleanEquals
local _stringEquals = fn_stringEquals
local _isValidHostLabel = fn_isValidHostLabel
local _parseURL = fn_parseURL
local _substring = fn_substring
local _uriEncode = fn_uriEncode
local _split = fn_split
local _aws_partition = fn_aws_partition
local _aws_parseArn = fn_aws_parseArn
local _aws_isVirtualHostableS3Bucket = fn_aws_isVirtualHostableS3Bucket

local functions = {
   isSet = _isSet,
   ["not"] = _not,
   booleanEquals = _booleanEquals,
   stringEquals = _stringEquals,
   getAttr = fn_getAttr,
   isValidHostLabel = _isValidHostLabel,
   parseURL = _parseURL,
   substring = _substring,
   uriEncode = _uriEncode,
   split = _split,
   coalesce = fn_coalesce,
   ite = fn_ite,
   ["aws.partition"] = _aws_partition,
   ["aws.parseArn"] = _aws_parseArn,
   ["aws.isVirtualHostableS3Bucket"] = _aws_isVirtualHostableS3Bucket,
}





local function resolve_arg(arg, scope)
   if type(arg) == "table" then
      local t = arg
      if (t)["ref"] then
         local val = scope[(t)["ref"]]
         if val == UNSET then return nil end
         return val
      end
      if (t)["fn"] then
         return M._call_fn((t)["fn"], (t)["argv"], scope)
      end
   end
   if type(arg) == "string" then
      return resolve_template(arg, scope)
   end
   return arg
end

function M._call_fn(name, argv, scope)
   local fn = functions[name]
   if not fn then
      error("unknown endpoint rules function: " .. tostring(name))
   end
   local resolved = {}
   if name == "isSet" then
      local a = argv[1]
      if type(a) == "table" and (a)["ref"] then
         local val = scope[(a)["ref"]]
         if val ~= nil and val ~= UNSET then
            resolved[1] = val
         else
            resolved[1] = nil
         end
      else
         resolved[1] = resolve_arg(a, scope)
      end
   else
      for i, a in ipairs(argv) do
         resolved[i] = resolve_arg(a, scope)
      end
   end
   return fn(resolved)
end





local function eval_conditions(conditions, scope)
   if not conditions then return true end
   for _, cond_any in ipairs(conditions) do
      local cond = cond_any
      local result = M._call_fn(cond["fn"], cond["argv"], scope)
      if not result and result ~= false then
         return false
      end
      if result == false then
         return false
      end
      if cond["assign"] then
         scope[cond["assign"]] = result
      end
   end
   return true
end





local function resolve_deep(val, scope)
   if type(val) == "string" then
      return resolve_template(val, scope)
   elseif type(val) == "table" then
      local out = {}
      for k, v in pairs(val) do
         out[k] = resolve_deep(v, scope)
      end
      return out
   end
   return val
end

local function eval_endpoint(endpoint, scope)
   local url
   if type(endpoint["url"]) == "string" then
      url = resolve_template(endpoint["url"], scope)
   elseif type(endpoint["url"]) == "table" then
      url = resolve_arg(endpoint["url"], scope)
   end

   local headers
   if endpoint["headers"] then
      headers = {}
      for k, vals in pairs(endpoint["headers"]) do
         local resolved_vals = {}
         for _, v in ipairs(vals) do
            if type(v) == "string" then
               resolved_vals[#resolved_vals + 1] = resolve_template(v, scope)
            else
               resolved_vals[#resolved_vals + 1] = resolve_arg(v, scope)
            end
         end
         headers[k] = resolved_vals
      end
   end

   local properties
   if endpoint["properties"] then
      properties = resolve_deep(endpoint["properties"], scope)
   end

   return { url = url, headers = headers, properties = properties }
end

local function eval_rules(rules, scope)
   for _, rule_any in ipairs(rules) do
      local rule = rule_any
      local child = setmetatable({}, { __index = scope })

      if eval_conditions(rule["conditions"], child) then
         if rule["type"] == "endpoint" then
            return eval_endpoint(rule["endpoint"], child), nil
         elseif rule["type"] == "error" then
            local msg
            if type(rule["error"]) == "string" then
               msg = resolve_template(rule["error"], child)
            else
               msg = resolve_arg(rule["error"], child)
            end
            return nil, msg
         elseif rule["type"] == "tree" then
            local result, err = eval_rules(rule["rules"], child)
            if result or err then
               return result, err
            end
            return nil, "rules exhausted in tree rule"
         end
      end
   end
   return nil, nil
end





function M.resolve(ruleset, params)
   local rs = ruleset
   local scope = {}
   if rs["parameters"] then
      for name, def_any in pairs(rs["parameters"]) do
         local def = def_any
         local val = params[name]
         if val == nil and def["default"] ~= nil then
            val = def["default"]
         end
         if val == nil then
            if def["required"] then
               return nil, "required endpoint parameter missing: " .. name
            end
            scope[name] = UNSET
         else
            scope[name] = val
         end
      end
   end
   for k, v in pairs(params) do
      if scope[k] == nil then
         scope[k] = v
      end
   end

   local result, err = eval_rules(rs["rules"], scope)
   if result then return result, nil end
   if err then return nil, err end
   return nil, "endpoint rules exhausted without a match"
end

return M
