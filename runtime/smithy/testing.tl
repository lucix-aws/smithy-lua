-- smithy-lua runtime: test helpers for protocol tests

local http = require("smithy.http")
local json_decoder = require("smithy.json.decoder")
local base64 = require("smithy.base64")

local M = {}

function M.read_body(body: any): string
    if not body then return "" end
    if type(body) == "string" then return body as string end
    return http.read_all(body as http.Reader) or ""
end

function M.base64_decode(s: string): string
    return base64.decode(s)
end

-- URL helpers

local function parse_path(url: string): string
    local path: string
    if url:match("^https?://") then
        path = url:match("^https?://[^/]*(/.*)$") or "/"
    else
        path = url
    end
    local p = path:match("^([^?]*)") or path
    return p
end

local function parse_query(url: string): string
    return url:match("%?(.*)$")
end

function M.assert_url_path(url: string, expected: string)
    local actual = parse_path(url)
    -- normalize trailing slash
    if expected ~= "/" and expected:sub(-1) == "/" then
        expected = expected:sub(1, -2)
    end
    if actual ~= "/" and actual:sub(-1) == "/" then
        actual = actual:sub(1, -2)
    end
    assert(actual == expected, "URL path mismatch: expected '" .. expected .. "', got '" .. actual .. "' (full URL: " .. url .. ")")
end

function M.assert_query_param(url: string, param: string)
    local qs = parse_query(url)
    assert(qs, "expected query string in URL: " .. url)
    -- param is "key=value" — check it exists in the query string
    for part in qs:gmatch("[^&]+") do
        if part == param then return end
    end
    assert(false, "query param '" .. param .. "' not found in: " .. qs)
end

function M.assert_no_query_param(url: string, param: string)
    local qs = parse_query(url)
    if not qs then return end
    for part in qs:gmatch("[^&]+") do
        if part == param then
            assert(false, "query param '" .. param .. "' should NOT be present in: " .. qs)
        end
    end
end

function M.assert_has_query_key(url: string, key: string)
    local qs = parse_query(url)
    assert(qs, "expected query string in URL: " .. url)
    for part in qs:gmatch("[^&]+") do
        local k = part:match("^([^=]*)")
        if k == key then return end
    end
    assert(false, "query key '" .. key .. "' not found in: " .. qs)
end

-- Header helpers

function M.assert_header(request: {string:any}, name: string, expected: string)
    local headers = request.headers as {string:string}
    local lower_name = name:lower()
    for k, v in pairs(headers) do
        if k:lower() == lower_name then
            assert(v == expected, "header '" .. name .. "': expected '" .. expected .. "', got '" .. v .. "'")
            return
        end
    end
    assert(false, "header '" .. name .. "' not found")
end

function M.assert_no_header(request: {string:any}, name: string)
    local headers = request.headers as {string:string}
    local lower_name = name:lower()
    for k, _ in pairs(headers) do
        if k:lower() == lower_name then
            assert(false, "header '" .. name .. "' should NOT be present")
        end
    end
end

-- Deep equality

local function deep_eq(a: any, b: any): boolean
    if a == b then return true end
    -- NaN == NaN (both are number, both fail == self)
    if type(a) == "number" and type(b) == "number" then
        if a ~= a and b ~= b then return true end
        return false
    end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    local ta = a as {any:any}
    local tb = b as {any:any}
    for k, v in pairs(ta) do
        local bv = tb[k]
        if bv == nil then
            -- actual has key, expected doesn't: allow if value is empty string or empty table
            if v == "" then -- ok, skip
            elseif type(v) == "table" and next(v as {any:any}) == nil then -- ok, skip
            else return false end
        elseif not deep_eq(v, bv) then return false end
    end
    for k, _ in pairs(tb) do
        if ta[k] == nil then return false end
    end
    return true
end

