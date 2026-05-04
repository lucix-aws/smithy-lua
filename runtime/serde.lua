-- smithy-lua runtime: serde codec interface
-- A codec serializes/deserializes Lua values using schemas.

local M = {}

--- Codec interface (for documentation; implementations are plain tables).
---
--- A codec provides:
---   serialize(self, value, schema) -> string, err
---     Serialize a Lua value to bytes according to its schema.
---
---   deserialize(self, bytes, schema) -> value, err
---     Deserialize bytes into a Lua value according to its schema.

return M
