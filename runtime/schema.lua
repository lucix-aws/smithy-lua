-- smithy-lua runtime: schema types and helpers
-- A schema is a runtime description of a Smithy shape used for generic serde.

local M = {}

-- Shape type constants
M.type = {
    BOOLEAN   = "boolean",
    BYTE      = "byte",
    SHORT     = "short",
    INTEGER   = "integer",
    LONG      = "long",
    FLOAT     = "float",
    DOUBLE    = "double",
    STRING    = "string",
    ENUM      = "enum",
    INT_ENUM  = "int_enum",
    BLOB      = "blob",
    TIMESTAMP = "timestamp",
    DOCUMENT  = "document",
    LIST      = "list",
    MAP       = "map",
    STRUCTURE = "structure",
    UNION     = "union",
}

-- Trait key constants (used in member/shape traits tables)
M.trait = {
    JSON_NAME        = "json_name",
    XML_NAME         = "xml_name",
    XML_ATTRIBUTE    = "xml_attribute",
    XML_FLATTENED    = "xml_flattened",
    XML_NAMESPACE    = "xml_namespace",
    TIMESTAMP_FORMAT = "timestamp_format",
    HTTP_HEADER      = "http_header",
    HTTP_LABEL       = "http_label",
    HTTP_QUERY       = "http_query",
    HTTP_QUERY_PARAMS = "http_query_params",
    HTTP_PAYLOAD     = "http_payload",
    HTTP_PREFIX_HEADERS = "http_prefix_headers",
    HTTP_RESPONSE_CODE  = "http_response_code",
    SPARSE           = "sparse",
    REQUIRED         = "required",
    SENSITIVE        = "sensitive",
    STREAMING        = "streaming",
    IDEMPOTENCY_TOKEN = "idempotency_token",
    HOST_LABEL       = "host_label",
    CONTEXT_PARAM    = "context_param",
}

-- Timestamp format constants
M.timestamp = {
    DATE_TIME      = "date-time",
    HTTP_DATE      = "http-date",
    EPOCH_SECONDS  = "epoch-seconds",
}

--- Look up a member schema by name.
--- @param schema table: a structure or union schema
--- @param name string: member name
--- @return table|nil: the member schema, or nil
function M.member(schema, name)
    local members = schema.members
    if not members then return nil end
    return members[name]
end

return M
