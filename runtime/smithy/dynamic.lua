

local json_decoder = require("smithy.json.decoder")
local schema = require("smithy.schema")
local shape_id = require("smithy.shape_id")
local traits = require("smithy.traits")
local base_client = require("smithy.client")

local M = { DynamicClient = {} }
















local TRAIT_MAP = {
   ["smithy.api#required"] = { key = traits.REQUIRED, value = function(_) return {} end },
   ["smithy.api#default"] = { key = traits.DEFAULT, value = function(v) return { value = v } end },
   ["smithy.api#jsonName"] = { key = traits.JSON_NAME, value = function(v) return { name = v } end },
   ["smithy.api#xmlName"] = { key = traits.XML_NAME, value = function(v) return { name = v } end },
   ["smithy.api#xmlAttribute"] = { key = traits.XML_ATTRIBUTE, value = function(_) return {} end },
   ["smithy.api#xmlFlattened"] = { key = traits.XML_FLATTENED, value = function(_) return {} end },
   ["smithy.api#xmlNamespace"] = { key = traits.XML_NAMESPACE, value = function(v) return v end },
   ["smithy.api#timestampFormat"] = { key = traits.TIMESTAMP_FORMAT, value = function(v) return { format = v } end },
   ["smithy.api#mediaType"] = { key = traits.MEDIA_TYPE, value = function(v) return { value = v } end },
   ["smithy.api#httpHeader"] = { key = traits.HTTP_HEADER, value = function(v) return { name = v } end },
   ["smithy.api#httpLabel"] = { key = traits.HTTP_LABEL, value = function(_) return {} end },
   ["smithy.api#httpQuery"] = { key = traits.HTTP_QUERY, value = function(v) return { name = v } end },
   ["smithy.api#httpQueryParams"] = { key = traits.HTTP_QUERY_PARAMS, value = function(_) return {} end },
   ["smithy.api#httpPayload"] = { key = traits.HTTP_PAYLOAD, value = function(_) return {} end },
   ["smithy.api#httpPrefixHeaders"] = { key = traits.HTTP_PREFIX_HEADERS, value = function(v) return { name = v } end },
   ["smithy.api#httpResponseCode"] = { key = traits.HTTP_RESPONSE_CODE, value = function(_) return {} end },
   ["smithy.api#idempotencyToken"] = { key = traits.IDEMPOTENCY_TOKEN, value = function(_) return {} end },
   ["smithy.api#streaming"] = { key = traits.STREAMING, value = function(_) return {} end },
   ["smithy.api#sensitive"] = { key = traits.SENSITIVE, value = function(_) return {} end },
   ["smithy.api#hostLabel"] = { key = traits.HOST_LABEL, value = function(_) return {} end },
   ["smithy.api#eventHeader"] = { key = traits.EVENT_HEADER, value = function(_) return {} end },
   ["smithy.api#eventPayload"] = { key = traits.EVENT_PAYLOAD, value = function(_) return {} end },
   ["smithy.api#error"] = { key = traits.ERROR, value = function(v) return { value = v } end },
   ["smithy.api#sparse"] = { key = traits.SPARSE, value = function(_) return {} end },
   ["aws.protocols#awsQueryError"] = { key = traits.AWS_QUERY_ERROR, value = function(v) return v end },
   ["aws.protocols#ec2QueryName"] = { key = traits.EC2_QUERY_NAME, value = function(v) return { name = v } end },
}

local TYPE_MAP = {
   blob = "blob", boolean = "boolean", string = "string", timestamp = "timestamp",
   byte = "byte", short = "short", integer = "integer", long = "long",
   float = "float", double = "double", document = "document",
   bigDecimal = "bigDecimal", bigInteger = "bigInteger",
   list = "list", set = "list", map = "map",
   structure = "structure", union = "union",
   enum = "enum", intEnum = "int_enum",
}

local function parse_id(id_str)
   local ns, name = id_str:match("^(.+)#(.+)$")
   if not ns then return nil end
   return shape_id.from(ns, name)
end

local function convert_traits(raw_traits)
   if not raw_traits then return nil end
   local result = nil
   for trait_id, trait_val in pairs(raw_traits) do
      local mapping = TRAIT_MAP[trait_id]
      if mapping then
         if not result then result = {} end
         result[mapping.key] = mapping.value(trait_val)
      end
   end
   return result
end






local Converter_mt = { __index = {} }

local function Converter_new(shapes)
   return setmetatable({ shapes = shapes, cache = {} }, Converter_mt)
end

local function Converter_get_schema(self, shape_id_str)
   local cached = self.cache[shape_id_str]
   if cached then return cached end
   return Converter_convert(self, shape_id_str)
end

