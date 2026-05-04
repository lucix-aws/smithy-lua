-- Teal declarations for runtime/schema.lua

local record schema

    -- Shape type constants
    record type
        BOOLEAN: string
        BYTE: string
        SHORT: string
        INTEGER: string
        LONG: string
        FLOAT: string
        DOUBLE: string
        STRING: string
        ENUM: string
        INT_ENUM: string
        BLOB: string
        TIMESTAMP: string
        DOCUMENT: string
        LIST: string
        MAP: string
        STRUCTURE: string
        UNION: string
    end

    -- Trait key constants
    record trait
        JSON_NAME: string
        XML_NAME: string
        XML_ATTRIBUTE: string
        XML_FLATTENED: string
        XML_NAMESPACE: string
        TIMESTAMP_FORMAT: string
        HTTP_HEADER: string
        HTTP_LABEL: string
        HTTP_QUERY: string
        HTTP_QUERY_PARAMS: string
        HTTP_PAYLOAD: string
        HTTP_PREFIX_HEADERS: string
        HTTP_RESPONSE_CODE: string
        SPARSE: string
        REQUIRED: string
        SENSITIVE: string
        STREAMING: string
        IDEMPOTENCY_TOKEN: string
        HOST_LABEL: string
        CONTEXT_PARAM: string
    end

    -- Timestamp format constants
    record timestamp
        DATE_TIME: string
        HTTP_DATE: string
        EPOCH_SECONDS: string
    end

    -- Schema types
    record MemberSchema
        name: string
        target: Schema
        traits: {string: any}
    end

    record Schema
        id: string
        type: string
        members: {MemberSchema}
        member: Schema
        key: Schema
        value: Schema
        traits: {string: any}
    end

    -- Look up a member schema by name
    member: function(schema: Schema, name: string): MemberSchema

end

return schema
