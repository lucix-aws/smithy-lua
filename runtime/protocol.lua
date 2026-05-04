-- smithy-lua runtime: ClientProtocol interface
--
-- A ClientProtocol serializes modeled input into an HTTP request and
-- deserializes an HTTP response into modeled output (or an error).
--
-- Implementations: protocol/awsjson.lua, protocol/restjson.lua, etc.
--
-- Interface (colon-call, self is implicit):
--   protocol:serialize(input, operation) -> request, err
--   protocol:deserialize(response, operation) -> output, err
--
-- See protocol.d.tl for the full Teal type.

return {}
