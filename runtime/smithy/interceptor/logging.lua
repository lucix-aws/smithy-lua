

local http = require("smithy.http")

local M = { Interceptor = {} }








local Interceptor = {}
Interceptor.__index = Interceptor

function M.new()
   return setmetatable({}, Interceptor)
end

(Interceptor).read_before_transmit = function(self, ctx)
   local req = ctx.request
   local headers = req.headers
   io.stderr:write("~~ SDK Request ~~\n")
   io.stderr:write((req.method) .. " " .. (req.url) .. "\n")
   for k, v in pairs(headers) do
      io.stderr:write(k .. ": " .. v .. "\n")
   end
   if req.body then
      local body, _ = http.read_all(req.body)
      if body then
         io.stderr:write("\n" .. body .. "\n")
         req.body = http.string_reader(body)
      end
   end
   io.stderr:write("\n")
end;

(Interceptor).read_after_transmit = function(self, ctx)
   local resp = ctx.response
   local headers = resp.headers
   io.stderr:write("~~ SDK Response ~~\n")
   io.stderr:write(tostring(resp.status_code) .. "\n")
   for k, v in pairs(headers) do
      io.stderr:write(k .. ": " .. v .. "\n")
   end
   io.stderr:write("\n")
end

return M
