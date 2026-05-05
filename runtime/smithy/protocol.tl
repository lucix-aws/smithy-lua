-- smithy-lua runtime: ClientProtocol interface

local http = require("smithy.http")

local record M
    interface ClientProtocol
        serialize: function(self: ClientProtocol, input: any, operation: any): http.Request, any
        deserialize: function(self: ClientProtocol, response: http.Response, operation: any): any, any
    end
end

return M
