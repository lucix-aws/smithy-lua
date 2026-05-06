-- smithy-lua runtime: Dynamic client
-- Loads a Smithy JSON AST model at runtime and creates a client without codegen.

local json_decoder = require("smithy.json.decoder")
local schema = require("smithy.schema")
local shape_id = require("smithy.shape_id")
local traits = require("smithy.traits")
local base_client = require("smithy.client")

local M = {}

-- Map from Smithy trait ID strings to our singleton trait keys + value extractors.
-- Each entry: { key = traits.X, value = fn(trait_value) -> trait_record }
local TRAIT_MAP = {
    ["smithy.api#required"]         = { key = traits.REQUIRED,         value = function() return {} end },
    ["smithy.api#default"]          = { key = traits.DEFAULT,          value = function(v) return { value = v } end },
    ["smithy.api#jsonName"]         = { key = traits.JSON_NAME,        value = function(v) return { name = v } end },
    ["smithy.api#xmlName"]          = { key = traits.XML_NAME,         value = function(v) return { name = v } end },
    ["smithy.api#xmlAttribute"]     = { key = traits.XML_ATTRIBUTE,    value = function() return {} end },
    ["smithy.api#xmlFlattened"]     = { key = traits.XML_FLATTENED,    value = function() return {} end },
    ["smithy.api#xmlNamespace"]     = { key = traits.XML_NAMESPACE,    value = function(v) return v end },
    ["smithy.api#timestampFormat"]  = { key = traits.TIMESTAMP_FORMAT, value = function(v) return { format = v } end },
    ["smithy.api#mediaType"]        = { key = traits.MEDIA_TYPE,       value = function(v) return { value = v } end },
    ["smithy.api#httpHeader"]       = { key = traits.HTTP_HEADER,      value = function(v) return { name = v } end },
    ["smithy.api#httpLabel"]        = { key = traits.HTTP_LABEL,       value = function() return {} end },
    ["smithy.api#httpQuery"]        = { key = traits.HTTP_QUERY,       value = function(v) return { name = v } end },
    ["smithy.api#httpQueryParams"]  = { key = traits.HTTP_QUERY_PARAMS, value = function() return {} end },
    ["smithy.api#httpPayload"]      = { key = traits.HTTP_PAYLOAD,     value = function() return {} end },
    ["smithy.api#httpPrefixHeaders"] = { key = traits.HTTP_PREFIX_HEADERS, value = function(v) return { name = v } end },
    ["smithy.api#httpResponseCode"] = { key = traits.HTTP_RESPONSE_CODE, value = function() return {} end },
    ["smithy.api#idempotencyToken"] = { key = traits.IDEMPOTENCY_TOKEN, value = function() return {} end },
    ["smithy.api#streaming"]        = { key = traits.STREAMING,        value = function() return {} end },
    ["smithy.api#sensitive"]        = { key = traits.SENSITIVE,        value = function() return {} end },
    ["smithy.api#hostLabel"]        = { key = traits.HOST_LABEL,       value = function() return {} end },
    ["smithy.api#eventHeader"]      = { key = traits.EVENT_HEADER,     value = function() return {} end },
    ["smithy.api#eventPayload"]     = { key = traits.EVENT_PAYLOAD,    value = function() return {} end },
    ["smithy.api#error"]            = { key = traits.ERROR,            value = function(v) return { value = v } end },
    ["smithy.api#sparse"]           = { key = traits.SPARSE,           value = function() return {} end },
    ["aws.protocols#awsQueryError"] = { key = traits.AWS_QUERY_ERROR,  value = function(v) return v end },
    ["aws.protocols#ec2QueryName"]  = { key = traits.EC2_QUERY_NAME,   value = function(v) return { name = v } end },
}

-- Smithy type string to our schema type constant
local TYPE_MAP = {
    blob = "blob", boolean = "boolean", string = "string", timestamp = "timestamp",
    byte = "byte", short = "short", integer = "integer", long = "long",
    float = "float", double = "double", document = "document",
    bigDecimal = "bigDecimal", bigInteger = "bigInteger",
    list = "list", set = "list", map = "map",
    structure = "structure", union = "union",
    enum = "enum", intEnum = "int_enum",
}