local function Converter_convert_member(self, parent_id_str, member_name, member_def)
   local target_id_str = member_def.target
   local target_schema = Converter_get_schema(self, target_id_str)

   local target_type = "structure"
   if target_schema then
      target_type = (target_schema).type
   else
      local target_shape = self.shapes[target_id_str]
      if target_shape then
         target_type = TYPE_MAP[target_shape.type] or "string"
      end
   end

   local member_traits = convert_traits(member_def.traits)

   if target_schema and (target_type == "structure" or target_type == "union" or
      target_type == "list" or target_type == "map") then
      local ts = target_schema
      if member_traits then
         return schema.new({
            id = parse_id(parent_id_str .. "$" .. member_name),
            type = target_type,
            name = member_name,
            target = target_schema,
            target_id = ts.id,
            traits = member_traits,
            members = ts._members,
            list_member = ts.list_member,
            map_key = ts.map_key,
            map_value = ts.map_value,
         })
      end
      return schema.new({
         id = parse_id(parent_id_str .. "$" .. member_name),
         type = target_type,
         name = member_name,
         target = target_schema,
         target_id = ts.id,
         members = ts._members,
         list_member = ts.list_member,
         map_key = ts.map_key,
         map_value = ts.map_value,
      })
   end

   local merged_traits = nil
   if target_schema and (target_schema)._traits then
      merged_traits = {}
      for k, v in pairs((target_schema)._traits) do merged_traits[k] = v end
   end
   if member_traits then
      if not merged_traits then merged_traits = {} end
      for k, v in pairs(member_traits) do merged_traits[k] = v end
   end

   return schema.new({
      id = parse_id(parent_id_str .. "$" .. member_name),
      type = target_type,
      name = member_name,
      target_id = target_schema and (target_schema).id or parse_id(target_id_str),
      traits = merged_traits,
   })
end

local function Converter_convert_aggregate(self, shape_id_str, shape, sid, stype)
   if stype == "list" then
      local member_schema = Converter_convert_member(self, shape_id_str, "member", shape.member)
      return schema.new({
         id = sid,
         type = "list",
         list_member = member_schema,
         traits = convert_traits(shape.traits),
      })
   end

   if stype == "map" then
      local key_schema = Converter_convert_member(self, shape_id_str, "key", shape.key)
      local value_schema = Converter_convert_member(self, shape_id_str, "value", shape.value)
      return schema.new({
         id = sid,
         type = "map",
         map_key = key_schema,
         map_value = value_schema,
         traits = convert_traits(shape.traits),
      })
   end

   local members = {}
   if shape.members then
      for member_name, member_def in pairs(shape.members) do
         members[member_name] = Converter_convert_member(self, shape_id_str, member_name, member_def)
      end
   end
   return schema.new({
      id = sid,
      type = stype,
      members = members,
      traits = convert_traits(shape.traits),
   })
end

function Converter_convert(self, shape_id_str)
   local shape = self.shapes[shape_id_str]
   if not shape then return nil end

   local sid = parse_id(shape_id_str)
   local stype = TYPE_MAP[shape.type]
   if not stype then return nil end

   if stype == "structure" or stype == "union" or stype == "list" or stype == "map" then
      local placeholder = {}
      self.cache[shape_id_str] = placeholder
      local s = Converter_convert_aggregate(self, shape_id_str, shape, sid, stype)
      for k, v in pairs(s) do placeholder[k] = v end
      setmetatable(placeholder, getmetatable(s))
      return placeholder
   end

   local s = schema.new({
      id = sid,
      type = stype,
      traits = convert_traits(shape.traits),
   })
   self.cache[shape_id_str] = s
   return s
end


local PROTOCOL_MAP = {
   ["aws.protocols#awsJson1_0"] = function(_, service_name, _version)
      return require("smithy.protocol.awsjson").new({ version = "1.0", service_id = service_name })
   end,
   ["aws.protocols#awsJson1_1"] = function(_, service_name, _version)
      return require("smithy.protocol.awsjson").new({ version = "1.1", service_id = service_name })
   end,
   ["aws.protocols#restJson1"] = function(_, _sn, _version)
      return require("smithy.protocol.restjson").new()
   end,
   ["aws.protocols#restXml"] = function(_, _sn, _version)
      return require("smithy.protocol.restxml").new()
   end,
   ["aws.protocols#awsQuery"] = function(_, _sn, version)
      return require("smithy.protocol.awsquery").new({ version = version })
   end,
   ["aws.protocols#ec2Query"] = function(_, _sn, version)
      return require("smithy.protocol.ec2query").new({ version = version })
   end,
   ["smithy.protocols#rpcv2Cbor"] = function(_, service_name, _version)
      return require("smithy.protocol.rpcv2").new_cbor({ service_name = service_name })
   end,
   ["smithy.protocols#rpcv2Json"] = function(_, service_name, _version)
      return require("smithy.protocol.rpcv2").new_json({ service_name = service_name })
   end,
}

