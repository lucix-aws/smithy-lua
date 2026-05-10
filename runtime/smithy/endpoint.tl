local partitions = require("smithy.endpoint.partitions")

local record M
    record Endpoint
        url: string
        headers: {string:{string}}
        properties: {string:any}
    end

    record Condition
        fn: string
        argv: {any}
        assign: string
    end

    record Rule
        type: string
        conditions: {Condition}
        rules: {Rule}
        endpoint: {string:any}
        error: any
    end

    record Parameter
        type: string
        default: any
        required: boolean
    end

    record Ruleset
        version: string
        parameters: {string:Parameter}
        rules: {Rule}
    end

    _call_fn: function(string, {any}, {string: any}): any
    resolve: function(ruleset: {string:any}, params: {string:any}): Endpoint, string
end

local UNSET: table = {}

---------------------------------------------------------------------------
-- Template string resolution
---------------------------------------------------------------------------

local function get_attr(obj: any, path: string): any
    local cur = obj
    for part in (path as string):gmatch("[^.]+") do
        if cur == nil then return nil end
        local key, idx_str = part:match("^(.-)%[(-?%d+)%]$")
        if key then
            if key ~= "" then cur = (cur as table)[key] end
            local idx = tonumber(idx_str) as integer
            if idx < 0 then
                idx = #(cur as {any}) + idx + 1
            else
                idx = idx + 1
            end
            cur = (cur as table)[idx]
        else
            cur = (cur as table)[part]
        end
    end
    return cur
end

