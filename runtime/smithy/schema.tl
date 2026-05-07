-- smithy-lua runtime: Schema type

local record M
    -- Shape type constants
    enum ShapeType
        "blob"
        "boolean"
        "string"
        "timestamp"
        "byte"
        "short"
        "integer"
        "long"
        "float"
        "double"
        "bigInteger"
        "bigDecimal"
        "document"
        "enum"
        "int_enum"
        "list"
        "map"
        "structure"
        "union"
    end

    type: {string:string}
    timestamp: {string:string}

    record Schema
        id: any
        type: string
        target_id: any
        name: string
        list_member: Schema
        map_key: Schema
        map_value: Schema
        _target: Schema
        _traits: {any:any}
        _direct_traits: {any:any}
        _members: {string:Schema}

        trait: function(Schema, any): any
        direct_trait: function(Schema, any): any
        member: function(Schema, string): Schema
        members: function(Schema): {string:Schema}
    end

    record ServiceSchema
        id: any
        version: string
        _traits: {any:any}

        trait: function(ServiceSchema, any): any
    end

    record OperationSchema
        id: any
        input: Schema
        output: Schema
        errors: {Schema}
        _traits: {any:any}

        trait: function(OperationSchema, any): any
    end

    new: function(args: {string:any}): Schema
    service: function(args: {string:any}): ServiceSchema
    operation: function(args: {string:any}): OperationSchema
end

M.type = {
    BLOB      = "blob",
    BOOLEAN   = "boolean",
    STRING    = "string",
    TIMESTAMP = "timestamp",
    BYTE      = "byte",
    SHORT     = "short",
    INTEGER   = "integer",
    LONG      = "long",
    FLOAT     = "float",
    DOUBLE    = "double",
    BIG_INTEGER = "bigInteger",
    BIG_DECIMAL = "bigDecimal",
    DOCUMENT  = "document",
    ENUM      = "enum",
    INT_ENUM  = "int_enum",
    LIST      = "list",
    MAP       = "map",
    STRUCTURE = "structure",
    UNION     = "union",
}

M.timestamp = {
    DATE_TIME     = "date-time",
    HTTP_DATE     = "http-date",
    EPOCH_SECONDS = "epoch-seconds",
}

local Schema_mt: metatable<M.Schema> = { __index = {} as M.Schema }
local schema_index = Schema_mt.__index as M.Schema

function schema_index:trait(key: any): any
    local t = self._traits
    if t then return t[key] end
    return nil
end

function schema_index:direct_trait(key: any): any
    local dt = self._direct_traits
    if dt then return dt[key] end
    local t = self._traits
    if t then return t[key] end
    return nil
end

function schema_index:member(name: string): M.Schema
    local m = self._members
    if m then return m[name] end
    local tgt = self._target
    if tgt then return tgt:member(name) end
    return nil
end

function schema_index:members(): {string:M.Schema}
    local m = self._members
    if m then return m end
    local tgt = self._target
    if tgt then return tgt:members() end
    return nil
end

function M.new(args: {string:any}): M.Schema
    return setmetatable({
        id          = args.id,
        type        = args.type as string,
        target_id   = args.target_id,
        name        = args.name as string,
        _target     = args.target as M.Schema,
        _traits     = args.traits as {any:any},
        _direct_traits = args.direct_traits as {any:any},
        _members    = args.members as {string:M.Schema},
        list_member = args.list_member as M.Schema,
        map_key     = args.map_key as M.Schema,
        map_value   = args.map_value as M.Schema,
    } as M.Schema, Schema_mt)
end

local ServiceSchema_mt: metatable<M.ServiceSchema> = { __index = {} as M.ServiceSchema }
local service_index = ServiceSchema_mt.__index as M.ServiceSchema

function service_index:trait(key: any): any
    local t = self._traits
    if t then return t[key] end
    return nil
end

function M.service(args: {string:any}): M.ServiceSchema
    return setmetatable({
        id       = args.id,
        version  = args.version as string,
        _traits  = args.traits as {any:any},
    } as M.ServiceSchema, ServiceSchema_mt)
end

local OperationSchema_mt: metatable<M.OperationSchema> = { __index = {} as M.OperationSchema }
local op_index = OperationSchema_mt.__index as M.OperationSchema

function op_index:trait(key: any): any
    local t = self._traits
    if t then return t[key] end
    return nil
end

function M.operation(args: {string:any}): M.OperationSchema
    return setmetatable({
        id      = args.id,
        input   = args.input as M.Schema,
        output  = args.output as M.Schema,
        errors  = args.errors as {M.Schema},
        _traits = args.traits as {any:any},
    } as M.OperationSchema, OperationSchema_mt)
end

return M
