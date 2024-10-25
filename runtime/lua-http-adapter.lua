local request = require('http.request')

local HTTPClient = {}

function HTTPClient.New(config)
    return setmetatable({
        Debug = config.Debug,
    }, { __index = HTTPClient })
end

function HTTPClient:Do(req)
    local adapted = request.new_from_uri(req.URL)
    adapted.headers:upsert(':method', req.Method)
    adapted.headers:upsert(':authority', req.Host)
    for header,value in pairs(req.Header._values) do -- TODO shouldn't access private
        -- host is a special case handled above
        if header ~= 'Host' then
            adapted.headers:upsert(header, value)
        end
    end
    adapted:set_body(req.Body)

    if self.Debug then
        print('[DEBUG] send request--------------------------------')
        for name, value, never_index in adapted.headers:each() do
            print(name, value, never_index)
        end
        print(req.Body)
        print('----------------------------------------------------')
        print('')
    end
    
    local headers, stream = adapted:go()
    local body = stream:get_body_as_string()

    if self.Debug then
        print('[DEBUG] recv response--------------------------------')
        for name, value, never_index in headers:each() do
            print(name, value, never_index)
        end
        print(body)
        print('-----------------------------------------------------')
        print('')
    end

    return {
        StatusCode = tonumber(headers:get(':status')),
        Body = body,
    }
end

return {
    HTTPClient = HTTPClient,
}
