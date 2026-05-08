-- smithy-lua runtime: shared REST protocol HTTP binding helpers

local json_codec = require("smithy.codec.json")
local base64 = require("smithy.base64")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local stype = schema_mod.type

local record M
    KEY_ONLY: table

    uri_encode: function(s: string, greedy?: boolean): string
    expand_path: function(template: string, labels: {string:any}): string
    format_query_value: function(v: any): string
    build_query: function(params: {string:any}): string
    format_header_value: function(v: any, member_schema: schema_mod.Schema): string
    parse_header_value: function(v: string, member_schema: schema_mod.Schema): any
    parse_http_date: function(v: string): number
    parse_header_list: function(v: string, member_schema: schema_mod.Schema): {any}
    bind_request: function(input: {string:any}, schema: schema_mod.Schema): {string:any}, {string:any}, {string:string}, string, schema_mod.Schema, {string:schema_mod.Schema}
    build_url: function(operation: schema_mod.OperationSchema, labels: {string:any}, query: {string:any}): string, string
    bind_response: function(response: http.Response, schema: schema_mod.Schema): {string:any}, string, schema_mod.Schema, {string:schema_mod.Schema}
    has_streaming_payload: function(schema: schema_mod.Schema): boolean
end

M.KEY_ONLY = {}

function M.uri_encode(s: string, greedy?: boolean): string
    s = tostring(s)
    local out: {string} = {}
    for i = 1, #s do
        local c = s:byte(i)
        if (c >= 0x41 and c <= 0x5A) or (c >= 0x61 and c <= 0x7A)
            or (c >= 0x30 and c <= 0x39) or c == 0x2D or c == 0x5F
            or c == 0x2E or c == 0x7E then
            out[#out + 1] = string.char(c)
        elseif c == 0x2F and greedy then
            out[#out + 1] = "/"
        else
            out[#out + 1] = string.format("%%%02X", c)
        end
    end
    return table.concat(out)
end

function M.expand_path(template: string, labels: {string:any}): string
    return (template:gsub("{([^}]+)}", function(label: string): string
        local greedy = label:sub(-1) == "+"
        local name = greedy and label:sub(1, -2) or label
        local v = labels[name]
        if v == nil then return "" end
        return M.uri_encode(tostring(v), greedy)
    end))
end

function M.format_query_value(v: any): string
    if type(v) == "number" then
        local n = v as number
        if n ~= n then return "NaN" end
        if n == math.huge then return "Infinity" end
        if n == -math.huge then return "-Infinity" end
    end
    return tostring(v)
end

function M.build_query(params: {string:any}): string
    local parts: {string} = {}
    local keys: {string} = {}
    for k in pairs(params) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = params[k]
        if v == M.KEY_ONLY then
            parts[#parts + 1] = M.uri_encode(k)
        elseif type(v) == "table" then
            for _, item in ipairs(v as {any}) do
                parts[#parts + 1] = M.uri_encode(k) .. "=" .. M.uri_encode(M.format_query_value(item))
            end
        elseif v == "" then
            parts[#parts + 1] = M.uri_encode(k) .. "="
        else
            parts[#parts + 1] = M.uri_encode(k) .. "=" .. M.uri_encode(M.format_query_value(v))
        end
    end
    if #parts == 0 then return "" end
    return "?" .. table.concat(parts, "&")
end

function M.format_header_value(v: any, member_schema: schema_mod.Schema): string
    if type(v) == "boolean" then return (v as boolean) and "true" or "false" end
    if type(v) == "number" then
        local n = v as number
        if n ~= n then return "NaN" end
        if n == math.huge then return "Infinity" end
        if n == -math.huge then return "-Infinity" end
    end
    if member_schema and (member_schema.type == "timestamp" or member_schema.type == stype.TIMESTAMP) then
        local ts_format = "http-date"
        local ts_trait = member_schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
        if ts_trait then ts_format = ts_trait.format end
        if ts_format == "http-date" then
            return json_codec._format_http_date(v as number)
        elseif ts_format == "date-time" then
            return json_codec._format_iso8601(v as number)
        else
            local n = v as number
            if n % 1 == 0 then return string.format("%.0f", n) end
            return tostring(n)
        end
    end
    if member_schema and member_schema:trait(t.MEDIA_TYPE) then
        return base64.encode(tostring(v))
    end
    if type(v) == "table" then
        local items: {string} = {}
        local elem = member_schema and member_schema.list_member
        for _, item in ipairs(v as {any}) do
            if elem and (elem.type == "timestamp" or elem.type == stype.TIMESTAMP) then
                local tf = "http-date"
                local tf_trait = elem:trait(t.TIMESTAMP_FORMAT) as {string:string}
                if tf_trait then tf = tf_trait.format end
                if tf == "http-date" then
                    items[#items + 1] = json_codec._format_http_date(item as number)
                elseif tf == "date-time" then
                    items[#items + 1] = json_codec._format_iso8601(item as number)
                else
                    local n = item as number
                    if n % 1 == 0 then items[#items + 1] = string.format("%.0f", n)
                    else items[#items + 1] = tostring(n) end
                end
            else
                local s = tostring(item)
                if s:find('[,"]') then
                    items[#items + 1] = '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
                else
                    items[#items + 1] = s
                end
            end
        end
        return table.concat(items, ", ")
    end
    return tostring(v)
end

function M.parse_header_value(v: string, member_schema: schema_mod.Schema): any
    local mtype = member_schema.type
    if mtype == "boolean" or mtype == stype.BOOLEAN then
        return (v == "true")
    elseif mtype == "timestamp" or mtype == stype.TIMESTAMP then
        local ts_format = "http-date"
        local ts_trait = member_schema:trait(t.TIMESTAMP_FORMAT) as {string:string}
        if ts_trait then ts_format = ts_trait.format end
        if ts_format == "http-date" then
            return M.parse_http_date(v)
        elseif ts_format == "date-time" then
            return json_codec._parse_iso8601(v)
        else
            return tonumber(v)
        end
    elseif member_schema:trait(t.MEDIA_TYPE) then
        return base64.decode(v)
    elseif mtype == "number" or mtype == "integer" or mtype == "long"
        or mtype == "float" or mtype == "double" or mtype == "short" or mtype == "byte"
        or mtype == stype.INTEGER or mtype == stype.LONG or mtype == stype.FLOAT
        or mtype == stype.DOUBLE or mtype == stype.SHORT or mtype == stype.BYTE then
        return tonumber(v)
    elseif mtype == "list" or mtype == stype.LIST then
        return M.parse_header_list(v, member_schema)
    else
        return v
    end
end

function M.parse_http_date(v: string): number
    local day_s, month_s, year_s, hour_s, min_s, sec_s = v:match(
        "%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
    if not day_s then return tonumber(v) as number end
    local months: {string:integer} = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
    local dt: {string:any} = {}
    dt.month = months[month_s] or 1
    dt.year = tonumber(year_s); dt.day = tonumber(day_s)
    dt.hour = tonumber(hour_s); dt.min = tonumber(min_s); dt.sec = tonumber(sec_s)
    dt.isdst = false
    local epoch = os.time(dt as os.DateTable)
    local utc_dt = os.date("!*t", 0) as os.DateTable
    local local_dt = os.date("*t", 0) as os.DateTable
    local utc_offset = os.time(utc_dt) - os.time(local_dt)
    return epoch - utc_offset
end

function M.parse_header_list(v: string, member_schema: schema_mod.Schema): {any}
    local items: {any} = {}
    local elem = member_schema.list_member

    local is_httpdate_list = false
    if elem and (elem.type == "timestamp" or elem.type == stype.TIMESTAMP) then
        local tf_trait = elem:trait(t.TIMESTAMP_FORMAT) as {string:string}
        local tf = tf_trait and tf_trait.format or "http-date"
        is_httpdate_list = (tf == "http-date")
    end

    if is_httpdate_list then
        local skip = true
        local j = 1
        for i = 1, #v do
            if v:sub(i, i) == "," then
                if skip then
                    skip = false
                else
                    skip = true
                    items[#items + 1] = v:sub(j, i - 1):match("^%s*(.-)%s*$")
                    j = i + 1
                end
            end
        end
        items[#items + 1] = v:sub(j):match("^%s*(.-)%s*$")
    else
        local i = 1
        while i <= #v do
            while i <= #v and v:sub(i,i) == " " do i = i + 1 end
            if i > #v then break end
            if v:sub(i,i) == '"' then
                i = i + 1
                local s: {string} = {}
                while i <= #v and v:sub(i,i) ~= '"' do
                    if v:sub(i,i) == '\\' then i = i + 1 end
                    s[#s+1] = v:sub(i,i)
                    i = i + 1
                end
                i = i + 1
                items[#items+1] = table.concat(s)
            else
                local j = v:find(",", i)
                if j then
                    items[#items+1] = v:sub(i, j-1):match("^%s*(.-)%s*$")
                    i = j
                else
                    items[#items+1] = v:sub(i):match("^%s*(.-)%s*$")
                    i = #v + 1
                end
            end
            while i <= #v and (v:sub(i,i) == "," or v:sub(i,i) == " ") do i = i + 1 end
        end
    end

    if elem then
        for idx, item in ipairs(items) do
            local etype = elem.type
            if etype == "integer" or etype == "long" or etype == "short"
                or etype == "byte" or etype == "float" or etype == "double"
                or etype == stype.INTEGER or etype == stype.LONG or etype == stype.SHORT
                or etype == stype.BYTE or etype == stype.FLOAT or etype == stype.DOUBLE then
                items[idx] = tonumber(item as string)
            elseif etype == "boolean" or etype == stype.BOOLEAN then
                items[idx] = ((item as string) == "true")
            elseif etype == "timestamp" or etype == stype.TIMESTAMP then
                local tf = "http-date"
                local tf_trait = elem:trait(t.TIMESTAMP_FORMAT) as {string:string}
                if tf_trait then tf = tf_trait.format end
                if tf == "http-date" then
                    items[idx] = M.parse_http_date(item as string)
                elseif tf == "date-time" then
                    items[idx] = json_codec._parse_iso8601(item as string)
                else
                    items[idx] = tonumber(item as string) or item
                end
            end
        end
    end
    return items
end

function M.bind_request(input: {string:any}, schema: schema_mod.Schema): {string:any}, {string:any}, {string:string}, string, schema_mod.Schema, {string:schema_mod.Schema}
    input = input or {}
    local members = schema and schema:members() or {} as {string:schema_mod.Schema}
    local labels: {string:any} = {}
    local query: {string:any} = {}
    local headers: {string:string} = {}
    local payload_name: string
    local payload_schema: schema_mod.Schema
    local body_members: {string:schema_mod.Schema} = {}

    for name, ms in pairs(members) do
        if ms:trait(t.IDEMPOTENCY_TOKEN) and input[name] == nil then
            input[name] = "00000000-0000-4000-8000-000000000000"
        end
    end

    for name, ms in pairs(members) do
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS) as {string:string}
        if pfx and type(input[name]) == "table" then
            for k, v in pairs(input[name] as {string:string}) do
                headers[pfx.prefix .. k] = tostring(v)
            end
        end
    end

    for name, ms in pairs(members) do
        local lbl = ms:trait(t.HTTP_LABEL)
        local qry = ms:trait(t.HTTP_QUERY) as {string:string}
        local qp = ms:trait(t.HTTP_QUERY_PARAMS)
        local hdr = ms:trait(t.HTTP_HEADER) as {string:string}
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS)
        local pld = ms:trait(t.HTTP_PAYLOAD)

        if lbl then
            local lv: any = input[name]
            if (ms.type == "timestamp" or ms.type == stype.TIMESTAMP) and type(lv) == "number" then
                local ts_trait = ms:trait(t.TIMESTAMP_FORMAT) as {string:string}
                local tf = ts_trait and ts_trait.format or "date-time"
                if tf == "date-time" then
                    lv = json_codec._format_iso8601(lv as number)
                elseif tf == "http-date" then
                    lv = json_codec._format_http_date(lv as number)
                end
            elseif type(lv) == "number" then
                local n = lv as number
                if n ~= n then lv = "NaN"
                elseif n == math.huge then lv = "Infinity"
                elseif n == -math.huge then lv = "-Infinity"
                end
            end
            labels[name] = lv
        elseif qry then
            if input[name] ~= nil then
                local qv: any = input[name]
                if ms.type == "timestamp" or ms.type == stype.TIMESTAMP then
                    local ts_trait = ms:trait(t.TIMESTAMP_FORMAT) as {string:string}
                    local tf = ts_trait and ts_trait.format or "date-time"
                    if tf == "date-time" then
                        qv = json_codec._format_iso8601(qv as number)
                    elseif tf == "http-date" then
                        qv = json_codec._format_http_date(qv as number)
                    end
                elseif (ms.type == "list" or ms.type == stype.LIST)
                    and ms.list_member
                    and (ms.list_member.type == "timestamp" or ms.list_member.type == stype.TIMESTAMP) then
                    local tf_trait = ms.list_member:trait(t.TIMESTAMP_FORMAT) as {string:string}
                    local tf = tf_trait and tf_trait.format or "date-time"
                    local formatted: {any} = {}
                    for _, item in ipairs(qv as {any}) do
                        if tf == "date-time" then
                            formatted[#formatted+1] = json_codec._format_iso8601(item as number)
                        elseif tf == "http-date" then
                            formatted[#formatted+1] = json_codec._format_http_date(item as number)
                        else
                            formatted[#formatted+1] = item
                        end
                    end
                    qv = formatted
                end
                query[qry.name] = qv
            end
        elseif qp then
            if type(input[name]) == "table" then
                for k, v in pairs(input[name] as {string:any}) do
                    if not query[k] then query[k] = v end
                end
            end
        elseif hdr then
            if input[name] ~= nil then
                headers[hdr.name] = M.format_header_value(input[name], ms)
            end
        elseif pfx then
            -- Already handled
        elseif pld then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    return labels, query, headers, payload_name, payload_schema, body_members
end

function M.build_url(operation: schema_mod.OperationSchema, labels: {string:any}, query: {string:any}): string, string
    local http_trait = operation:trait(t.HTTP) as {string:string}
    local path = M.expand_path(http_trait and http_trait.path or "/", labels)
    local base_path, existing_qs = path:match("^([^?]*)%??(.*)")
    if existing_qs and #existing_qs > 0 then
        for pair in existing_qs:gmatch("[^&]+") do
            local k, eq, v = pair:match("^([^=]*)(=?)(.*)")
            if k and not query[k] then
                if eq == "=" then
                    query[k] = v
                else
                    query[k] = M.KEY_ONLY
                end
            end
        end
    end
    return base_path .. M.build_query(query), http_trait and http_trait.method or "POST"
end

function M.bind_response(response: http.Response, schema: schema_mod.Schema): {string:any}, string, schema_mod.Schema, {string:schema_mod.Schema}
    local members = schema and schema:members() or {} as {string:schema_mod.Schema}
    local output: {string:any} = {}
    local payload_name: string
    local payload_schema: schema_mod.Schema
    local body_members: {string:schema_mod.Schema} = {}

    for name, ms in pairs(members) do
        local rc = ms:trait(t.HTTP_RESPONSE_CODE)
        local hdr = ms:trait(t.HTTP_HEADER) as {string:string}
        local pfx = ms:trait(t.HTTP_PREFIX_HEADERS) as {string:string}
        local pld = ms:trait(t.HTTP_PAYLOAD)

        if rc then
            output[name] = response.status_code
        elseif hdr then
            local v = response.headers and (response.headers[hdr.name] or response.headers[hdr.name:lower()])
            if v ~= nil then
                output[name] = M.parse_header_value(v, ms)
            end
        elseif pfx then
            local prefix = pfx.prefix:lower()
            local map: {string:string} = {}
            if response.headers then
                for k, hv in pairs(response.headers) do
                    if k:lower():sub(1, #prefix) == prefix then
                        map[k:sub(#prefix + 1)] = hv
                    end
                end
            end
            output[name] = map
        elseif pld then
            payload_name = name
            payload_schema = ms
        else
            body_members[name] = ms
        end
    end

    return output, payload_name, payload_schema, body_members
end

function M.has_streaming_payload(schema: schema_mod.Schema): boolean
    local members = schema and schema:members() or {} as {string:schema_mod.Schema}
    for _, ms in pairs(members) do
        if ms:trait(t.HTTP_PAYLOAD) and ms:trait(t.STREAMING) then
            return true
        end
    end
    return false
end

return M
