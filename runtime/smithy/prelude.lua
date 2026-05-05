-- smithy-lua runtime: Prelude schemas
-- Canonical schema instances for Smithy prelude simple types.

local id = require("smithy.shape_id")
local schema = require("smithy.schema")

local ns = "smithy.api"

return {
    String    = schema.new({ id = id.from(ns, "String"),    type = "string" }),
    Blob      = schema.new({ id = id.from(ns, "Blob"),      type = "blob" }),
    Boolean   = schema.new({ id = id.from(ns, "Boolean"),   type = "boolean" }),
    Byte      = schema.new({ id = id.from(ns, "Byte"),      type = "byte" }),
    Short     = schema.new({ id = id.from(ns, "Short"),     type = "short" }),
    Integer   = schema.new({ id = id.from(ns, "Integer"),   type = "integer" }),
    Long      = schema.new({ id = id.from(ns, "Long"),      type = "long" }),
    Float     = schema.new({ id = id.from(ns, "Float"),     type = "float" }),
    Double    = schema.new({ id = id.from(ns, "Double"),    type = "double" }),
    Timestamp = schema.new({ id = id.from(ns, "Timestamp"), type = "timestamp" }),
    Document  = schema.new({ id = id.from(ns, "Document"),  type = "document" }),
    Unit      = schema.new({ id = id.from(ns, "Unit"),      type = "structure" }),
}
