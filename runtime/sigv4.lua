local hash = require('./hash')
local strings = require('./strings')

local module = {}

module.Credentials = {}

function module.Credentials:New(o)
    o = o or {}
    local t = {
        AKID         = o.AKID,
        Secret       = o.Secret,
        SessionToken = o.SessionToken,
    }
    setmetatable(t, self)
    self.__index = self
    return t
end

local function shortTime(time)
    return os.date("!%Y%m%d", time)
end

local function longTime(time)
    return os.date("!%Y%m%dT%H%M%SZ", time)
end

local function credentialScope(time, region, service)
    return shortTime(time) .. '/' .. region .. '/' .. service .. '/aws4_request'
end

-- FIXME assumes headers do not have multiple values
local function buildCanonicalHeaders(req)
    local canon = {}
    local signed = {}

    -- FIXME should not be accessing _values
    for header,value in pairs(req.Header._values) do
        header = header:lower()
        if header == 'host' or strings.StartsWith(header, 'x-amz-') then
            -- is signed
            signed[#signed+1] = header
            canon[header] = value
        end
    end

    table.sort(signed)

    local canonStr = ''
    for i=1,#signed do
        canonStr = canonStr .. signed[i] .. ':'
        canonStr = canonStr .. canon[signed[i]] .. '\n'
    end

    return canonStr, strings.Join(signed, ';')
end

local function buildCanonicalRequest(req, payloadHash)
    -- FIXME assumes awsJson
    local path = '/'
    local query = ''

    local headers, signedHeaders = buildCanonicalHeaders(req)

    return req.Method .. '\n' ..
        path .. '\n' ..
        query .. '\n' ..
        headers .. '\n' ..
        signedHeaders .. '\n' ..
        strings.StrToHex(payloadHash), signedHeaders
end

local function buildStringToSign(canonicalRequest, time, scope)
    return 'AWS4-HMAC-SHA256' .. '\n' ..
        longTime(time) .. '\n' ..
        scope .. '\n' ..
        strings.StrToHex(hash.SHA256(canonicalRequest))
end

local function signString(str)
    return 'TODO'
end

function module.Sign(req, creds, service, region)
    local now = os.time()
    local scope = credentialScope(now, region, service)

    req.Header:Set("Host", req.URL)
    req.Header:Set("X-Amz-Date", longTime(now))
    if creds.SessionToken ~= nil then
        req.Header:Set("X-Amz-Session-Token", creds.SessionToken)
    end

    local payloadHash = hash.SHA256(req.Body)

    local canonReq, signedHeader = buildCanonicalRequest(req, payloadHash)
    local toSign = buildStringToSign(canonReq, now, scope)
    local signature = signString(toSign)

    local credential = creds.AKID .. '/' .. scope
    req.Header:Set('Authorization',
        'AWS4-HMAC-SHA256 Credential='..credential..', SignedHeaders='..signedHeader..', Signature='..signature)
end

--test
local http = require('./http')
local req = http.Request:New()
req.Method = 'POST'
req.Header:Set('Host', 'AmazonS3.PutObject')
req.Header:Set('X-Amz-Target', 'AmazonS3.PutObject')
req.Header:Set('Content-Type', 'application/xml')
req.Body = '{}'
local creds = module.Credentials:New {
    AKID = "AKID",
    Secret = "SECRET",
}

module.Sign(req, creds, 's3', 'us-east-50')
print(req.Header:Get('Authorization'))

return module
