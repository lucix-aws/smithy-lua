

local id = require("smithy.shape_id")

local M = { TraitKey = {} }





































M.JSON_NAME = { id = id.from("smithy.api", "jsonName") }
M.XML_NAME = { id = id.from("smithy.api", "xmlName") }
M.XML_ATTRIBUTE = { id = id.from("smithy.api", "xmlAttribute") }
M.XML_FLATTENED = { id = id.from("smithy.api", "xmlFlattened") }
M.XML_NAMESPACE = { id = id.from("smithy.api", "xmlNamespace") }
M.TIMESTAMP_FORMAT = { id = id.from("smithy.api", "timestampFormat") }
M.MEDIA_TYPE = { id = id.from("smithy.api", "mediaType") }
M.HTTP_HEADER = { id = id.from("smithy.api", "httpHeader") }
M.HTTP_LABEL = { id = id.from("smithy.api", "httpLabel") }
M.HTTP_QUERY = { id = id.from("smithy.api", "httpQuery") }
M.HTTP_QUERY_PARAMS = { id = id.from("smithy.api", "httpQueryParams") }
M.HTTP_PAYLOAD = { id = id.from("smithy.api", "httpPayload") }
M.HTTP_PREFIX_HEADERS = { id = id.from("smithy.api", "httpPrefixHeaders") }
M.HTTP_RESPONSE_CODE = { id = id.from("smithy.api", "httpResponseCode") }
M.REQUIRED = { id = id.from("smithy.api", "required") }
M.DEFAULT = { id = id.from("smithy.api", "default") }
M.SPARSE = { id = id.from("smithy.api", "sparse") }
M.IDEMPOTENCY_TOKEN = { id = id.from("smithy.api", "idempotencyToken") }
M.STREAMING = { id = id.from("smithy.api", "streaming") }
M.SENSITIVE = { id = id.from("smithy.api", "sensitive") }
M.HOST_LABEL = { id = id.from("smithy.api", "hostLabel") }
M.EVENT_HEADER = { id = id.from("smithy.api", "eventHeader") }
M.EVENT_PAYLOAD = { id = id.from("smithy.api", "eventPayload") }
M.ERROR = { id = id.from("smithy.api", "error") }
M.HTTP = { id = id.from("smithy.api", "http") }
M.AUTH = { id = id.from("smithy.api", "auth") }
M.CONTEXT_PARAMS = { id = id.from("smithy.rules", "contextParams") }
M.STATIC_CONTEXT_PARAMS = { id = id.from("smithy.rules", "staticContextParams") }
M.EVENT_STREAM = { id = id.from("smithy.api", "eventStream") }
M.AWS_QUERY_ERROR = { id = id.from("aws.protocols", "awsQueryError") }
M.EC2_QUERY_NAME = { id = id.from("aws.protocols", "ec2QueryName") }

return M
