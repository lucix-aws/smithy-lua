

local error_mod = require("smithy.error")
local retry_mod = require("smithy.retry")

local standard_mod = { Options = {} }

















standard_mod.DEFAULT_MAX_ATTEMPTS = 3
standard_mod.DEFAULT_MAX_BACKOFF = 20
standard_mod.DEFAULT_RATE_TOKENS = 500
standard_mod.DEFAULT_RETRY_COST = 5
standard_mod.DEFAULT_TIMEOUT_COST = 10
standard_mod.DEFAULT_NO_RETRY_INCREMENT = 1

math.randomseed(os.time())

local function backoff_delay(attempt, max_backoff)
   if attempt <= 0 then return 0 end
   local ceil = math.min(2 ^ attempt, max_backoff)
   return math.random() * ceil
end

function standard_mod.new(opts)
   opts = opts or {}
   local max_attempts = opts.max_attempts or standard_mod.DEFAULT_MAX_ATTEMPTS
   local max_backoff = opts.max_backoff or standard_mod.DEFAULT_MAX_BACKOFF
   local retry_cost = opts.retry_cost or standard_mod.DEFAULT_RETRY_COST
   local timeout_cost = opts.timeout_cost or standard_mod.DEFAULT_TIMEOUT_COST
   local no_retry_increment = opts.no_retry_increment or standard_mod.DEFAULT_NO_RETRY_INCREMENT

   local capacity = opts.rate_tokens or standard_mod.DEFAULT_RATE_TOKENS
   local max_capacity = capacity

   return {
      acquire_token = function(_self)
         return { attempt = 0 }
      end,

      retry_token = function(_self, token, err)
         token.attempt = token.attempt + 1
         if token.attempt >= max_attempts then
            return nil, err
         end
         if not error_mod.is_retryable(err) then
            return nil, err
         end

         local cost = error_mod.is_timeout(err) and timeout_cost or retry_cost
         if capacity < cost then
            return nil, err
         end
         capacity = capacity - cost
         token.cost = cost

         return backoff_delay(token.attempt, max_backoff)
      end,

      record_success = function(_self, token)
         if token.cost then
            capacity = math.min(max_capacity, capacity + token.cost)
         else
            capacity = math.min(max_capacity, capacity + no_retry_increment)
         end
      end,
   }
end

return standard_mod