--- Parse a shape ID string "namespace#Name" into a shape_id table.
local function parse_id(id_str)
    local ns, name = id_str:match("^(.+)#(.+)$")
    if not ns then return nil end
    return shape_id.from(ns, name)
end

--- Convert raw JSON AST traits to our trait table format.
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

--- Schema converter: converts Smithy JSON AST shapes to runtime schemas.
local Converter = {}
Converter.__index = Converter

function Converter.new(shapes)
    return setmetatable({ shapes = shapes, cache = {} }, Converter)
end

function Converter:get_schema(shape_id_str)
    local cached = self.cache[shape_id_str]
    if cached then return cached end
    return self:convert(shape_id_str)
end

function Converter:convert(shape_id_str)
    local shape = self.shapes[shape_id_str]
    if not shape then return nil end

    local sid = parse_id(shape_id_str)
    local stype = TYPE_MAP[shape.type]
    if not stype then return nil end

    -- For aggregate types, put a placeholder in cache first to handle cycles
    if stype == "structure" or stype == "union" or stype == "list" or stype == "map" then
        local placeholder = {}
        self.cache[shape_id_str] = placeholder
        local s = self:convert_aggregate(shape_id_str, shape, sid, stype)
        -- Copy fields into placeholder so existing references work
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

function Converter:convert_aggregate(shape_id_str, shape, sid, stype)
    if stype == "list" then
        local member_schema = self:convert_member(shape_id_str, "member", shape.member)
        return schema.new({
            id = sid,
            type = "list",
            list_member = member_schema,
            traits = convert_traits(shape.traits),
        })
    end

    if stype == "map" then
        local key_schema = self:convert_member(shape_id_str, "key", shape.key)
        local value_schema = self:convert_member(shape_id_str, "value", shape.value)
        return schema.new({
            id = sid,
            type = "map",
            map_key = key_schema,
            map_value = value_schema,
            traits = convert_traits(shape.traits),
        })
    end

    -- structure or union
    local members = {}
    if shape.members then
        for member_name, member_def in pairs(shape.members) do
            members[member_name] = self:convert_member(shape_id_str, member_name, member_def)
        end
    end
    return schema.new({
        id = sid,
        type = stype,
        members = members,
        traits = convert_traits(shape.traits),
    })
end

function Converter:convert_member(parent_id_str, member_name, member_def)
    local target_id_str = member_def.target
    local target_schema = self:get_schema(target_id_str)

    -- For simple targets, the member schema carries the target's type
    local target_type = "structure"
    if target_schema then
        target_type = target_schema.type
    else
        -- Fallback: look up the shape directly for its type
        local target_shape = self.shapes[target_id_str]
        if target_shape then
            target_type = TYPE_MAP[target_shape.type] or "string"
        end
    end

    local member_traits = convert_traits(member_def.traits)

    -- For aggregate targets (structure/union/list/map), use the target schema directly
    -- and layer member traits on top
    if target_schema and (target_type == "structure" or target_type == "union"
        or target_type == "list" or target_type == "map") then
        if member_traits then
            -- Create a member schema that delegates to target for members
            return schema.new({
                id = parse_id(parent_id_str .. "$" .. member_name),
                type = target_type,
                name = member_name,
                target = target_schema,
                target_id = target_schema.id,
                traits = member_traits,
                -- Inherit structural fields
                members = target_schema._members,
                list_member = target_schema.list_member,
                map_key = target_schema.map_key,
                map_value = target_schema.map_value,
            })
        end
        -- No member-level traits, just use target directly but with name
        return schema.new({
            id = parse_id(parent_id_str .. "$" .. member_name),
            type = target_type,
            name = member_name,
            target = target_schema,
            target_id = target_schema.id,
            members = target_schema._members,
            list_member = target_schema.list_member,
            map_key = target_schema.map_key,
            map_value = target_schema.map_value,
        })
    end

    -- Simple/scalar target: merge target traits with member traits
    local merged_traits = nil
    if target_schema and target_schema._traits then
        merged_traits = {}
        for k, v in pairs(target_schema._traits) do merged_traits[k] = v end
    end
    if member_traits then
        if not merged_traits then merged_traits = {} end
        for k, v in pairs(member_traits) do merged_traits[k] = v end
    end

    return schema.new({
        id = parse_id(parent_id_str .. "$" .. member_name),
        type = target_type,
        name = member_name,
        target_id = target_schema and target_schema.id or parse_id(target_id_str),
        traits = merged_traits,
    })
