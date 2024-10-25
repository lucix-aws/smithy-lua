local http = require('./runtime/http')

local record module
    record Config
        Debug: boolean
    end

    record HTTPClient
        New: function(cfg: Config): HTTPClient
        Do: function(self, req: http.Request): http.Response
    end
end

return module