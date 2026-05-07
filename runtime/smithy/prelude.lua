

local id = require("smithy.shape_id")
local schema = require("smithy.schema")

local ns = "smithy.api"

local M = {}
















M.String = schema.new({ id = id.from(ns, "String"), type = "string" })
M.Blob = schema.new({ id = id.from(ns, "Blob"), type = "blob" })
M.Boolean = schema.new({ id = id.from(ns, "Boolean"), type = "boolean" })
M.Byte = schema.new({ id = id.from(ns, "Byte"), type = "byte" })
M.Short = schema.new({ id = id.from(ns, "Short"), type = "short" })
M.Integer = schema.new({ id = id.from(ns, "Integer"), type = "integer" })
M.Long = schema.new({ id = id.from(ns, "Long"), type = "long" })
M.Float = schema.new({ id = id.from(ns, "Float"), type = "float" })
M.Double = schema.new({ id = id.from(ns, "Double"), type = "double" })
M.BigInteger = schema.new({ id = id.from(ns, "BigInteger"), type = "bigInteger" })
M.BigDecimal = schema.new({ id = id.from(ns, "BigDecimal"), type = "bigDecimal" })
M.Timestamp = schema.new({ id = id.from(ns, "Timestamp"), type = "timestamp" })
M.Document = schema.new({ id = id.from(ns, "Document"), type = "document" })
M.Unit = schema.new({ id = id.from(ns, "Unit"), type = "structure" })

return M