end

--- Protocol detection from service traits.
local PROTOCOL_MAP = {
    ["aws.protocols#awsJson1_0"] = function(_, service_name)
        return require("smithy.protocol.awsjson").new({ version = "1.0", service_id = service_name })
    end,
    ["aws.protocols#awsJson1_1"] = function(_, service_name)
        return require("smithy.protocol.awsjson").new({ version = "1.1", service_id = service_name })
    end,
    ["aws.protocols#restJson1"] = function()
        return require("smithy.protocol.restjson").new()
    end,
    ["aws.protocols#restXml"] = function()
        return require("smithy.protocol.restxml").new()
    end,
    ["aws.protocols#awsQuery"] = function(_, _, version)
        return require("smithy.protocol.awsquery").new({ version = version })
    end,
    ["aws.protocols#ec2Query"] = function(_, _, version)
        return require("smithy.protocol.ec2query").new({ version = version })
    end,
    ["smithy.protocols#rpcv2Cbor"] = function(_, service_name)
        return require("smithy.protocol.rpcv2").new_cbor({ service_name = service_name })
    end,
    ["smithy.protocols#rpcv2Json"] = function(_, service_name)
        return require("smithy.protocol.rpcv2").new_json({ service_name = service_name })
    end,
}

local function detect_protocol(service_shape, service_id_str)
    if not service_shape.traits then return nil end
    -- Extract the short name from the service ID for protocols that need it
    local service_name = service_id_str:match("#(.+)$") or service_id_str
    -- Get service version for query protocols
    local service_version = service_shape.version or ""
    for trait_id, factory in pairs(PROTOCOL_MAP) do
        if service_shape.traits[trait_id] then
            return factory(service_id_str, service_name, service_version)
        end
    end
    return nil
end

--- Detect signing name from service traits.
local function detect_signing_name(service_shape)
    local sigv4 = service_shape.traits and service_shape.traits["aws.auth#sigv4"]
    if sigv4 then return sigv4.name end
    return nil
end

--- Detect effective auth schemes for the service.
local function detect_auth_schemes(service_shape)
    local auth = service_shape.traits and service_shape.traits["smithy.api#auth"]
    if auth then return auth end
    -- Default: if sigv4 trait present, use sigv4
    if service_shape.traits and service_shape.traits["aws.auth#sigv4"] then
        return { "aws.auth#sigv4" }
    end
    return {}
end

