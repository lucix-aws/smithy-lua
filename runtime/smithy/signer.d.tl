-- Teal declarations for smithy-lua runtime/signer

local http = require("http")
local auth = require("auth")

local record M

    uri_encode: function(s: string, encode_slash: boolean): string
    sign: function(request: http.Request, identity: auth.Credentials, props: auth.SignerProperties): http.Request, table

end

return M
