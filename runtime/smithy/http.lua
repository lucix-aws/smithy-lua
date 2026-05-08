

local async = require("smithy.async")

local M = { HttpClient = {}, Error = {}, Request = {}, Response = {} }



























function M.string_reader(s)
   local done = false
   return function()
      if done then return nil end
      done = true
      return s
   end
end

function M.read_all(reader)
   local chunks = {}
   while true do
      local chunk, err = reader()
      if err then return nil, err end
      if not chunk then break end
      chunks[#chunks + 1] = chunk
   end
   return table.concat(chunks)
end

function M.new_request(method, url, headers, body)
   return {
      method = method or "GET",
      url = url or "",
      headers = headers or {},
      body = body,
   }
end

return M
