-- Smithy endpoint rules engine interpreter.
-- Evaluates a ruleset (Lua table emitted by codegen) given parameters,
-- returning { url, headers, properties } or nil, err.

local partitions = require("smithy.endpoint.partitions")

local M = {}

-- Sentinel for "not set" (distinguishes nil/unset from false)
local UNSET = {}

---------------------------------------------------------------------------
-- Template string resolution
---------------------------------------------------------------------------

local function get_attr(obj, path)
    -- path is "key.key[idx]" etc.
    for part in path:gmatch("[^.]+") do
        if obj == nil then return nil end
        local key, idx = part:match("^(.-)%[(-?%d+)%]$")
        if key then
            if key ~= "" then obj = obj[key] end
            idx = tonumber(idx)
            if idx < 0 then
                idx = #obj + idx + 1
            else
                idx = idx + 1 -- convert 0-based to 1-based
            end
            obj = obj[idx]
        else
            obj = obj[part]
        end
    end
    return obj
end

local function resolve_template(tmpl, scope)
    if type(tmpl) ~= "string" then return tmpl end
    return (tmpl:gsub("{([^}]+)}", function(expr)
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

---------------------------------------------------------------------------
-- Standard library functions
---------------------------------------------------------------------------

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
    local value, allow_sub = args[1], args[2]
    if type(value) ~= "string" or value == "" then return false end
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
    if type(url) ~= "string" then return nil end
    -- Reject URLs with query strings or fragments
    if url:find("?", 1, true) then return nil end
    if url:find("#", 1, true) then return nil end

    local scheme, rest = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://(.+)$")
    if not scheme then return nil end
    scheme = scheme:lower()

    local authority, path
    local slash_pos = rest:find("/", 1, true)
    if slash_pos then
        authority = rest:sub(1, slash_pos - 1)
        path = rest:sub(slash_pos)
    else
        authority = rest
        path = ""
    end

    -- Strip default ports
    local host_for_check = authority
    if scheme == "http" and authority:match(":80$") then
        -- keep non-default ports
    elseif scheme == "https" and authority:match(":443$") then
        -- keep non-default ports
    end

    -- normalizedPath: ensure starts and ends with /
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

    -- isIp: check for IPv4 or IPv6
    local is_ip = false
    local host = authority:match("^%[(.+)%]") -- IPv6
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
    local input, start_idx, end_idx, reverse = args[1], args[2], args[3], args[4]
    if type(input) ~= "string" then return nil end
    -- Must be ASCII only
    if input:match("[\128-\255]") then return nil end
    local len = #input
    if end_idx - start_idx <= 0 then return nil end
    if reverse then
        start_idx = len - end_idx
        end_idx = len - args[2]
    end
    if start_idx < 0 or end_idx > len then return nil end
    return input:sub(start_idx + 1, end_idx)
end

local function fn_uriEncode(args)
    local s = args[1]
    if type(s) ~= "string" then return "" end
    return (s:gsub("([^A-Za-z0-9%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function fn_split(args)
    local value, delimiter, limit = args[1], args[2], args[3]
    if type(value) ~= "string" or type(delimiter) ~= "string" or delimiter == "" then
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

---------------------------------------------------------------------------
-- AWS library functions
---------------------------------------------------------------------------

local function fn_aws_partition(args)
    local region = args[1]
    if type(region) ~= "string" or region == "" then return nil end
    return partitions.get_partition(region)
end

local function fn_aws_parseArn(args)
    local value = args[1]
    if type(value) ~= "string" then return nil end
    -- arn:partition:service:region:account:resource
    local parts = {}
    for part in (value .. ":"):gmatch("([^:]*):") do
        parts[#parts + 1] = part
    end
    if #parts < 6 then return nil end
    if parts[1] ~= "arn" then return nil end
    if parts[2] == "" or parts[3] == "" then return nil end

    -- resourceId: rejoin remaining parts, then split on : and / (preserving empty segments)
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
    local value, allow_sub = args[1], args[2]
    if type(value) ~= "string" or #value < 3 then return false end
    -- Must not contain ..
    if value:find("..", 1, true) then return false end
    -- Must not look like an IP
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

---------------------------------------------------------------------------
-- Function dispatch
---------------------------------------------------------------------------

local functions = {
    isSet = fn_isSet,
    ["not"] = fn_not,
    booleanEquals = fn_booleanEquals,
    stringEquals = fn_stringEquals,
    getAttr = fn_getAttr,
    isValidHostLabel = fn_isValidHostLabel,
    parseURL = fn_parseURL,
    substring = fn_substring,
    uriEncode = fn_uriEncode,
    split = fn_split,
    coalesce = fn_coalesce,
    ite = fn_ite,
    ["aws.partition"] = fn_aws_partition,
    ["aws.parseArn"] = fn_aws_parseArn,
    ["aws.isVirtualHostableS3Bucket"] = fn_aws_isVirtualHostableS3Bucket,
}

---------------------------------------------------------------------------
-- Argument resolution
---------------------------------------------------------------------------

local function resolve_arg(arg, scope)
    if type(arg) == "table" then
        if arg.ref then
            local val = scope[arg.ref]
            if val == UNSET then return nil end
            return val
        end
        if arg.fn then
            return M._call_fn(arg.fn, arg.argv, scope)
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
    -- isSet is special: pass nil for unset refs instead of resolving
    if name == "isSet" then
        local a = argv[1]
        if type(a) == "table" and a.ref then
            local val = scope[a.ref]
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

---------------------------------------------------------------------------
-- Condition evaluation
---------------------------------------------------------------------------

local function eval_conditions(conditions, scope)
    if not conditions then return true end
    for _, cond in ipairs(conditions) do
        local result = M._call_fn(cond.fn, cond.argv, scope)
        -- nil or false means condition failed
        if not result and result ~= false then
            -- nil return = condition not met
            return false
        end
        if result == false then
            return false
        end
        if cond.assign then
            scope[cond.assign] = result
        end
    end
    return true
end

---------------------------------------------------------------------------
-- Rule evaluation
---------------------------------------------------------------------------

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
    if type(endpoint.url) == "string" then
        url = resolve_template(endpoint.url, scope)
    elseif type(endpoint.url) == "table" then
        url = resolve_arg(endpoint.url, scope)
    end

    local headers
    if endpoint.headers then
        headers = {}
        for k, vals in pairs(endpoint.headers) do
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
    if endpoint.properties then
        properties = resolve_deep(endpoint.properties, scope)
    end

    return { url = url, headers = headers, properties = properties }
end

local function eval_rules(rules, scope)
    for _, rule in ipairs(rules) do
        -- Create a child scope for this rule's condition assignments
        local child = setmetatable({}, { __index = scope })

        if eval_conditions(rule.conditions, child) then
            if rule.type == "endpoint" then
                return eval_endpoint(rule.endpoint, child), nil
            elseif rule.type == "error" then
                local msg
                if type(rule.error) == "string" then
                    msg = resolve_template(rule.error, child)
                else
                    msg = resolve_arg(rule.error, child)
                end
                return nil, msg
            elseif rule.type == "tree" then
                local result, err = eval_rules(rule.rules, child)
                if result or err then
                    return result, err
                end
                -- Tree rules are terminal: if sub-rules exhausted, that's an error
                return nil, "rules exhausted in tree rule"
            end
        end
    end
    return nil, nil -- no rule matched (caller decides if this is an error)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Resolve an endpoint from a ruleset and parameters.
--- @param ruleset table: { parameters, rules } emitted by codegen
--- @param params table: parameter values
--- @return table|nil: { url, headers, properties } on success
--- @return string|nil: error message on failure
function M.resolve(ruleset, params)
    -- Build scope: apply defaults, check required
    local scope = {}
    if ruleset.parameters then
        for name, def in pairs(ruleset.parameters) do
            local val = params[name]
            if val == nil and def.default ~= nil then
                val = def.default
            end
            if val == nil then
                if def.required then
                    return nil, "required endpoint parameter missing: " .. name
                end
                scope[name] = UNSET
            else
                scope[name] = val
            end
        end
    end
    -- Also copy any params not in the parameter definitions
    for k, v in pairs(params) do
        if scope[k] == nil then
            scope[k] = v
        end
    end

    local result, err = eval_rules(ruleset.rules, scope)
    if result then return result, nil end
    if err then return nil, err end
    return nil, "endpoint rules exhausted without a match"
end

return M