local function detect_protocol(service_shape, service_id_str)
   if not service_shape.traits then return nil end
   local service_name = service_id_str:match("#(.+)$") or service_id_str
   local service_version = (service_shape.version or "")
   local service_traits = service_shape.traits
   for trait_id, factory in pairs(PROTOCOL_MAP) do
      if service_traits[trait_id] then
         return factory(service_id_str, service_name, service_version)
      end
   end
   return nil
end

local function detect_signing_name(service_shape)
   local service_traits = service_shape.traits
   local sigv4 = service_traits and service_traits["aws.auth#sigv4"]
   if sigv4 then return sigv4.name end
   return nil
end

local function detect_auth_schemes(service_shape)
   local service_traits = service_shape.traits
   local auth = service_traits and service_traits["smithy.api#auth"]
   if auth then return auth end
   if service_traits and service_traits["aws.auth#sigv4"] then
      return { "aws.auth#sigv4" }
   end
   return {}
end

local function build_operation(converter, shapes, op_id_str, service_auth_schemes)
   local op_shape = shapes[op_id_str]
   if not op_shape then return nil, "operation not found: " .. op_id_str end

   local input_target = op_shape.input
   local output_target = op_shape.output
   local input_schema = input_target and Converter_get_schema(converter, input_target.target)
   local output_schema = output_target and Converter_get_schema(converter, output_target.target)

   local http_trait_val = nil
   local op_traits_raw = op_shape.traits
   local raw_http = op_traits_raw and op_traits_raw["smithy.api#http"]
   if raw_http then
      local method = (raw_http.method or "POST")
      local path = (raw_http.uri or "/")
      http_trait_val = { method = method, path = path }
   end

   local effective_auth = service_auth_schemes
   local op_auth = op_traits_raw and op_traits_raw["smithy.api#auth"]
   if op_auth then effective_auth = op_auth end

   local context_params = nil
   if input_target then
      local input_shape = shapes[input_target.target]
      if input_shape and input_shape.members then
         for member_name, member_def in pairs(input_shape.members) do
            local md = member_def
            local md_traits = md.traits
            local cp = md_traits and md_traits["smithy.rules#contextParam"]
            if cp then
               context_params = context_params or {}
               context_params[cp.name] = member_name
            end
         end
      end
   end

   local static_ctx = nil
   if op_traits_raw and op_traits_raw["smithy.rules#staticContextParams"] then
      static_ctx = {}
      for param_name, param_def in pairs(op_traits_raw["smithy.rules#staticContextParams"]) do
         static_ctx[param_name] = param_def
      end
   end

   local op_schema_traits = {}
   if http_trait_val then op_schema_traits[traits.HTTP] = http_trait_val end
   if effective_auth then op_schema_traits[traits.AUTH] = effective_auth end
   if context_params then op_schema_traits[traits.CONTEXT_PARAMS] = context_params end
   if static_ctx then op_schema_traits[traits.STATIC_CONTEXT_PARAMS] = static_ctx end

   local default_input = schema.new({ id = parse_id(op_id_str .. "Input"), type = "structure" })
   local default_output = schema.new({ id = parse_id(op_id_str .. "Output"), type = "structure" })

   return schema.operation({
      id = parse_id(op_id_str),
      input = input_schema or default_input,
      output = output_schema or default_output,
      traits = op_schema_traits,
   })
end

function M.load_model(model_source)
   if type(model_source) == "table" then return model_source, nil end
   local f, err = io.open(model_source, "r")
   if not f then return nil, "cannot open model: " .. (err or model_source) end
   local content = f:read("*a")
   f:close()
   return json_decoder.decode(content)
end

local function find_service(shapes, service_id)
   if service_id then
      local shape = shapes[service_id]
      if not shape then return nil, nil, "service not found: " .. service_id end
      return service_id, shape, nil
   end
   local found_id = nil
   local found_shape = nil
   local count = 0
   for id_str, shape in pairs(shapes) do
      local s = shape
      if s.type == "service" then
         found_id = id_str
         found_shape = s
         count = count + 1
      end
   end
   if count == 0 then return nil, nil, "no service found in model" end
   if count > 1 then return nil, nil, "multiple services in model; specify service ID" end
   return found_id, found_shape, nil
end

