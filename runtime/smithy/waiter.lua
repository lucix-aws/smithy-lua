

local M = { PathMatcher = {}, Matcher = {}, Acceptor = {}, WaiterConfig = {}, WaitOptions = {} }


































local function eval_path(obj, path)
   local segments = {}
   for seg in path:gmatch("[^.]+") do
      segments[#segments + 1] = seg
   end

   local function resolve(val, idx)
      if idx > #segments then return val end
      if type(val) ~= "table" then return nil end

      local seg = segments[idx]
      local field_name = seg:match("^(.-)%[%]$")
      if field_name then
         local tval = val
         if field_name ~= "" then
            val = tval[field_name]
            if type(val) ~= "table" then return nil end
         end
         if idx == #segments then return val end
         local out = {}
         for _, item in ipairs(val) do
            local r = resolve(item, idx + 1)
            if type(r) == "table" and #(r) > 0 and idx + 1 <= #segments and segments[idx + 1]:find("%[%]$") then
               for _, v in ipairs(r) do out[#out + 1] = v end
            elseif r ~= nil then
               out[#out + 1] = r
            end
         end
         return out
      else
         return resolve((val)[seg], idx + 1)
      end
   end

   return resolve(obj, 1)
end

local function match_comparator(comparator, value, expected)
   if comparator == "stringEquals" then
      return tostring(value) == expected
   elseif comparator == "booleanEquals" then
      return tostring(value) == expected
   elseif comparator == "allStringEquals" then
      if type(value) ~= "table" then return false end
      local arr = value
      if #arr == 0 then return false end
      for _, v in ipairs(arr) do
         if tostring(v) ~= expected then return false end
      end
      return true
   elseif comparator == "anyStringEquals" then
      if type(value) ~= "table" then return false end
      for _, v in ipairs(value) do
         if tostring(v) == expected then return true end
      end
      return false
   end
   return false
end

local function eval_acceptor(acceptor, input, output, err)
   local matcher = acceptor.matcher

   if matcher.success ~= nil then
      if matcher.success == true and not err then return acceptor.state end
      if matcher.success == false and err then return acceptor.state end
      return nil
   end

   if matcher.errorType then
      if err then
         local e = err
         if e.code == matcher.errorType then return acceptor.state end
      end
      return nil
   end

   if err then return nil end

   if matcher.output then
      local val = eval_path(output, matcher.output.path)
      if match_comparator(matcher.output.comparator, val, matcher.output.expected) then
         return acceptor.state
      end
      return nil
   end

   if matcher.inputOutput then
      local synthetic = { input = input, output = output }
      local val = eval_path(synthetic, matcher.inputOutput.path)
      if match_comparator(matcher.inputOutput.comparator, val, matcher.inputOutput.expected) then
         return acceptor.state
      end
      return nil
   end

   return nil
end

function M.compute_delay(attempt, min_delay, max_delay)
   if attempt <= 1 then return min_delay end
   local delay = min_delay * (2 ^ (attempt - 1))
   if delay > max_delay then delay = max_delay end
   if delay > min_delay then
      delay = min_delay + math.random() * (delay - min_delay)
   end
   return delay
end

local function sleep(seconds)
   local ok, socket = pcall(require, "socket")
   if ok and (socket).sleep then
      local sleep_fn = (socket).sleep
      sleep_fn(seconds)
   else
      local target = os.clock() + seconds
      while os.clock() < target do end
   end
end

function M.wait(client, operation_fn, input, waiter_config, options)
   options = options or {}
   local max_wait = options.max_wait_time
   if not max_wait or max_wait <= 0 then
      return nil, { type = "sdk", code = "WaiterInvalidConfig", message = "max_wait_time is required and must be > 0" }
   end

   local min_delay = waiter_config.min_delay or 2
   local max_delay = waiter_config.max_delay or 120
   local acceptors = waiter_config.acceptors

   local remaining = max_wait
   local attempt = 0

   while true do
      attempt = attempt + 1
      local start = os.clock()

      local cl = client
      local op_fn = cl[operation_fn]
      local output, err = op_fn(client, input)

      local state
      for _, acceptor in ipairs(acceptors) do
         state = eval_acceptor(acceptor, input, output, err)
         if state then break end
      end

      if state == "success" then
         return output, nil
      elseif state == "failure" then
         local msg = "waiter state transitioned to Failure"
         if err then
            local e = err
            msg = msg .. ": " .. ((e.message or e.code or ""))
         end
         return nil, { type = "sdk", code = "WaiterFailure", message = msg }
      end

      if not state and err then
         return nil, err
      end

      local elapsed = os.clock() - start
      remaining = remaining - elapsed

      if remaining <= min_delay then
         return nil, { type = "sdk", code = "WaiterTimeout", message = "exceeded max wait time" }
      end

      local delay = M.compute_delay(attempt, min_delay, max_delay)
      if remaining - delay < min_delay then
         delay = remaining - min_delay
      end

      sleep(delay)
      remaining = remaining - delay
   end
end

M._eval_path = eval_path
M._eval_acceptor = eval_acceptor

return M
