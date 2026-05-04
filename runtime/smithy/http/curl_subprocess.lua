-- HTTP client using curl subprocess fallback.
-- Conforms to: function(request) -> response, err

local http = require("smithy.http")

local M = {}

--- Check if this backend is available.
function M.available()
    local h = io.popen("curl --version 2>/dev/null")
    if not h then return false end
    local out = h:read("*a")
    h:close()
    return out and out:match("curl") ~= nil
end

--- Create an HTTP client backed by curl subprocess.
function M.new()
    return function(request)
        -- Read body
        local body = ""
        if request.body then
            local b, err = http.read_all(request.body)
            if err then return nil, { type = "http", code = "ReadError", message = err } end
            body = b or ""
        end

        -- Write curl config file (avoids shell escaping)
        local cfg = os.tmpname()
        local body_in = os.tmpname()
        local body_out = os.tmpname()
        local hdr_out = os.tmpname()

        local f = io.open(cfg, "w")
        f:write('silent\nshow-error\n')
        f:write('request = "' .. request.method .. '"\n')
        f:write('output = "' .. body_out .. '"\n')
        f:write('dump-header = "' .. hdr_out .. '"\n')
        f:write('write-out = "%{http_code}"\n')
        for k, v in pairs(request.headers or {}) do
            f:write('header = "' .. k .. ': ' .. v .. '"\n')
        end
        if #body > 0 then
            local bf = io.open(body_in, "wb")
            bf:write(body)
            bf:close()
            f:write('data-binary = "@' .. body_in .. '"\n')
        end
        f:write('url = "' .. request.url .. '"\n')
        f:close()

        local pipe = io.popen('curl -K "' .. cfg .. '" 2>/dev/null', "r")
        local status_str = pipe:read("*a") or ""
        pipe:close()
        os.remove(cfg)
        os.remove(body_in)

        local status_code = tonumber(status_str:match("(%d+)"))
        if not status_code then
            os.remove(body_out)
            os.remove(hdr_out)
            return nil, { type = "http", code = "CurlError", message = "failed to parse status from curl" }
        end

        -- Parse response headers
        local headers = {}
        local hf = io.open(hdr_out, "r")
        if hf then
            for line in hf:lines() do
                local k, v = line:match("^([^:]+):%s*(.-)%s*$")
                if k then headers[k:lower()] = v end
            end
            hf:close()
        end
        os.remove(hdr_out)

        -- Read response body
        local resp_body = ""
        local bf = io.open(body_out, "rb")
        if bf then
            resp_body = bf:read("*a") or ""
            bf:close()
        end
        os.remove(body_out)

        return {
            status_code = status_code,
            headers = headers,
            body = http.string_reader(resp_body),
        }, nil
    end
end

return M
