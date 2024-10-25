local http = require('./runtime/http')

local record module
    record Credentials
        AKID: string
        Secret: string
        SessionToken: string

        New: function(init: Credentials): Credentials
    end

    Sign: function(req: http.Request, creds: Credentials, service: string, region: string)
end

return module