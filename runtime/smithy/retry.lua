

local retry_mod = { Token = {}, Retryer = {} }












function retry_mod.none()
   return {
      acquire_token = function(_self)
         return { attempt = 0 }
      end,
      retry_token = function(_self, _token, err)
         return nil, err
      end,
      record_success = function(_self, _token) end,
   }
end

return retry_mod
