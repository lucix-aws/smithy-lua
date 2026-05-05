-- smithy-lua runtime: schema types and helpers

local record schema_mod
    record Schema
        type: string
        members: {string:Schema}
        member: Schema
        value: Schema
        traits: {string:any}
    end

    type: {string:string}
    trait: {string:string}
    timestamp: {string:string}
end

schema_mod.type = {
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

schema_mod.trait = {
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
    EC2_QUERY_NAME   = "ec2_query_name",
    AWS_QUERY_ERROR  = "aws_query_error",
    DEFAULT          = "default",
    MEDIA_TYPE       = "media_type",
    EVENT_HEADER     = "event_header",
    EVENT_PAYLOAD    = "event_payload",
}

schema_mod.timestamp = {
    DATE_TIME      = "date-time",
    HTTP_DATE      = "http-date",
    EPOCH_SECONDS  = "epoch-seconds",
}

function schema_mod.member(schema: schema_mod.Schema, name: string): schema_mod.Schema
    local members = schema.members
    if not members then return nil end
    return members[name]
end

return schema_mod