--- Build an operation schema from the model.
local function build_operation(converter, shapes, op_id_str, service_auth_schemes)
    local op_shape = shapes[op_id_str]
    if not op_shape then return nil, "operation not found: " .. op_id_str end

    local input_schema = op_shape.input and converter:get_schema(op_shape.input.target)
    local output_schema = op_shape.output and converter:get_schema(op_shape.output.target)

    -- Get HTTP method/path from @http trait
    local http_trait_val = nil
    local raw_http = op_shape.traits and op_shape.traits["smithy.api#http"]
    if raw_http then
        http_trait_val = { method = raw_http.method or "POST", path = raw_http.uri or "/" }
    end

    -- Get effective auth schemes (operation-level overrides service-level)
    local effective_auth = service_auth_schemes
    local op_auth = op_shape.traits and op_shape.traits["smithy.api#auth"]
    if op_auth then effective_auth = op_auth end

    -- Get context params from @contextParam on members
    local context_params = nil
    if op_shape.input then
        local input_shape = shapes[op_shape.input.target]
        if input_shape and input_shape.members then
            for member_name, member_def in pairs(input_shape.members) do
                local cp = member_def.traits and member_def.traits["smithy.rules#contextParam"]
                if cp then
                    context_params = context_params or {}
                    context_params[cp.name] = member_name
                end
            end
        end
    end

    -- Get static context params
    local static_ctx = nil
    if op_shape.traits and op_shape.traits["smithy.rules#staticContextParams"] then
        static_ctx = {}
        for param_name, param_def in pairs(op_shape.traits["smithy.rules#staticContextParams"]) do
            static_ctx[param_name] = param_def
        end
    end

    local traits = require("smithy.traits")
    local op_traits = {}
    if http_trait_val then op_traits[traits.HTTP] = http_trait_val end
    if effective_auth then op_traits[traits.AUTH] = effective_auth end
    if context_params then op_traits[traits.CONTEXT_PARAMS] = context_params end
    if static_ctx then op_traits[traits.STATIC_CONTEXT_PARAMS] = static_ctx end

    return schema.operation({
        id = parse_id(op_id_str),
        input = input_schema or schema.new({ id = parse_id(op_id_str .. "Input"), type = "structure" }),
        output = output_schema or schema.new({ id = parse_id(op_id_str .. "Output"), type = "structure" }),
        traits = op_traits,
    })
end

--- Load a Smithy JSON AST model from a file path or table.
--- @param model_source string|table: file path or pre-parsed model table
--- @return table: the parsed model (with .shapes, .smithy fields)
function M.load_model(model_source)
    if type(model_source) == "table" then return model_source end
    local f, err = io.open(model_source, "r")
    if not f then return nil, "cannot open model: " .. (err or model_source) end
    local content = f:read("*a")
    f:close()
    return json_decoder.decode(content)
end

--- Find the service shape in a model.
--- @param shapes table: the shapes map from the model
--- @param service_id string|nil: explicit service ID, or nil to auto-detect
--- @return string, table: service ID string and service shape
local function find_service(shapes, service_id)
    if service_id then
        local shape = shapes[service_id]
        if not shape then return nil, nil, "service not found: " .. service_id end
        return service_id, shape, nil
    end
    -- Auto-detect: find the single service shape
    local found_id, found_shape, count = nil, nil, 0
    for id_str, shape in pairs(shapes) do
        if shape.type == "service" then
            found_id, found_shape = id_str, shape
            count = count + 1
        end
    end
    if count == 0 then return nil, nil, "no service found in model" end
    if count > 1 then return nil, nil, "multiple services in model; specify service ID" end
    return found_id, found_shape, nil
end