function M.new(config)
   local model, err = M.load_model(config.model)
   if not model then return nil, err end

   local shapes = (model).shapes
   local service_id_str
   local service_shape
   service_id_str, service_shape, err = find_service(shapes, config.service)
   if not service_id_str then return nil, err end

   local converter = Converter_new(shapes)

   local protocol = config.protocol or detect_protocol(service_shape, service_id_str)
   if not protocol then
      return nil, "cannot detect protocol for service " .. service_id_str .. "; provide config.protocol"
   end

   local signing_name = detect_signing_name(service_shape)
   local service_auth_schemes = detect_auth_schemes(service_shape)

   local operation_ids = {}
   if service_shape.operations then
      for _, op_ref in ipairs(service_shape.operations) do
         local op_name = (op_ref.target):match("#(.+)$")
         if op_name then operation_ids[op_name] = op_ref.target end
      end
   end
   if service_shape.resources then
      for _, res_ref in ipairs(service_shape.resources) do
         local res_shape = shapes[res_ref.target]
         if res_shape and res_shape.operations then
            for _, op_ref in ipairs(res_shape.operations) do
               local op_name = (op_ref.target):match("#(.+)$")
               if op_name then operation_ids[op_name] = op_ref.target end
            end
         end
      end
   end

   local client_config = {
      protocol = protocol,
      region = config.region,
      endpoint_url = config.endpoint_url,
      use_fips = config.use_fips,
      use_dual_stack = config.use_dual_stack,
      http_client = config.http_client,
      retry_strategy = config.retry_strategy,
      auth_schemes = config.auth_schemes,
      identity_resolvers = config.identity_resolvers,
      interceptors = config.interceptors,
   }

   if signing_name and not config.auth_scheme_resolver then
      local traits_mod = require("smithy.traits")
      client_config.auth_scheme_resolver = function(service, operation)
         local trait_fn = (operation).trait
         local svc_trait_fn = (service).trait
         local auth_trait = trait_fn(operation, traits_mod.AUTH) or svc_trait_fn(service, traits_mod.AUTH)
         local options = {}
         for _, scheme_id in ipairs(auth_trait or {}) do
            local sid = scheme_id
            if sid == "aws.auth#sigv4" or sid == "aws.auth#sigv4a" then
               local sp = {
                  signing_name = signing_name,
                  signing_region = config.region,
               }
               local entry = { scheme_id = sid, signer_properties = sp }
               options[#options + 1] = entry
            else
               local entry = { scheme_id = sid }
               options[#options + 1] = entry
            end
         end
         return options
      end
   else
      client_config.auth_scheme_resolver = config.auth_scheme_resolver
   end

   if config.endpoint_provider then
      client_config.endpoint_provider = config.endpoint_provider
   elseif config.endpoint_url then
      client_config.endpoint_provider = function()
         return { url = config.endpoint_url }, nil
      end
   else
      local service_traits = service_shape.traits
      local rules_trait = service_traits and service_traits["smithy.rules#endpointRuleSet"]
      if rules_trait then
         local endpoint_engine = require("smithy.endpoint")
         client_config.endpoint_provider = function(params)
            return endpoint_engine.resolve(rules_trait, params)
         end
      else
         return nil, "no endpoint_url or endpoint rules for service " .. service_id_str
      end
   end

   local defaults = require("smithy.defaults")
   defaults.resolve_auth_schemes(client_config)
   defaults.resolve_identity_resolvers(client_config)
   defaults.resolve_http_client(client_config)
   defaults.resolve_retry_strategy(client_config)

   local ok, sdk_defaults = pcall(require, "aws.sdk_defaults")
   if ok and sdk_defaults then
      local sd = sdk_defaults
      if sd.resolve_identity_resolver then
         local resolve_fn = sd.resolve_identity_resolver
         resolve_fn(client_config)
      end
   else
      local cred_ok, env_creds = pcall(require, "aws.credentials.environment")
      if cred_ok then
         local ec = env_creds
         local new_fn = ec.new
         local resolver = new_fn()
         if not client_config.identity_resolvers then client_config.identity_resolvers = {} end
         local ir = client_config.identity_resolvers
         ir["aws_credentials"] = resolver
      end
   end

   local traits_mod = require("smithy.traits")
   local svc_traits = {}
   if service_auth_schemes and #service_auth_schemes > 0 then
      svc_traits[traits_mod.AUTH] = service_auth_schemes
   end
   local service_schema = schema.service({
      id = parse_id(service_id_str),
      version = (service_shape.version or ""),
      traits = svc_traits,
   })

   local client = base_client.new(client_config)

   local op_cache = {}

   function client:call(name, input, options)
      local op = op_cache[name]
      if not op then
         local op_id = operation_ids[name]
         if not op_id then
            return nil, { type = "sdk", message = "unknown operation: " .. name }
         end
         local build_err
         op, build_err = build_operation(converter, shapes, op_id, service_auth_schemes)
         if not op then
            return nil, { type = "sdk", message = build_err }
         end
         op_cache[name] = op
      end
      return self:invokeOperation(service_schema, op, input or {}, options)
   end

   function client:operations()
      local names = {}
      for name in pairs(operation_ids) do
         names[#names + 1] = name
      end
      table.sort(names)
      return names
   end

   return client
end

return M
