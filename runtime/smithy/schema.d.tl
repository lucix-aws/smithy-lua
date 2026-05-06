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

    -- Timestamp format constants
    record timestamp
        DATE_TIME: string
        HTTP_DATE: string
        EPOCH_SECONDS: string
    end

    -- A schema describes a Smithy data shape at runtime.
    record Schema
        id: ShapeId
        type: string
        members: {string: Schema}
        member: Schema
        key: Schema
        value: Schema
        _traits: {any: any}
        error: string

        trait: function(Schema, key: any): any
        direct_trait: function(Schema, key: any): any
        member: function(Schema, name: string): Schema
        members: function(Schema): {string: Schema}
    end

    -- A service schema describes a Smithy service shape.
    record ServiceSchema
        id: ShapeId
        version: string
        _traits: {any: any}

        trait: function(ServiceSchema, key: any): any
    end

    -- An operation schema describes a Smithy operation shape.
    record OperationSchema
        id: ShapeId
        input: Schema
        output: Schema
        errors: {Schema}
        _traits: {any: any}

        trait: function(OperationSchema, key: any): any
    end

    -- Constructors
    new: function(args: table): Schema
    service: function(args: table): ServiceSchema
    operation: function(args: table): OperationSchema

end

return schema
