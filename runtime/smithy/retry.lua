local M = {}


function M.none()
   return {
      acquire_token = function() return {} end,
      retry_token = function(_, _, err) return nil, err end,
      record_success = function() end,
   }
end

return M
