local request = require('http.request')
local sigv4 = require('./runtime/sigv4')
local weather = require('./client')

-- http client adapter
local HTTPClient = {}

function HTTPClient:new()
    local t = {}
    setmetatable(t, self)
    self.__index = self
    return t
end

function HTTPClient:Do(req)
    local adapted = request.new_from_uri(req.URL)
    adapted.headers:upsert(':method', req.Method)
    for header,value in pairs(req.Header._values) do -- FIXME shouldn't access private
        adapted.headers:upsert(header, value)
    end
    adapted:set_body(req.Body)

    -- debug
    print('send request--------------------------------')
    for name, value, never_index in adapted.headers:each() do
        print(name, value, never_index)
    end
    print(req.Body)
    print('------------------------------------------')
    print('')
    
    print('recv response--------------------------------')
    local headers, stream = adapted:go()
    local body = stream:get_body_as_string()
    for name, value, never_index in headers:each() do
        print(name, value, never_index)
    end
    print(body)
    print('------------------------------------------')
    print('')


    local resp = {
        StatusCode = tonumber(headers:get(':status')),
        Body = body,
    }
    return resp
end

local client = weather:New({
    Region   = 'us-east-1',
    HTTPClient = HTTPClient:new(),
    Credentials = sigv4.Credentials:New{
        AKID = os.getenv('AWS_ACCESS_KEY_ID'),
        Secret = os.getenv('AWS_SECRET_ACCESS_KEY'), 
        SessionToken = os.getenv('AWS_SESSION_TOKEN'),
    },
})

print('akid:')
print(client._config.Credentials.AKID)
print('')

local out, err = client:ListQueues({})
print(out, err)
