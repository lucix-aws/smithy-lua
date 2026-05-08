


local http = require("smithy.http")






local M = { ResolveError = {} }









local backends = {
   { name = "crt", mod = "aws_crt.http" },
   { name = "curl_async", mod = "smithy.http.curl_async" },
   { name = "curl_ffi", mod = "smithy.http.curl_ffi" },
   { name = "curl_subprocess", mod = "smithy.http.curl_subprocess" },
}






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