local function resolve_template(tmpl: any, scope: {string: any}): any
    if type(tmpl) ~= "string" then return tmpl end
    return ((tmpl as string):gsub("{([^}]+)}", function(expr: string): string
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

local function fn_isSet(args: {any}): boolean
    return args[1] ~= nil and args[1] ~= UNSET
end

local function fn_not(args: {any}): boolean
    return not args[1]
end

local function fn_booleanEquals(args: {any}): boolean
    return args[1] == args[2]
end

local function fn_stringEquals(args: {any}): boolean
    return args[1] == args[2]
end

local function fn_getAttr(args: {any}): any
    return get_attr(args[1], args[2] as string)
end

local function fn_isValidHostLabel(args: {any}): boolean
    local value = args[1] as string
    local allow_sub = args[2] as boolean
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

local function fn_parseURL(args: {any}): table
    local url = args[1] as string
    if type(args[1]) ~= "string" then return nil as table end
    if url:find("?", 1, true) then return nil as table end
    if url:find("#", 1, true) then return nil as table end

    local scheme, rest = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://(.+)$")
    if not scheme then return nil as table end
    scheme = scheme:lower()

    local authority: string
    local path: string
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

local function fn_substring(args: {any}): string
    local input = args[1] as string
    local start_idx = args[2] as integer
    local end_idx = args[3] as integer
    local reverse = args[4] as boolean
    if type(args[1]) ~= "string" then return nil as string end
    if input:match("[\128-\255]") then return nil as string end
    local len = #input
    if end_idx - start_idx <= 0 then return nil as string end
    if reverse then
        local orig_start = start_idx
        start_idx = len - end_idx
        end_idx = len - orig_start
    end
    if start_idx < 0 or end_idx > len then return nil as string end
    return input:sub(start_idx + 1, end_idx)
end

local function fn_uriEncode(args: {any}): string
    local s = args[1] as string
    if type(args[1]) ~= "string" then return "" end
    return (s:gsub("([^A-Za-z0-9%-_.~])", function(c: string): string
        return string.format("%%%02X", string.byte(c))
    end))
end

local function fn_split(args: {any}): {string}
    local value = args[1] as string
    local delimiter = args[2] as string
    local limit = args[3] as integer
    if type(args[1]) ~= "string" or type(args[2]) ~= "string" or delimiter == "" then
        return {}
    end
    local result: {string} = {}
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

local function fn_coalesce(args: {any}): any
    for i = 1, #args - 1 do
        if args[i] ~= nil and args[i] ~= UNSET then
            return args[i]
        end
    end
    return args[#args]
end

local function fn_ite(args: {any}): any
    if args[1] then return args[2] else return args[3] end
end

---------------------------------------------------------------------------
-- AWS library functions
---------------------------------------------------------------------------

local function fn_aws_partition(args: {any}): table
    local region = args[1] as string
    if type(args[1]) ~= "string" or region == "" then return nil as table end
    return partitions.get_partition(region) as table
end

local function fn_aws_parseArn(args: {any}): table
    local value = args[1] as string
    if type(args[1]) ~= "string" then return nil as table end
    local parts: {string} = {}
    for part in (value .. ":"):gmatch("([^:]*):") do
        parts[#parts + 1] = part
    end
    if #parts < 6 then return nil as table end
    if parts[1] ~= "arn" then return nil as table end
    if parts[2] == "" or parts[3] == "" then return nil as table end

    local resource_str = table.concat(parts, ":", 6)
    if resource_str == "" then return nil as table end
    local resource_id: {string} = {}
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

local function fn_aws_isVirtualHostableS3Bucket(args: {any}): boolean
    local value = args[1] as string
    local allow_sub = args[2] as boolean
    if type(args[1]) ~= "string" or #value < 3 then return false end
    if value:find("..", 1, true) then return false end
    if value:match("^%d+%.%d+%.%d+%.%d+$") then return false end

    local check_segment = function(seg: string): boolean
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

local type FnType = function({any}): any
local _isSet = fn_isSet as FnType
local _not = fn_not as FnType
local _booleanEquals = fn_booleanEquals as FnType
local _stringEquals = fn_stringEquals as FnType
local _isValidHostLabel = fn_isValidHostLabel as FnType
local _parseURL = fn_parseURL as FnType
local _substring = fn_substring as FnType
local _uriEncode = fn_uriEncode as FnType
local _split = fn_split as FnType
local _aws_partition = fn_aws_partition as FnType
local _aws_parseArn = fn_aws_parseArn as FnType
local _aws_isVirtualHostableS3Bucket = fn_aws_isVirtualHostableS3Bucket as FnType

local functions: {string: FnType} = {
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

---------------------------------------------------------------------------
-- Argument resolution
---------------------------------------------------------------------------

local function resolve_arg(a: any, scope: {string: any}): any
    if type(a) == "table" then
        local t = a as table
        if (t as {string:any})["ref"] then
            local val = scope[(t as {string:any})["ref"] as string]
            if val == UNSET then return nil end
            return val
        end
        if (t as {string:any})["fn"] then
            return M._call_fn((t as {string:any})["fn"] as string, (t as {string:any})["argv"] as {any}, scope)
        end
    end
    if type(a) == "string" then
        return resolve_template(a, scope)
    end
    return a
end

function M._call_fn(name: string, argv: {any}, scope: {string: any}): any
    local fn = functions[name]
    if not fn then
        error("unknown endpoint rules function: " .. tostring(name))
    end
    local resolved: {any} = {}
    if name == "isSet" then
        local a = argv[1]
        if type(a) == "table" and (a as {string:any})["ref"] then
            local val = scope[(a as {string:any})["ref"] as string]
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

local function eval_conditions(conditions: {M.Condition}, scope: {string: any}): boolean
    if not conditions then return true end
    for _, cond in ipairs(conditions) do
        local result = M._call_fn(cond.fn, cond.argv, scope)
        if not result and result ~= false then
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

local function resolve_deep(val: any, scope: {string: any}): any
    if type(val) == "string" then
        return resolve_template(val, scope)
    elseif type(val) == "table" then
        local out: {any: any} = {}
        for k, v in pairs(val as {any: any}) do
            out[k] = resolve_deep(v, scope)
        end
        return out
    end
    return val
end

local function eval_endpoint(endpoint: {string: any}, scope: {string: any}): M.Endpoint
    local url: any
    if type(endpoint["url"]) == "string" then
        url = resolve_template(endpoint["url"], scope)
    elseif type(endpoint["url"]) == "table" then
        url = resolve_arg(endpoint["url"], scope)
    end

    local headers: {string: {string}}
    if endpoint["headers"] then
        headers = {}
        for k, vals in pairs(endpoint["headers"] as {string: {any}}) do
            local resolved_vals: {string} = {}
            for _, v in ipairs(vals) do
                if type(v) == "string" then
                    resolved_vals[#resolved_vals + 1] = resolve_template(v, scope) as string
                else
                    resolved_vals[#resolved_vals + 1] = resolve_arg(v, scope) as string
                end
            end
            headers[k] = resolved_vals
        end
    end

    local properties: any
    if endpoint["properties"] then
        properties = resolve_deep(endpoint["properties"], scope)
    end

    return { url = url as string, headers = headers, properties = properties } as M.Endpoint
end

local function eval_rules(rules: {M.Rule}, scope: {string: any}): M.Endpoint, string
    for _, rule in ipairs(rules) do
        local child = setmetatable({} as {string: any}, { __index = scope })

        if eval_conditions(rule.conditions, child) then
            if rule.type == "endpoint" then
                return eval_endpoint(rule.endpoint as {string: any}, child), nil as string
            elseif rule.type == "error" then
                local msg: string
                if type(rule.error) == "string" then
                    msg = resolve_template(rule.error, child) as string
                else
                    msg = resolve_arg(rule.error, child) as string
                end
                return nil as M.Endpoint, msg
            elseif rule.type == "tree" then
                local result, err = eval_rules(rule.rules, child)
                if result or err then
                    return result, err
                end
                return nil as M.Endpoint, "rules exhausted in tree rule"
            end
        end
    end
    return nil as M.Endpoint, nil as string
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.resolve(ruleset: {string:any}, params: {string: any}): M.Endpoint, string
    local scope: {string: any} = {}
    if ruleset["parameters"] then
        for name, def_any in pairs(ruleset["parameters"] as {string: any}) do
            local def = def_any as {string: any}
            local val = params[name]
            if val == nil and def["default"] ~= nil then
                val = def["default"]
            end
            if val == nil then
                if def["required"] then
                    return nil as M.Endpoint, "required endpoint parameter missing: " .. name
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

    local result, err = eval_rules(ruleset["rules"] as {M.Rule}, scope)
    if result then return result, nil as string end
    if err then return nil as M.Endpoint, err end
    return nil as M.Endpoint, "endpoint rules exhausted without a match"
end

return M
