-- HTTP client resolver: probes available backends and returns the best one.
-- Resolution order: CRT > libcurl FFI > curl subprocess

local http = require("smithy.http")

local record Backend
    name: string
    mod: string
end

local record M
    record ResolveError
        type: string
        code: string
        message: string
    end

    resolve: function(): http.HttpClient, M.ResolveError
end

local backends: {Backend} = {
    { name = "crt",             mod = "aws_crt.http" },
    { name = "curl_ffi",        mod = "smithy.http.curl_ffi" },
    { name = "curl_subprocess", mod = "smithy.http.curl_subprocess" },
}

local record BackendModule
    available: function(): boolean
    new: function(): http.HttpClient
end

function M.resolve(): http.HttpClient, M.ResolveError
    for _, b in ipairs(backends) do
        local ok, mod = pcall(require, b.mod) as (boolean, BackendModule)
        if ok and mod.available() then
            return mod.new(), nil
        end
    end
    return nil, { type = "sdk", code = "NoHTTPClient", message = "no HTTP client backend available" }
end

return M
