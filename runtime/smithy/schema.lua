

local M = { Schema = {}, ServiceSchema = {}, OperationSchema = {} }




































































M.type = {
   BLOB = "blob",
   BOOLEAN = "boolean",
   STRING = "string",
   TIMESTAMP = "timestamp",
   BYTE = "byte",
   SHORT = "short",
   INTEGER = "integer",
   LONG = "long",
   FLOAT = "float",
   DOUBLE = "double",
   BIG_INTEGER = "bigInteger",
   BIG_DECIMAL = "bigDecimal",
   DOCUMENT = "document",
   ENUM = "enum",
   INT_ENUM = "int_enum",
   LIST = "list",
   MAP = "map",
   STRUCTURE = "structure",
   UNION = "union",
}

M.timestamp = {
   DATE_TIME = "date-time",
   HTTP_DATE = "http-date",
   EPOCH_SECONDS = "epoch-seconds",
}

local Schema_mt = { __index = {} }
local schema_index = Schema_mt.__index

function schema_index:trait(key)
   local t = self._traits
   if t then return t[key] end
   return nil
end

function schema_index:direct_trait(key)
   local dt = self._direct_traits
   if dt then return dt[key] end
   local t = self._traits
   if t then return t[key] end
   return nil
end

function schema_index:member(name)
   local m = self._members
   if m then return m[name] end
   local tgt = self._target
   if tgt then return tgt:member(name) end
   return nil
end

function schema_index:members()
   local m = self._members
   if m then return m end
   local tgt = self._target
   if tgt then return tgt:members() end
   return nil
end

function M.new(args)
   return setmetatable({
      id = args.id,
      type = args.type,
      target_id = args.target_id,
      name = args.name,
      _target = args.target,
      _traits = args.traits,
      _direct_traits = args.direct_traits,
      _members = args.members,
      list_member = args.list_member,
      map_key = args.map_key,
      map_value = args.map_value,
   }, Schema_mt)
end

local ServiceSchema_mt = { __index = {} }
local service_index = ServiceSchema_mt.__index

function service_index:trait(key)
   local t = self._traits
   if t then return t[key] end
   return nil
end

function M.service(args)
   return setmetatable({
      id = args.id,
      version = args.version,
      _traits = args.traits,
   }, ServiceSchema_mt)
end

local OperationSchema_mt = { __index = {} }
local op_index = OperationSchema_mt.__index

function op_index:trait(key)
   local t = self._traits
   if t then return t[key] end
   return nil
end

function M.operation(args)
   return setmetatable({
      id = args.id,
      input = args.input,
      output = args.output,
      errors = args.errors,
      _traits = args.traits,
   }, OperationSchema_mt)
end

return M
