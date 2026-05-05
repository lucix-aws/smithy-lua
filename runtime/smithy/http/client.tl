-- HTTP client resolver: probes available backends and returns the best one.

local http_mod = require("smithy.http")

local record client_mod
end

local record Backend
    name: string
    mod: string
end

local backends: {Backend} = {
    { name = "curl_ffi",        mod = "http.curl_ffi" },
    { name = "curl_subprocess", mod = "http.curl_subprocess" },
}

function client_mod.resolve(): http_mod.HttpClient, any
    for _, b in ipairs(backends) do
        local ok, mod = pcall(require, b.mod) as (boolean, any)
        if ok then
            local m = mod as {string:any}
            local avail = m.available as function(): boolean
            if avail() then
                local new_fn = m.new as function(): http_mod.HttpClient
                return new_fn(), nil
            end
        end
    end
    return nil, { type = "sdk", code = "NoHTTPClient", message = "no HTTP client backend available" }
end

return client_mod
