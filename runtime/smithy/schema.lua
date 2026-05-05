-- smithy-lua runtime: Schema type
-- A Schema is a runtime description of a Smithy shape used for generic serde.

local M = {}

-- Shape type constants
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
    DOCUMENT  = "document",
    ENUM      = "enum",
    INT_ENUM  = "int_enum",
    LIST      = "list",
    MAP       = "map",
    STRUCTURE = "structure",
    UNION     = "union",
}

-- Timestamp format constants
M.timestamp = {
    DATE_TIME     = "date-time",
    HTTP_DATE     = "http-date",
    EPOCH_SECONDS = "epoch-seconds",
}

-- Schema metatable
local Schema = {}
Schema.__index = Schema

--- Get the effective (merged) trait value for a trait key.
--- For member schemas this includes traits inherited from the target.
--- @param key table: a trait key from smithy.traits
--- @return table|nil: the trait record, or nil if not present
function Schema:trait(key)
    local t = self._traits
    if t then return t[key] end
    return nil
end

--- Get the direct trait value for a trait key.
--- For member schemas this returns only traits declared on the member itself.
--- For non-member schemas this is equivalent to trait().
--- @param key table: a trait key from smithy.traits
--- @return table|nil: the trait record, or nil if not present
function Schema:direct_trait(key)
    local dt = self._direct_traits
    if dt then return dt[key] end
    -- For non-member schemas, fall back to _traits
    local t = self._traits
    if t then return t[key] end
    return nil
end

--- Get a member schema by name.
--- @param name string: member name
--- @return table|nil: the member schema, or nil
function Schema:member(name)
    local m = self._members
    if m then return m[name] end
    local tgt = self._target
    if tgt then return tgt:member(name) end
    return nil
end

--- Get all members (name-indexed table).
--- @return table|nil
function Schema:members()
    local m = self._members
    if m then return m end
    local tgt = self._target
    if tgt then return tgt:members() end
    return nil
end

--- Create a new Schema.
--- @param args table: { id, type, members, traits, direct_traits, target_id, name, list_member, map_key, map_value }
--- @return table: Schema instance
function M.new(args)
    local s = setmetatable({
        id          = args.id,
        type        = args.type,
        target_id   = args.target_id,   -- member schemas: target shape id
        name        = args.name,         -- member schemas: member name string
        _target     = args.target,       -- member schemas: reference to target schema
        _traits     = args.traits,
        _direct_traits = args.direct_traits,
        _members    = args.members,
        list_member = args.list_member,  -- list schemas: element schema
        map_key     = args.map_key,      -- map schemas: key schema
        map_value   = args.map_value,    -- map schemas: value schema
    }, Schema)
    return s
end

return M
