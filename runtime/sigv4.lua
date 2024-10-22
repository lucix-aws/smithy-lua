local module = {}

module.Credentials = {}

function module.Credentials:New()
    local t = {
        AKID         = nil,
        Secret       = nil,
        SessionToken = nil,
    }
    setmetatable(t, self)
    self.__index = self
    return t
end

function module.SignRequest(req, creds, service, region)
    local now = os.date()
    req.Header:Set("Host", req.URL)
    req.Header:Set("X-Amz-Date", longTime(now))
    if creds.SessionToken ~= nil then
        req.Header:Set("X-Amz-Session-Token", creds.SessionToken)
    end
end

local function credentialScope(time, region, service)
    return shortTime(time) .. '/' .. region .. '/' .. service .. '/aws4_request'
end

local function shortTime(time)
    return os.date("!%Y%m%d", time)
end

local function longTime(time)
    return os.date("!%Y%m%dT%H%M%SZ", time)
end

return module
