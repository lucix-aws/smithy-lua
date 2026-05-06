-- smithy-lua runtime: restXml protocol
-- REST-style protocol with XML body (S3, CloudFront, Route 53).

local json_codec = require("smithy.codec.json")
local xml_codec = require("smithy.codec.xml")
local http = require("smithy.http")
local schema_mod = require("smithy.schema")
local t = require("smithy.traits")
local stype = schema_mod.type
local rest = require("smithy.protocol.rest")

local M = {}
M.__index = M

function M.new(settings)
    settings = settings or {}
    return setmetatable({
        codec = xml_codec.new({
            default_timestamp_format = schema_mod.timestamp.DATE_TIME,
        }),
        no_error_wrapping = settings.no_error_wrapping or false,
        xml_namespace = settings.xml_namespace,
    }, M)
end

function M.serialize(self, input, service, operation)
    input = input or {}
    local schema = operation.input

    local labels, query, headers, payload_name, payload_schema, body_members =
        rest.bind_request(input, schema)

    local url, method = rest.build_url(operation, labels, query)

    -- Build body
    local body_str
    if payload_name then
        local v = input[payload_name]
        if v == nil then
            if payload_schema.type == stype.STRUCTURE then
                local xml_name = payload_schema:trait(t.XML_NAME)
                local root = xml_name and xml_name.name or payload_name
                body_str = "<" .. root .. "/>"
            else
                body_str = ""
            end
        elseif payload_schema.type == stype.STRUCTURE or payload_schema.type == stype.UNION then
            headers["Content-Type"] = "application/xml"
            local target_schema = payload_schema._target or payload_schema
            local xml_name_trait = payload_schema:trait(t.XML_NAME) or target_schema:trait(t.XML_NAME)
            local root = (xml_name_trait and xml_name_trait.name)
                or (target_schema.id and target_schema.id.name)
                or payload_name
            local err
            body_str, err = self.codec:serialize(v, payload_schema, root)
            if err then return nil, err end
            if self.xml_namespace and body_str and #body_str > 0 then
                local ns_attr = ' xmlns="' .. self.xml_namespace.uri .. '"'
                body_str = body_str:gsub("^(<" .. root .. ")", "%1" .. ns_attr, 1)
            end
        elseif payload_schema.type == stype.DOCUMENT then
            body_str = require("smithy.json.encoder").encode(v)
        elseif payload_schema.type == stype.BLOB then
            body_str = v
            local mt = payload_schema:trait(t.MEDIA_TYPE)
            if mt then
                headers["Content-Type"] = mt.value
            elseif not headers["Content-Type"] then
                headers["Content-Type"] = "application/octet-stream"
            end
        elseif payload_schema.type == stype.STRING or payload_schema.type == stype.ENUM then
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
            headers["Content-Type"] = "application/xml"
            local xml_name = schema:trait(t.XML_NAME)
            local root = xml_name and xml_name.name or (schema.id and schema.id.name) or "root"
            local body_schema = schema_mod.new({ type = stype.STRUCTURE, members = body_members, traits = schema._traits })
            local err
            body_str, err = self.codec:serialize(input, body_schema, root)
            if err then return nil, err end
            if self.xml_namespace and body_str and #body_str > 0 then
                local ns_attr = ' xmlns="' .. self.xml_namespace.uri .. '"'
                body_str = body_str:gsub("^(<" .. root .. ")", "%1" .. ns_attr, 1)
            end
        elseif next(body_members) then
            headers["Content-Type"] = "application/xml"
            body_str = ""
        else
            body_str = ""
        end
    end

    return http.new_request(method, url, headers, http.string_reader(body_str)), nil
end

-- Parse error from XML response
local function parse_xml_error(body_str, no_error_wrapping)
    if not body_str or #body_str == 0 then return "UnknownError", "" end
    local node = xml_codec.parse_xml(body_str)
    if not node then return "UnknownError", "" end

    local error_node
    if no_error_wrapping then
        error_node = node
    else
        for _, child in ipairs(node.children or {}) do
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

function M.deserialize(self, response, operation)
    local schema = operation.output
    local streaming = rest.has_streaming_payload(schema)

    local body_str, read_err
    if streaming and response.status_code >= 200 and response.status_code < 300 then
        body_str = nil
    else
        body_str, read_err = http.read_all(response.body)
        if read_err then
            return nil, { type = "http", code = "ResponseReadError", message = read_err }
        end
    end

    if response.status_code < 200 or response.status_code >= 300 then
        local code, message = parse_xml_error(body_str, self.no_error_wrapping)
        return nil, {
            type = "api",
            code = code,
            message = message,
            status_code = response.status_code,
        }
    end

    local output, payload_name, payload_schema, body_members =
        rest.bind_response(response, schema)

    if payload_name then
        if payload_schema:trait(t.STREAMING) then
            output[payload_name] = response.body
        elseif body_str and #body_str > 0 then
            if payload_schema.type == stype.STRUCTURE or payload_schema.type == stype.UNION then
                local v, err = self.codec:deserialize(body_str, payload_schema)
                if err then return nil, err end
                output[payload_name] = v
            elseif payload_schema.type == stype.DOCUMENT then
                output[payload_name] = require("smithy.json.decoder").decode(body_str)
            elseif payload_schema.type == stype.BLOB or payload_schema.type == stype.STRING then
                output[payload_name] = body_str
            else
                output[payload_name] = body_str
            end
        end
    elseif body_str and #body_str > 0 then
        local body_schema = schema_mod.new({ type = stype.STRUCTURE, members = body_members })
        local decoded, err = self.codec:deserialize(body_str, body_schema)
        if err then return nil, err end
        for k, v in pairs(decoded) do output[k] = v end
    end

    return output, nil
end

return M