--- Create a dynamic client from a model.
--- @param config table: { model = path_or_table, service = "ns#Name", region = "...", ... }
--- @return table: client with :call(operation_name, input) method
function M.new(config)
    local model, err = M.load_model(config.model)
    if not model then return nil, err end

    local shapes = model.shapes
    local service_id_str, service_shape
    service_id_str, service_shape, err = find_service(shapes, config.service)
    if not service_id_str then return nil, err end

    -- Build schema converter
    local converter = Converter.new(shapes)

    -- Detect protocol
    local protocol = config.protocol or detect_protocol(service_shape, service_id_str)
    if not protocol then
        return nil, "cannot detect protocol for service " .. service_id_str .. "; provide config.protocol"
    end

    -- Detect auth
    local signing_name = detect_signing_name(service_shape)
    local service_auth_schemes = detect_auth_schemes(service_shape)

    -- Collect operations from service shape
    local operation_ids = {}
    if service_shape.operations then
        for _, op_ref in ipairs(service_shape.operations) do
            local op_name = op_ref.target:match("#(.+)$")
            if op_name then operation_ids[op_name] = op_ref.target end
        end
    end
    -- Also check resources for operations
    if service_shape.resources then
        for _, res_ref in ipairs(service_shape.resources) do
            local res_shape = shapes[res_ref.target]
            if res_shape and res_shape.operations then
                for _, op_ref in ipairs(res_shape.operations) do
                    local op_name = op_ref.target:match("#(.+)$")
                    if op_name then operation_ids[op_name] = op_ref.target end
                end
            end
        end
    end

    -- Build client config
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

    -- Set up auth scheme resolver if signing_name detected
    if signing_name and not config.auth_scheme_resolver then
        local traits_mod = require("smithy.traits")
        client_config.auth_scheme_resolver = function(service, operation)
            local auth_trait = operation:trait(traits_mod.AUTH) or service:trait(traits_mod.AUTH)
            local options = {}
            for _, scheme_id in ipairs(auth_trait or {}) do
                if scheme_id == "aws.auth#sigv4" or scheme_id == "aws.auth#sigv4a" then
                    options[#options + 1] = {
                        scheme_id = scheme_id,
                        signer_properties = {
                            signing_name = signing_name,
                            signing_region = config.region,
                        },
                    }
                else
                    options[#options + 1] = { scheme_id = scheme_id }
                end
            end
            return options
        end
    else
        client_config.auth_scheme_resolver = config.auth_scheme_resolver
    end

    -- Set up endpoint provider
    if config.endpoint_provider then
        client_config.endpoint_provider = config.endpoint_provider
    elseif config.endpoint_url then
        -- Static endpoint
        client_config.endpoint_provider = function()
            return { url = config.endpoint_url }, nil
        end
    else
        -- Try to load endpoint rules from model
        local rules_trait = service_shape.traits and service_shape.traits["smithy.rules#endpointRuleSet"]
        if rules_trait then
            local endpoint_engine = require("smithy.endpoint")
            client_config.endpoint_provider = function(params)
                return endpoint_engine.resolve(rules_trait, params)
            end
        else
            return nil, "no endpoint_url or endpoint rules for service " .. service_id_str
        end
    end

    -- Resolve defaults
    local defaults = require("smithy.defaults")
    defaults.resolve_auth_schemes(client_config)
    defaults.resolve_identity_resolvers(client_config)
    defaults.resolve_http_client(client_config)
    defaults.resolve_retry_strategy(client_config)

    -- Try SDK defaults if available (aws-sdk-lua credential chain)
    local ok, sdk_defaults = pcall(require, "aws.sdk_defaults")
    if ok and sdk_defaults and sdk_defaults.resolve_identity_resolver then
        sdk_defaults.resolve_identity_resolver(client_config)
    else
        -- Fallback: try environment credential provider directly
        local cred_ok, env_creds = pcall(require, "aws.credentials.environment")
        if cred_ok then
            local resolver = env_creds.new()
            if not client_config.identity_resolvers then client_config.identity_resolvers = {} end
            client_config.identity_resolvers["aws_credentials"] = resolver
        end
    end

    -- Build service schema
    local traits_mod = require("smithy.traits")
    local svc_traits = {}
    if service_auth_schemes and #service_auth_schemes > 0 then
        svc_traits[traits_mod.AUTH] = service_auth_schemes
    end
    local service_schema = schema.service({
        id = parse_id(service_id_str),
        version = service_shape.version or "",
        traits = svc_traits,
    })

    -- Build the client
    local client = base_client.new(client_config)

    -- Operation cache
    local op_cache = {}

    --- Call an operation by name.
    --- @param name string: operation name (e.g. "ListTables")
    --- @param input table|nil: input fields
    --- @param options table|nil: per-call overrides
    --- @return table|nil, table|nil: output, error
    function client:call(name, input, options)
        local op = op_cache[name]
        if not op then
            local op_id = operation_ids[name]
            if not op_id then
                return nil, { type = "sdk", message = "unknown operation: " .. name }
            end
            op, err = build_operation(converter, shapes, op_id, service_auth_schemes)
            if not op then
                return nil, { type = "sdk", message = err }
            end
            op_cache[name] = op
        end
        return self:invokeOperation(service_schema, op, input or {}, options)
    end

    --- List available operations.
    --- @return table: list of operation name strings
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
