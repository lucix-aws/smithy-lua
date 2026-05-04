-- HTTP client resolver: probes available backends and returns the best one.
-- Resolution order: luasocket+luasec > libcurl FFI > curl subprocess

local M = {}

local backends = {
    { name = "curl_ffi",        mod = "http.curl_ffi" },
    { name = "curl_subprocess", mod = "http.curl_subprocess" },
}

--- Resolve the best available HTTP client.
--- @return function, nil: http_client function, or nil + error
function M.resolve()
    for _, b in ipairs(backends) do
        local ok, mod = pcall(require, b.mod)
        if ok and mod.available() then
            return mod.new(), nil
        end
    end
    return nil, { type = "sdk", code = "NoHTTPClient", message = "no HTTP client backend available" }
end

return M
