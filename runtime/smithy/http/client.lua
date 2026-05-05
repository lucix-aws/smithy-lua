

local http_mod = require("smithy.http")

local client_mod = {}







local backends = {
   { name = "curl_ffi", mod = "http.curl_ffi" },
   { name = "curl_subprocess", mod = "http.curl_subprocess" },
}

function client_mod.resolve()
   for _, b in ipairs(backends) do
      local ok, mod = pcall(require, b.mod)
      if ok then
         local m = mod
         local avail = m.available
         if avail() then
            local new_fn = m.new
            return new_fn(), nil
         end
      end
   end
   return nil, { type = "sdk", code = "NoHTTPClient", message = "no HTTP client backend available" }
end

return client_mod