local function format_value(v: any, depth: integer): string
    depth = depth or 0
    if depth > 5 then return "..." end
    if type(v) == "string" then return "\"" .. (v as string) .. "\"" end
    if type(v) ~= "table" then return tostring(v) end
    local t = v as {any:any}
    local parts: {string} = {}
    for k, val in pairs(t) do
        parts[#parts+1] = tostring(k) .. "=" .. format_value(val, depth+1)
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

function M.assert_deep_eq(actual: any, expected: any, label: string)
    if not deep_eq(actual, expected) then
        local msg = (label or "value") .. " mismatch:\n  expected: " .. format_value(expected, 0) .. "\n  actual:   " .. format_value(actual, 0)
        error(msg, 2)
    end
end

-- Body comparison helpers

function M.assert_json_eq(actual: string, expected: string)
    local a, err_a = json_decoder.decode(actual)
    assert(not err_a, "failed to decode actual JSON: " .. tostring(err_a) .. "\n  body: " .. actual)
    local b, err_b = json_decoder.decode(expected)
    assert(not err_b, "failed to decode expected JSON: " .. tostring(err_b))
    if not deep_eq(a, b) then
        error("JSON mismatch:\n  expected: " .. expected .. "\n  actual:   " .. actual, 2)
    end
end

function M.assert_xml_eq(actual: string, expected: string)
    -- Simple XML tree parser for comparison
    local record XNode
        tag: string
        attrs: {string:string}
        children: {XNode}
        text: string
    end

    local function parse_xml(s: string): XNode
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
        local stack: {XNode} = { { tag = "_root", attrs = {}, children = {}, text = "" } }

        local pos = 1
        while pos <= #s do
            local ts, te, slash, tag, attr_str, self_close = s:find("<(/?)([%w:%-]+)(.-)(/?)>", pos)
            if not ts then
                -- remaining text
                local txt = s:sub(pos):gsub("^%s+", ""):gsub("%s+$", "")
                if #txt > 0 then stack[#stack].text = (stack[#stack].text or "") .. txt end
                break
            end
            -- text before this tag
            if ts > pos then
                local txt = s:sub(pos, ts - 1):gsub("^%s+", ""):gsub("%s+$", "")
                if #txt > 0 then stack[#stack].text = (stack[#stack].text or "") .. txt end
            end
            if slash == "/" then
                -- closing tag
                local node = table.remove(stack) as XNode
                local parent = stack[#stack]
                parent.children[#parent.children + 1] = node
            elseif self_close == "/" then
                -- self-closing
                local node: XNode = { tag = tag, attrs = {}, children = {}, text = "" }
                for k, v in (attr_str as string):gmatch("([%w:%-]+)=\"([^\"]*)\"") do
                    node.attrs[k] = v
                end
                stack[#stack].children[#stack[#stack].children + 1] = node
            else
                -- opening tag
                local node: XNode = { tag = tag, attrs = {}, children = {}, text = "" }
                for k, v in (attr_str as string):gmatch("([%w:%-]+)=\"([^\"]*)\"") do
                    node.attrs[k] = v
                end
                stack[#stack + 1] = node
            end
            pos = te + 1
        end
        local root = stack[1]
        if #root.children == 1 then return root.children[1] end
        return root
    end

    local function xml_eq(a: XNode, b: XNode): boolean
        if a.tag ~= b.tag then return false end
        if (a.text or "") ~= (b.text or "") then return false end
        -- compare attrs
        for k, v in pairs(a.attrs) do
            if b.attrs[k] ~= v then return false end
        end
        for k, _ in pairs(b.attrs) do
            if a.attrs[k] == nil then return false end
        end
        -- compare children (order-independent: match by tag+text)
        if #a.children ~= #b.children then return false end
        local used: {integer:boolean} = {}
        for _, ac in ipairs(a.children) do
            local found = false
            for j, bc in ipairs(b.children) do
                if not used[j] and xml_eq(ac, bc) then
                    used[j] = true
                    found = true
                    break
                end
            end
            if not found then return false end
        end
        return true
    end

    local a = parse_xml(actual)
    local b = parse_xml(expected)
    if not xml_eq(a, b) then
        error("XML mismatch:\n  expected: " .. expected .. "\n  actual:   " .. actual, 2)
    end
end

function M.assert_form_eq(actual: string, expected: string)
    -- Parse form params into sorted sets and compare
    local function parse_form(s: string): {string}
        local params: {string} = {}
        for p in s:gmatch("[^&]+") do
            params[#params+1] = p
        end
        table.sort(params)
        return params
    end
    local ap = parse_form(actual)
    local ep = parse_form(expected)
    if #ap ~= #ep then
        error("form param count mismatch: expected " .. #ep .. ", got " .. #ap .. "\n  expected: " .. expected .. "\n  actual:   " .. actual, 2)
    end
    for i = 1, #ap do
        if ap[i] ~= ep[i] then
            error("form param mismatch at " .. i .. ": expected '" .. ep[i] .. "', got '" .. ap[i] .. "'", 2)
        end
    end
end

function M.assert_cbor_eq(actual: string, expected: string)
    local cbor = require("smithy.codec.cbor") as {string:any}
    local decode = cbor.decode_item as function(string, integer): any, integer
    local a = decode(actual, 1)
    local b = decode(expected, 1)
    if not deep_eq(a, b) then
        error("CBOR mismatch", 2)
    end
end

return M
