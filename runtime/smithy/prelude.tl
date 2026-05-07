-- smithy-lua runtime: Prelude schemas

local id = require("smithy.shape_id")
local schema = require("smithy.schema")

local ns = "smithy.api"

local record M
    String: schema.Schema
    Blob: schema.Schema
    Boolean: schema.Schema
    Byte: schema.Schema
    Short: schema.Schema
    Integer: schema.Schema
    Long: schema.Schema
    Float: schema.Schema
    Double: schema.Schema
    BigInteger: schema.Schema
    BigDecimal: schema.Schema
    Timestamp: schema.Schema
    Document: schema.Schema
    Unit: schema.Schema
end

M.String    = schema.new({ id = id.from(ns, "String"),    type = "string" })
M.Blob      = schema.new({ id = id.from(ns, "Blob"),      type = "blob" })
M.Boolean   = schema.new({ id = id.from(ns, "Boolean"),   type = "boolean" })
M.Byte      = schema.new({ id = id.from(ns, "Byte"),      type = "byte" })
M.Short     = schema.new({ id = id.from(ns, "Short"),     type = "short" })
M.Integer   = schema.new({ id = id.from(ns, "Integer"),   type = "integer" })
M.Long      = schema.new({ id = id.from(ns, "Long"),      type = "long" })
M.Float     = schema.new({ id = id.from(ns, "Float"),     type = "float" })
M.Double    = schema.new({ id = id.from(ns, "Double"),    type = "double" })
M.BigInteger = schema.new({ id = id.from(ns, "BigInteger"), type = "bigInteger" })
M.BigDecimal = schema.new({ id = id.from(ns, "BigDecimal"), type = "bigDecimal" })
M.Timestamp = schema.new({ id = id.from(ns, "Timestamp"), type = "timestamp" })
M.Document  = schema.new({ id = id.from(ns, "Document"),  type = "document" })
M.Unit      = schema.new({ id = id.from(ns, "Unit"),      type = "structure" })

return M
