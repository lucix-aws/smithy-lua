local http = require('./runtime/http')
local json = require('./runtime/json')
local sigv4 = require('./runtime/sigv4')
local Client = {}

local function _do(client, input, target)
    local req = http.Request:New()

    local endpoint = 'https://sqs.'..client._config.Region..'.amazonaws.com'
    req.URL = endpoint
    req.Host = 'sqs.'..client._config.Region..'.amazonaws.com'

    req.Method = 'POST'
    req.Header:Set("Content-Type", "application/x-amz-json-1.0")
    req.Header:Set("X-Amz-Target", target)
    req.Body = json.encode(input)

    sigv4.Sign(req, client._config.Credentials, 'sqs', client._config.Region)

    local resp = client._config.HTTPClient:Do(req)
    if resp.StatusCode < 200 or resp.StatusCode >= 300 then
        return nil, 'error: http ' .. resp.StatusCode
    end

    return json.decode(resp.Body), nil
end

function Client:New(config)
    local t = {
        _config = {
            Region      = config.Region,
            Credentials = config.Credentials,
            HTTPClient  = config.HTTPClient,
        },
    }
    setmetatable(t, self)
    self.__index = self

    return t
end

function Client:GetCity(input)
    return _do(self, input, "Weather.GetCity")
end

function Client:GetCurrentTime(input)
    return _do(self, input, "Weather.GetCurrentTime")
end

function Client:GetForecast(input)
    return _do(self, input, "Weather.GetForecast")
end

function Client:ListCities(input)
    return _do(self, input, "Weather.ListCities")
end

return Client
